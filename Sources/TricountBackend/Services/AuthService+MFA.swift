import Fluent
import Vapor
import Foundation

/// MFA setup, verification, login challenge, and recovery-factor workflows.
extension AuthService {
    // MARK: - MFA

    func enableMFA(dto: EnableMFARequest) async throws -> UserDTO {
        let user = try await currentUser()
        let rawMethod = dto.method.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let method = EmailMFAChallenge.Method(rawValue: rawMethod) else {
            throw Abort(.badRequest, reason: "Unsupported MFA method")
        }

        guard method != .backupCode else {
            throw Abort(.unprocessableEntity, reason: "Backup codes cannot be used as the primary MFA method")
        }

        guard try await isMFAMethodAvailable(method, for: user) else {
            throw Abort(.unprocessableEntity, reason: "Selected MFA method is not configured and verified")
        }

        user.isMFAEnabled = true
        user.mfaMethod = method.rawValue
        try await user.save(on: req.db)

        return UserDTO(from: user)
    }

    func disableMFA() async throws -> UserDTO {
        let user = try await currentUser()
        let userId = try requireUserID(from: user)

        try await invalidateEmailMFAChallenges(for: userId, purpose: .login)

        user.isMFAEnabled = false
        user.mfaMethod = nil
        try await user.save(on: req.db)
        return UserDTO(from: user)
    }

    func requestEmailMFAEnable() async throws -> MessageResponse {
        let user = try await currentUser()

        guard user.isEmailVerified else {
            throw AuthError.mfaRequiresVerifiedEmail
        }

        if user.isMFAEnabled, user.mfaMethod == EmailMFAChallenge.Method.email.rawValue {
            return MessageResponse(message: "Email MFA is already enabled.")
        }

        let code = try await replaceEmailMFAEnableCode(for: user)
        try await req.authEmailDispatcher.sendMFAEnableOTP(
            to: user.email,
            code: code,
            displayName: user.displayName
        )
        req.setDevelopmentDebugHeader(name: "X-Debug-OTP-Code", value: code)

        return MessageResponse(message: "MFA enable code sent to \(user.email).")
    }

    func confirmEmailMFAEnable(dto: ConfirmEmailMFAEnableRequest) async throws -> UserDTO {
        let code = try normalizeSixDigitCode(
            dto.code,
            reason: "MFA code must be a 6-digit number"
        )

        let user = try await currentUser()
        guard let userId = user.id else {
            throw Abort(.internalServerError)
        }

        guard let challenge = try await EmailMFAChallenge.query(on: req.db)
            .filter(\.$user.$id == userId)
            .filter(\.$purposeRawValue == EmailMFAChallenge.Purpose.enable.rawValue)
            .filter(\.$codeHash == sha256(code))
            .filter(\.$isUsed == false)
            .sort(\.$createdAt, .descending)
            .first(),
              challenge.isValid
        else {
            throw AuthError.mfaCodeInvalid
        }

        challenge.isUsed = true
        try await challenge.save(on: req.db)

        user.isMFAEnabled = true
        user.mfaMethod = EmailMFAChallenge.Method.email.rawValue
        try await user.save(on: req.db)

        return UserDTO(from: user)
    }

    func disableEmailMFA() async throws -> UserDTO {
        let user = try await currentUser()
        guard let userId = user.id else {
            throw Abort(.internalServerError)
        }

        if !user.isMFAEnabled || user.mfaMethod != EmailMFAChallenge.Method.email.rawValue {
            return UserDTO(from: user)
        }

        try await invalidateEmailMFAChallenges(for: userId, method: .email)

        user.isMFAEnabled = false
        user.mfaMethod = nil
        try await user.save(on: req.db)

        return UserDTO(from: user)
    }

    func verifyEmailMFALogin(dto: MFALoginVerifyRequest) async throws -> AuthResponse {
        let challenge = try await validMFALoginChallenge(token: dto.challengeToken, method: .email)
        let code = try normalizeSixDigitCode(
            dto.code,
            reason: "MFA code must be a 6-digit number"
        )

        guard challenge.codeHash == sha256(code) else {
            throw AuthError.mfaCodeInvalid
        }

        challenge.isUsed = true
        try await challenge.save(on: req.db)

        let user = try await challenge.$user.get(on: req.db)
        guard user.isMFAEnabled, user.isEmailVerified else {
            throw AuthError.mfaChallengeInvalid
        }

        return try await generateTokenPair(for: user)
    }

    func verifyPhoneMFALogin(dto: MFALoginVerifyRequest) async throws -> AuthResponse {
        let challenge = try await validMFALoginChallenge(token: dto.challengeToken, method: .phone)
        let code = try normalizeSixDigitCode(
            dto.code,
            reason: "Phone MFA code must be a 6-digit number"
        )

        guard challenge.codeHash == sha256(code) else {
            throw AuthError.mfaCodeInvalid
        }

        challenge.isUsed = true
        try await challenge.save(on: req.db)

        let user = try await challenge.$user.get(on: req.db)
        guard user.isMFAEnabled,
              user.isPhoneVerified,
              user.phoneNumber != nil
        else {
            throw AuthError.mfaChallengeInvalid
        }

        return try await generateTokenPair(for: user)
    }

    func beginAuthenticatorAppMFASetup() async throws -> AuthenticatorAppMFASetupResponse {
        let user = try await currentUser()
        let userId = try requireUserID(from: user)
        let issuer = configuredTOTPIssuer()

        try await invalidateAuthenticatorAppSetupChallenges(for: userId)

        let secret = TOTPService.generateSecret()
        let challenge = AuthenticatorAppSetupChallenge(
            userId: userId,
            secret: secret,
            expiresAt: AuthenticatorAppSetupChallenge.expirationFromNow
        )
        try await challenge.save(on: req.db)

        let otpauthURL = TOTPService.otpauthURL(secret: secret, issuer: issuer, accountName: user.email)
        req.logSensitiveDevelopmentValue(
            "Authenticator app MFA setup generated",
            metadata: [
                "userId": .string(userId.uuidString),
                "email": .string(user.email),
                "issuer": .string(issuer),
                "secret": .string(secret),
                "otpauthURL": .string(otpauthURL)
            ]
        )

        return AuthenticatorAppMFASetupResponse(
            secret: secret,
            issuer: issuer,
            accountName: user.email,
            otpauthURL: otpauthURL,
            digits: TOTPService.digits,
            period: TOTPService.period
        )
    }

    func confirmAuthenticatorAppMFAEnable(dto: ConfirmEmailMFAEnableRequest) async throws -> UserDTO {
        let code = try normalizeSixDigitCode(
            dto.code,
            reason: "Authenticator app code must be a 6-digit number"
        )

        let user = try await currentUser()
        let userId = try requireUserID(from: user)

        guard let challenge = try await AuthenticatorAppSetupChallenge.query(on: req.db)
            .filter(\.$user.$id == userId)
            .filter(\.$isUsed == false)
            .sort(\.$createdAt, .descending)
            .first(),
              challenge.isValid,
              try TOTPService.verify(code: code, secret: challenge.secret)
        else {
            throw AuthError.authenticatorAppSetupInvalid
        }

        challenge.isUsed = true
        try await challenge.save(on: req.db)

        try await invalidateEmailMFAChallenges(for: userId)

        user.totpSecret = challenge.secret
        user.isMFAEnabled = true
        user.mfaMethod = EmailMFAChallenge.Method.authenticatorApp.rawValue
        try await user.save(on: req.db)

        return UserDTO(from: user)
    }

    func disableAuthenticatorAppMFA() async throws -> UserDTO {
        let user = try await currentUser()
        let userId = try requireUserID(from: user)

        try await invalidateAuthenticatorAppSetupChallenges(for: userId)

        guard user.isMFAEnabled, user.mfaMethod == EmailMFAChallenge.Method.authenticatorApp.rawValue else {
            return UserDTO(from: user)
        }

        try await invalidateEmailMFAChallenges(for: userId, method: .authenticatorApp)

        user.isMFAEnabled = false
        user.mfaMethod = nil
        user.totpSecret = nil
        try await user.save(on: req.db)

        return UserDTO(from: user)
    }

    func verifyAuthenticatorAppMFALogin(dto: MFALoginVerifyRequest) async throws -> AuthResponse {
        let challenge = try await validMFALoginChallenge(token: dto.challengeToken, method: .authenticatorApp)
        let code = try normalizeSixDigitCode(
            dto.code,
            reason: "Authenticator app code must be a 6-digit number"
        )

        let user = try await challenge.$user.get(on: req.db)
        guard user.isMFAEnabled,
              let secret = user.totpSecret,
              try TOTPService.verify(code: code, secret: secret)
        else {
            throw AuthError.mfaCodeInvalid
        }

        challenge.isUsed = true
        try await challenge.save(on: req.db)

        return try await generateTokenPair(for: user)
    }

    func verifyBackupCodeMFALogin(dto: MFALoginVerifyRequest) async throws -> AuthResponse {
        let challenge = try await validMFALoginChallenge(token: dto.challengeToken, method: .backupCode)
        let normalizedCode = try normalizeBackupCode(dto.code)

        let user = try await challenge.$user.get(on: req.db)
        guard user.isMFAEnabled else {
            throw AuthError.mfaChallengeInvalid
        }

        guard let matchedCode = try await matchingBackupCode(
            normalizedCode,
            for: try requireUserID(from: user)
        ) else {
            throw AuthError.mfaCodeInvalid
        }

        matchedCode.usedAt = Date()
        try await matchedCode.save(on: req.db)

        challenge.isUsed = true
        try await challenge.save(on: req.db)

        return try await generateTokenPair(for: user)
    }

    func beginPasskeyMFALogin(dto: PasskeyMFALoginOptionsRequest) async throws -> PasskeyAuthenticationOptionsResponse {
        let challenge = try await validMFALoginChallenge(token: dto.challengeToken, method: .passkey)
        let user = try await challenge.$user.get(on: req.db)

        guard user.isMFAEnabled else {
            throw AuthError.mfaChallengeInvalid
        }

        return try await passkeyService.beginAuthentication(emailHint: user.email)
    }

    func finishPasskeyMFALogin(dto: PasskeyMFALoginVerificationRequest) async throws -> AuthResponse {
        let challenge = try await validMFALoginChallenge(token: dto.challengeToken, method: .passkey)
        let expectedUser = try await challenge.$user.get(on: req.db)
        let authenticatedUser = try await passkeyService.finishAuthentication(dto.authenticationRequest)

        guard expectedUser.id == authenticatedUser.id,
              authenticatedUser.isMFAEnabled
        else {
            throw AuthError.mfaChallengeInvalid
        }

        challenge.isUsed = true
        try await challenge.save(on: req.db)

        return try await generateTokenPair(for: authenticatedUser)
    }

    func generateBackupCodes() async throws -> BackupCodesResponse {
        try await replaceBackupCodes()
    }

    func regenerateBackupCodes() async throws -> BackupCodesResponse {
        try await replaceBackupCodes()
    }

    func requestPhoneVerification(dto: SetupPhoneVerificationRequest) async throws -> MessageResponse {
        let normalizedPhone = AuthValidation.normalizePhoneNumber(dto.phoneNumber)
        guard AuthValidation.isValidPhoneNumber(normalizedPhone) else {
            throw Abort(.badRequest, reason: "Phone number must be a valid E.164 value")
        }

        let user = try await currentUser()
        let userId = try requireUserID(from: user)
        try await ensurePhoneNumberIsAvailable(normalizedPhone, excluding: userId)

        user.phoneNumber = normalizedPhone
        user.isPhoneVerified = false
        user.phoneVerifiedAt = nil
        try await user.save(on: req.db)

        let code = try await replacePhoneVerificationOTP(for: user, phoneNumber: normalizedPhone)
        try await req.authSMSDispatcher.sendPhoneVerificationOTP(to: normalizedPhone, code: code)
        req.setDevelopmentDebugHeader(name: "X-Debug-OTP-Code", value: code)

        return MessageResponse(message: "Verification code sent to \(normalizedPhone).")
    }

    func confirmPhoneVerification(dto: ConfirmPhoneVerificationRequest) async throws -> UserDTO {
        let code = try normalizeSixDigitCode(
            dto.code,
            reason: "Phone verification code must be a 6-digit number"
        )

        let user = try await currentUser()
        let userId = try requireUserID(from: user)

        guard let phoneNumber = user.phoneNumber else {
            throw Abort(.badRequest, reason: "Phone number is not set")
        }

        guard let challenge = try await PhoneVerificationOTP.query(on: req.db)
            .filter(\.$user.$id == userId)
            .filter(\.$phoneNumber == phoneNumber)
            .filter(\.$codeHash == sha256(code))
            .filter(\.$isUsed == false)
            .sort(\.$createdAt, .descending)
            .first(),
              challenge.isValid
        else {
            throw AuthError.phoneVerificationCodeInvalid
        }

        challenge.isUsed = true
        try await challenge.save(on: req.db)

        user.isPhoneVerified = true
        user.phoneVerifiedAt = Date()
        try await user.save(on: req.db)

        return UserDTO(from: user)
    }

    func removePhoneNumber() async throws -> UserDTO {
        let user = try await currentUser()
        let userId = try requireUserID(from: user)

        if user.isMFAEnabled,
           user.mfaMethod == EmailMFAChallenge.Method.phone.rawValue,
           let fallbackMethod = try await fallbackPrimaryMFAMethod(for: user, removing: .phone) {
            user.mfaMethod = fallbackMethod.rawValue
        } else if user.isMFAEnabled,
                  user.mfaMethod == EmailMFAChallenge.Method.phone.rawValue {
            throw Abort(.conflict, reason: "Add another MFA method before removing your verified phone number.")
        }

        try await PhoneVerificationOTP.query(on: req.db)
            .filter(\.$user.$id == userId)
            .filter(\.$isUsed == false)
            .set(\.$isUsed, to: true)
            .update()
        try await invalidateEmailMFAChallenges(for: userId, purpose: .login, method: .phone)

        user.phoneNumber = nil
        user.isPhoneVerified = false
        user.phoneVerifiedAt = nil
        try await user.save(on: req.db)

        return UserDTO(from: user)
    }

    func listPasskeys() async throws -> [PasskeyCredentialDTO] {
        let userId = try req.authenticatedUserID
        let credentials = try await PasskeyCredential.query(on: req.db)
            .filter(\.$user.$id == userId)
            .sort(\.$createdAt, .ascending)
            .all()

        return credentials.map(PasskeyCredentialDTO.init(from:))
    }

    func removePasskey(dto: RemovePasskeyRequest) async throws -> MessageResponse {
        let user = try await currentUser()
        let userId = try requireUserID(from: user)
        let credentialId = dto.credentialId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credentialId.isEmpty else {
            throw Abort(.badRequest, reason: "credentialId is required")
        }

        guard let credential = try await PasskeyCredential.query(on: req.db)
            .filter(\.$user.$id == userId)
            .filter(\.$credentialId == credentialId)
            .first()
        else {
            throw AuthError.passkeyCredentialNotFound
        }

        let passkeyCount = try await PasskeyCredential.query(on: req.db)
            .filter(\.$user.$id == userId)
            .count()
        let remainingPasskeyCount = max(0, passkeyCount - 1)

        if user.isMFAEnabled,
           user.mfaMethod == EmailMFAChallenge.Method.passkey.rawValue,
           remainingPasskeyCount == 0,
           let fallbackMethod = try await fallbackPrimaryMFAMethod(
               for: user,
               removing: .passkey,
               remainingPasskeyCount: remainingPasskeyCount
           ) {
            user.mfaMethod = fallbackMethod.rawValue
            try await user.save(on: req.db)
        } else if user.isMFAEnabled,
                  user.mfaMethod == EmailMFAChallenge.Method.passkey.rawValue,
                  remainingPasskeyCount == 0 {
            throw Abort(.conflict, reason: "Add another MFA method before removing your last passkey.")
        }

        try await invalidateEmailMFAChallenges(for: userId, purpose: .login, method: .passkey)
        try await credential.delete(on: req.db)
        return MessageResponse(message: "Passkey removed.")
    }

    func resetPasskeys() async throws -> MessageResponse {
        let user = try await currentUser()
        let userId = try requireUserID(from: user)

        if user.isMFAEnabled,
           user.mfaMethod == EmailMFAChallenge.Method.passkey.rawValue,
           let fallbackMethod = try await fallbackPrimaryMFAMethod(
               for: user,
               removing: .passkey,
               remainingPasskeyCount: 0
           ) {
            user.mfaMethod = fallbackMethod.rawValue
            try await user.save(on: req.db)
        } else if user.isMFAEnabled,
                  user.mfaMethod == EmailMFAChallenge.Method.passkey.rawValue {
            throw Abort(.conflict, reason: "Add another MFA method before removing all passkeys.")
        }

        try await invalidateEmailMFAChallenges(for: userId, purpose: .login, method: .passkey)
        try await PasskeyCredential.query(on: req.db)
            .filter(\.$user.$id == userId)
            .delete()

        return MessageResponse(message: "All passkeys removed.")
    }

    // MARK: - MFA Helpers

    func replaceEmailMFAEnableCode(for user: User) async throws -> String {
        guard let userId = user.id else {
            throw Abort(.internalServerError)
        }

        try await invalidateEmailMFAChallenges(for: userId, purpose: .enable, method: .email)

        let code = generateOTPCode()
        let challenge = EmailMFAChallenge(
            userId: userId,
            purpose: .enable,
            method: .email,
            codeHash: sha256(code),
            expiresAt: EmailMFAChallenge.expirationFromNow
        )
        try await challenge.save(on: req.db)
        return code
    }

    func createEmailMFALoginChallenge(for user: User) async throws -> MFAChallengeResponse {
        guard let userId = user.id else {
            throw Abort(.internalServerError)
        }

        guard user.isEmailVerified else {
            throw AuthError.mfaRequiresVerifiedEmail
        }

        try await invalidateEmailMFAChallenges(for: userId, purpose: .login, method: .email)

        let code = generateOTPCode()
        let challengeToken = generateSecureToken()
        let challenge = EmailMFAChallenge(
            userId: userId,
            purpose: .login,
            method: .email,
            challengeTokenHash: sha256(challengeToken),
            codeHash: sha256(code),
            expiresAt: EmailMFAChallenge.expirationFromNow
        )
        try await challenge.save(on: req.db)

        try await req.authEmailDispatcher.sendMFALoginOTP(
            to: user.email,
            code: code,
            displayName: user.displayName
        )
        req.setDevelopmentDebugHeader(name: "X-Debug-OTP-Code-Email", value: code)

        return MFAChallengeResponse(
            method: "email",
            challengeToken: challengeToken,
            expiresIn: Int(EmailMFAChallenge.lifetime.interval),
            displayName: "Email OTP",
            verificationType: "otp",
            destinationHint: maskedEmail(user.email)
        )
    }

    func createAuthenticatorAppMFALoginChallenge(for user: User) async throws -> MFAChallengeResponse {
        let userId = try requireUserID(from: user)

        guard user.totpSecret != nil else {
            throw Abort(.internalServerError, reason: "Authenticator app MFA secret missing")
        }

        try await invalidateEmailMFAChallenges(for: userId, purpose: .login, method: .authenticatorApp)

        let challengeToken = generateSecureToken()
        let challenge = EmailMFAChallenge(
            userId: userId,
            purpose: .login,
            method: .authenticatorApp,
            challengeTokenHash: sha256(challengeToken),
            codeHash: "",
            expiresAt: EmailMFAChallenge.expirationFromNow
        )
        try await challenge.save(on: req.db)

        return MFAChallengeResponse(
            method: EmailMFAChallenge.Method.authenticatorApp.rawValue,
            challengeToken: challengeToken,
            expiresIn: Int(EmailMFAChallenge.lifetime.interval),
            displayName: "Authenticator App",
            verificationType: "totp",
            destinationHint: nil
        )
    }

    func createPhoneMFALoginChallenge(for user: User) async throws -> MFAChallengeResponse {
        let userId = try requireUserID(from: user)
        guard user.isPhoneVerified, let phoneNumber = user.phoneNumber else {
            throw Abort(.unprocessableEntity, reason: "Phone MFA requires a verified phone number")
        }

        try await invalidateEmailMFAChallenges(for: userId, purpose: .login, method: .phone)

        let code = generateOTPCode()
        let challengeToken = generateSecureToken()
        let challenge = EmailMFAChallenge(
            userId: userId,
            purpose: .login,
            method: .phone,
            challengeTokenHash: sha256(challengeToken),
            codeHash: sha256(code),
            expiresAt: EmailMFAChallenge.expirationFromNow
        )
        try await challenge.save(on: req.db)

        try await req.authSMSDispatcher.sendMFALoginOTP(to: phoneNumber, code: code)
        req.setDevelopmentDebugHeader(name: "X-Debug-OTP-Code-Phone", value: code)

        return MFAChallengeResponse(
            method: EmailMFAChallenge.Method.phone.rawValue,
            challengeToken: challengeToken,
            expiresIn: Int(EmailMFAChallenge.lifetime.interval),
            displayName: "SMS OTP",
            verificationType: "otp",
            destinationHint: maskedPhoneNumber(phoneNumber)
        )
    }

    func createBackupCodeMFALoginChallenge(for user: User) async throws -> MFAChallengeResponse {
        let userId = try requireUserID(from: user)
        try await invalidateEmailMFAChallenges(for: userId, purpose: .login, method: .backupCode)

        let challengeToken = generateSecureToken()
        let challenge = EmailMFAChallenge(
            userId: userId,
            purpose: .login,
            method: .backupCode,
            challengeTokenHash: sha256(challengeToken),
            codeHash: "",
            expiresAt: EmailMFAChallenge.expirationFromNow
        )
        try await challenge.save(on: req.db)

        return MFAChallengeResponse(
            method: EmailMFAChallenge.Method.backupCode.rawValue,
            challengeToken: challengeToken,
            expiresIn: Int(EmailMFAChallenge.lifetime.interval),
            displayName: "Backup Code",
            verificationType: "backup_code",
            destinationHint: nil
        )
    }

    func createPasskeyMFALoginChallenge(for user: User) async throws -> MFAChallengeResponse {
        let userId = try requireUserID(from: user)
        try await invalidateEmailMFAChallenges(for: userId, purpose: .login, method: .passkey)

        let challengeToken = generateSecureToken()
        let challenge = EmailMFAChallenge(
            userId: userId,
            purpose: .login,
            method: .passkey,
            challengeTokenHash: sha256(challengeToken),
            codeHash: "",
            expiresAt: EmailMFAChallenge.expirationFromNow
        )
        try await challenge.save(on: req.db)

        return MFAChallengeResponse(
            method: EmailMFAChallenge.Method.passkey.rawValue,
            challengeToken: challengeToken,
            expiresIn: Int(EmailMFAChallenge.lifetime.interval),
            displayName: "Passkey",
            verificationType: "webauthn",
            destinationHint: nil
        )
    }

    func createMFALoginChallenges(
        for user: User,
        methods: [EmailMFAChallenge.Method]
    ) async throws -> [MFAChallengeResponse] {
        var challenges: [MFAChallengeResponse] = []
        challenges.reserveCapacity(methods.count)

        for method in methods {
            switch method {
            case .email:
                challenges.append(try await createEmailMFALoginChallenge(for: user))
            case .phone:
                challenges.append(try await createPhoneMFALoginChallenge(for: user))
            case .authenticatorApp:
                challenges.append(try await createAuthenticatorAppMFALoginChallenge(for: user))
            case .backupCode:
                challenges.append(try await createBackupCodeMFALoginChallenge(for: user))
            case .passkey:
                challenges.append(try await createPasskeyMFALoginChallenge(for: user))
            }
        }

        return challenges
    }

    func availableMFALoginMethods(
        for user: User,
        primaryMethods: [EmailMFAChallenge.Method]? = nil
    ) async throws -> [EmailMFAChallenge.Method] {
        let userId = try requireUserID(from: user)
        var methods = if let primaryMethods {
            primaryMethods
        } else {
            try await availablePrimaryMFAMethods(for: user)
        }
        if try await hasActiveBackupCodes(for: userId) {
            methods.append(.backupCode)
        }

        return prioritizedMFAMethods(methods, preferredMethodRawValue: user.mfaMethod)
    }

    func isMFAMethodAvailable(
        _ method: EmailMFAChallenge.Method,
        for user: User
    ) async throws -> Bool {
        let userId = try requireUserID(from: user)

        switch method {
        case .email:
            return user.isEmailVerified
        case .phone:
            return user.isPhoneVerified && user.phoneNumber != nil
        case .authenticatorApp:
            return user.totpSecret != nil
        case .backupCode:
            return try await hasActiveBackupCodes(for: userId)
        case .passkey:
            return try await hasRegisteredPasskeys(for: userId)
        }
    }

    func availablePrimaryMFAMethods(
        for user: User,
        excluding excludedMethods: Set<EmailMFAChallenge.Method> = [],
        remainingPasskeyCount: Int? = nil
    ) async throws -> [EmailMFAChallenge.Method] {
        let userId = try requireUserID(from: user)
        var methods: [EmailMFAChallenge.Method] = []

        if user.isEmailVerified, !excludedMethods.contains(.email) {
            methods.append(.email)
        }

        if user.isPhoneVerified,
           user.phoneNumber != nil,
           !excludedMethods.contains(.phone) {
            methods.append(.phone)
        }

        if user.totpSecret != nil, !excludedMethods.contains(.authenticatorApp) {
            methods.append(.authenticatorApp)
        }

        if !excludedMethods.contains(.passkey) {
            let hasPasskeys: Bool
            if let remainingPasskeyCount {
                hasPasskeys = remainingPasskeyCount > 0
            } else {
                hasPasskeys = try await hasRegisteredPasskeys(for: userId)
            }

            if hasPasskeys {
                methods.append(.passkey)
            }
        }

        return prioritizedMFAMethods(methods, preferredMethodRawValue: user.mfaMethod)
    }

    func fallbackPrimaryMFAMethod(
        for user: User,
        removing removedMethod: EmailMFAChallenge.Method,
        remainingPasskeyCount: Int? = nil
    ) async throws -> EmailMFAChallenge.Method? {
        let methods = try await availablePrimaryMFAMethods(
            for: user,
            excluding: [removedMethod],
            remainingPasskeyCount: remainingPasskeyCount
        )
        return methods.first(where: \.isPrimaryFactor)
    }

    func prioritizedMFAMethods(
        _ methods: [EmailMFAChallenge.Method],
        preferredMethodRawValue: String?
    ) -> [EmailMFAChallenge.Method] {
        var prioritized = methods
        let preferredMethod = EmailMFAChallenge.Method(rawValue: preferredMethodRawValue ?? "")
        if let preferredMethod,
           let preferredIndex = prioritized.firstIndex(of: preferredMethod),
           preferredIndex != 0 {
            prioritized.swapAt(0, preferredIndex)
        }

        return prioritized
    }

    func preferredMFALoginChallenge(
        from options: [MFAChallengeResponse],
        for user: User
    ) -> MFAChallengeResponse? {
        guard !options.isEmpty else { return nil }

        if let preferredMethod = user.mfaMethod,
           let preferred = options.first(where: { $0.method == preferredMethod }) {
            return preferred
        }

        return options.first
    }

    func validMFALoginChallenge(
        token: String,
        method: EmailMFAChallenge.Method
    ) async throws -> EmailMFAChallenge {
        let challengeToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !challengeToken.isEmpty else {
            throw Abort(.badRequest, reason: "MFA challenge token is required")
        }

        guard let challenge = try await EmailMFAChallenge.query(on: req.db)
            .filter(\.$challengeTokenHash == sha256(challengeToken))
            .filter(\.$purposeRawValue == EmailMFAChallenge.Purpose.login.rawValue)
            .filter(\.$isUsed == false)
            .sort(\.$createdAt, .descending)
            .first(),
              challenge.isValid,
              challenge.method == method
        else {
            throw AuthError.mfaChallengeInvalid
        }

        return challenge
    }

    func invalidateEmailMFAChallenges(
        for userId: UUID,
        purpose: EmailMFAChallenge.Purpose? = nil,
        method: EmailMFAChallenge.Method? = nil
    ) async throws {
        let query = EmailMFAChallenge.query(on: req.db)
            .filter(\.$user.$id == userId)
            .filter(\.$isUsed == false)

        if let purpose { query.filter(\.$purposeRawValue == purpose.rawValue) }
        if let method { query.filter(\.$methodRawValueStorage == method.rawValue) }

        try await query.set(\.$isUsed, to: true).update()
    }

    func invalidateAuthenticatorAppSetupChallenges(for userId: UUID) async throws {
        try await AuthenticatorAppSetupChallenge.query(on: req.db)
            .filter(\.$user.$id == userId)
            .filter(\.$isUsed == false)
            .set(\.$isUsed, to: true)
            .update()
    }

    func replacePhoneVerificationOTP(for user: User, phoneNumber: String) async throws -> String {
        let userId = try requireUserID(from: user)

        try await PhoneVerificationOTP.query(on: req.db)
            .filter(\.$user.$id == userId)
            .filter(\.$isUsed == false)
            .set(\.$isUsed, to: true)
            .update()

        let code = generateOTPCode()
        let challenge = PhoneVerificationOTP(
            userId: userId,
            phoneNumber: phoneNumber,
            codeHash: sha256(code),
            expiresAt: PhoneVerificationOTP.expirationFromNow
        )
        try await challenge.save(on: req.db)
        return code
    }

    func replaceBackupCodes() async throws -> BackupCodesResponse {
        let user = try await currentUser()
        let userId = try requireUserID(from: user)

        guard try await hasAnyPrimaryMFAMethod(for: user) else {
            throw Abort(.unprocessableEntity, reason: "Configure at least one verified MFA method before generating backup codes")
        }

        try await invalidateEmailMFAChallenges(for: userId, purpose: .login, method: .backupCode)

        var rawCodes: [String] = []
        var hashedCodes: [String] = []
        rawCodes.reserveCapacity(Self.backupCodeCount)
        hashedCodes.reserveCapacity(Self.backupCodeCount)

        for _ in 0..<Self.backupCodeCount {
            let rawCode = generateBackupCode()
            rawCodes.append(rawCode)
            let hash = try await req.passwordHasher.hash(normalizeBackupCode(rawCode), on: req.eventLoop)
            hashedCodes.append(hash)
        }
        let storedCodeHashes = hashedCodes

        try await req.db.transaction { db in
            try await BackupCode.query(on: db)
                .filter(\.$user.$id == userId)
                .delete()

            for hash in storedCodeHashes {
                let backupCode = BackupCode(userId: userId, codeHash: hash)
                try await backupCode.save(on: db)
            }
        }

        return BackupCodesResponse(codes: rawCodes, totalCount: rawCodes.count)
    }

    func hasAnyPrimaryMFAMethod(for user: User) async throws -> Bool {
        let userId = try requireUserID(from: user)
        if user.isEmailVerified || (user.isPhoneVerified && user.phoneNumber != nil) || user.totpSecret != nil {
            return true
        }

        return try await hasRegisteredPasskeys(for: userId)
    }

    func hasActiveBackupCodes(for userId: UUID) async throws -> Bool {
        try await BackupCode.query(on: req.db)
            .filter(\.$user.$id == userId)
            .filter(\.$usedAt == nil)
            .count() > 0
    }

    func hasRegisteredPasskeys(for userId: UUID) async throws -> Bool {
        try await PasskeyCredential.query(on: req.db)
            .filter(\.$user.$id == userId)
            .count() > 0
    }

    func matchingBackupCode(_ code: String, for userId: UUID) async throws -> BackupCode? {
        let activeCodes = try await BackupCode.query(on: req.db)
            .filter(\.$user.$id == userId)
            .filter(\.$usedAt == nil)
            .all()

        for backupCode in activeCodes {
            let matches = try await req.passwordHasher.verify(
                password: code,
                against: backupCode.codeHash,
                on: req.eventLoop
            )
            if matches {
                return backupCode
            }
        }

        return nil
    }

    func ensurePhoneNumberIsAvailable(_ phoneNumber: String, excluding userID: UUID?) async throws {
        guard let existing = try await User.query(on: req.db)
            .filter(\.$phoneNumber == phoneNumber)
            .first()
        else {
            return
        }

        if existing.id != userID {
            throw Abort(.conflict, reason: "Phone number is already linked to another account")
        }
    }
}
