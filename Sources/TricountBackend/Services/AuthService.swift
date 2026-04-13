import Fluent
import Vapor
import JWT
import Crypto
import Foundation

private enum SocialAuthProvider: String, Sendable {
    case google
    case apple
}

private struct SocialIdentityProfile: Sendable {
    let provider: SocialAuthProvider
    let subject: String
    let email: String?
    let displayName: String
    let avatarUrl: String?

    var normalizedEmail: String? {
        email.map(AuthValidation.normalizeEmail)
    }

    var canRefreshPrimaryProfile: Bool {
        provider == .google || normalizedEmail != nil
    }
}

struct AuthService {
    let req: Request
    private static let backupCodeCount = 10

    // MARK: - Login

    func login(dto: LoginRequest) async throws -> AuthenticationResultResponse {
        guard !dto.email.isEmpty, !dto.password.isEmpty else {
            throw Abort(.badRequest, reason: "Email and password are required")
        }

        let email = AuthValidation.normalizeEmail(dto.email)

        guard let user = try await User.query(on: req.db)
            .filter(\.$email == email)
            .filter(\.$provider == "email")
            .first()
        else {
            throw AuthError.invalidCredentials
        }

        guard let hash = user.passwordHash else {
            throw AuthError.invalidCredentials
        }

        let valid = try await req.passwordHasher.verify(password: dto.password, against: hash, on: req.eventLoop)
        guard valid else {
            throw AuthError.invalidCredentials
        }

        return try await completePrimaryAuthentication(for: user)
    }

    // MARK: - Register

    func register(dto: RegisterRequest) async throws -> AuthResponse {
        try validatePassword(dto.password)
        try validateDisplayName(dto.displayName)

        let email = AuthValidation.normalizeEmail(dto.email)
        guard AuthValidation.isValidEmail(email) else {
            throw Abort(.unprocessableEntity, reason: "Invalid email format")
        }

        let exists = try await User.query(on: req.db)
            .filter(\.$email == email)
            .count() > 0

        if exists { throw AuthError.emailAlreadyExists }

        let hash = try await req.passwordHasher.hash(dto.password, on: req.eventLoop)
        let user = User(
            email: email,
            passwordHash: hash,
            displayName: dto.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            isEmailVerified: false,
            provider: "email"
        )
        try await user.save(on: req.db)

        return try await generateTokenPair(for: user)
    }

    // MARK: - Social Sign-In

    func googleSignIn(dto: GoogleLoginRequest) async throws -> AuthenticationResultResponse {
        let googleProfile = try await googleProfile(from: dto.idToken)
        return try await signIn(with: googleProfile)
    }

    func appleSignIn(dto: AppleLoginRequest) async throws -> AuthenticationResultResponse {
        let appleProfile = try await appleProfile(from: dto.idToken)
        return try await signIn(with: appleProfile)
    }

    // MARK: - Passkeys

    func beginPasskeyRegistration() async throws -> PasskeyRegistrationOptionsResponse {
        let user = try await currentUser()
        return try await passkeyService.beginRegistration(for: user)
    }

    func finishPasskeyRegistration(dto: PasskeyRegistrationVerificationRequest) async throws -> PasskeyCredentialDTO {
        let user = try await currentUser()
        let credential = try await passkeyService.finishRegistration(dto, for: user)
        return PasskeyCredentialDTO(from: credential)
    }

    func beginPasskeyAuthentication(
        dto: PasskeyAuthenticationOptionsRequest
    ) async throws -> PasskeyAuthenticationOptionsResponse {
        try await passkeyService.beginAuthentication(emailHint: dto.email)
    }

    func finishPasskeyAuthentication(
        dto: PasskeyAuthenticationVerificationRequest
    ) async throws -> AuthenticationResultResponse {
        let user = try await passkeyService.finishAuthentication(dto)
        return try await completePrimaryAuthentication(for: user)
    }

    // MARK: - Refresh Tokens

    func refresh(dto: RefreshTokenRequest) async throws -> TokenRefreshResponse {
        let hash = sha256(dto.refreshToken)

        guard let stored = try await RefreshToken.query(on: req.db)
            .filter(\.$tokenHash == hash)
            .first(),
              stored.isValid
        else {
            throw AuthError.refreshTokenInvalid
        }

        stored.isRevoked = true
        try await stored.save(on: req.db)

        let user = try await stored.$user.get(on: req.db)
        let (newAccess, newRefresh) = try await issueTokens(for: user)

        return TokenRefreshResponse(
            accessToken: newAccess,
            refreshToken: newRefresh,
            expiresIn: Int(TokenLifetime.accessToken)
        )
    }

    // MARK: - Logout

    func logout() async throws {
        let userId = try req.authenticatedUserID

        try await RefreshToken.query(on: req.db)
            .filter(\.$user.$id == userId)
            .filter(\.$isRevoked == false)
            .set(\.$isRevoked, to: true)
            .update()
    }

    // MARK: - Forgot Password

    func forgotPassword(dto: ForgotPasswordRequest) async throws {
        let email = AuthValidation.normalizeEmail(dto.email)
        req.logger.info("Password reset requested", metadata: ["email": .string(email)])

        guard let user = try await User.query(on: req.db)
            .filter(\.$email == email)
            .filter(\.$provider == "email")
            .first(),
              user.passwordHash != nil
        else {
            return
        }

        let code = try await replacePasswordResetOTP(for: user)
        try await req.authEmailDispatcher.sendPasswordResetOTP(
            to: user.email,
            code: code,
            displayName: user.displayName
        )
    }

    func resetPassword(dto: ResetPasswordRequest) async throws -> MessageResponse {
        let email = AuthValidation.normalizeEmail(dto.email)
        guard AuthValidation.isValidEmail(email) else {
            throw Abort(.unprocessableEntity, reason: "Invalid email format")
        }

        try validatePassword(dto.newPassword)
        let code = try normalizeSixDigitCode(dto.code, reason: "Password reset code must be a 6-digit number")

        guard let user = try await User.query(on: req.db)
            .filter(\.$email == email)
            .filter(\.$provider == "email")
            .first(),
              user.passwordHash != nil,
              let userId = user.id
        else {
            throw AuthError.passwordResetCodeInvalid
        }

        guard let resetCode = try await PasswordResetOTP.query(on: req.db)
            .filter(\.$user.$id == userId)
            .filter(\.$email == email)
            .filter(\.$codeHash == sha256(code))
            .filter(\.$isUsed == false)
            .sort(\.$createdAt, .descending)
            .first(),
              resetCode.isValid
        else {
            throw AuthError.passwordResetCodeInvalid
        }

        resetCode.isUsed = true
        try await resetCode.save(on: req.db)

        user.passwordHash = try await req.passwordHasher.hash(dto.newPassword, on: req.eventLoop)
        try await user.save(on: req.db)

        try await revokeActiveRefreshTokens(for: userId)

        return MessageResponse(message: "Password has been reset.")
    }

    // MARK: - Verify Profile

    func verifyGoogleProfile(dto: VerifyProfileRequest) async throws -> UserDTO {
        let googleProfile = try await googleProfile(from: dto.idToken)
        return try await verifyProfile(with: googleProfile)
    }

    func verifyAppleProfile(dto: VerifyProfileRequest) async throws -> UserDTO {
        let appleProfile = try await appleProfile(from: dto.idToken)
        return try await verifyProfile(with: appleProfile)
    }

    func requestEmailVerificationOTP() async throws -> MessageResponse {
        let user = try await currentUser()

        guard !user.isEmailVerified else {
            return MessageResponse(message: "Email is already verified.")
        }

        let code = try await replaceEmailVerificationOTP(for: user)
        try await req.authEmailDispatcher.sendVerificationOTP(
            to: user.email,
            code: code,
            displayName: user.displayName
        )

        return MessageResponse(message: "Verification code sent to \(user.email).")
    }

    func confirmEmailVerificationOTP(dto: VerifyEmailOTPRequest) async throws -> UserDTO {
        let code = try normalizeSixDigitCode(
            dto.code,
            reason: "Verification code must be a 6-digit number"
        )

        let user = try await currentUser()
        guard let userId = user.id else {
            throw Abort(.internalServerError)
        }

        guard let otp = try await EmailVerificationOTP.query(on: req.db)
            .filter(\.$user.$id == userId)
            .filter(\.$codeHash == sha256(code))
            .filter(\.$isUsed == false)
            .sort(\.$createdAt, .descending)
            .first(),
              otp.isValid,
              otp.email == user.email
        else {
            throw AuthError.verificationOTPInvalid
        }

        otp.isUsed = true
        try await otp.save(on: req.db)

        user.isEmailVerified = true
        user.verifiedAt = user.verifiedAt ?? Date()
        try await user.save(on: req.db)

        return UserDTO(from: user)
    }

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

    // MARK: - Current User

    func currentUser() async throws -> User {
        guard let user = try await User.find(req.authenticatedUserID, on: req.db)
        else {
            throw AuthError.invalidToken
        }
        return user
    }

    // MARK: - Private helpers

    private var passkeyService: PasskeyService {
        PasskeyService(req: req)
    }

    private func requireUserID(from user: User) throws -> UUID {
        guard let userId = user.id else {
            throw Abort(.internalServerError)
        }

        return userId
    }

    private func configuredTOTPIssuer() -> String {
        if let configured = Environment.get("TOTP_ISSUER")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            return configured
        }

        if let rpName = Environment.get("PASSKEY_RP_NAME")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !rpName.isEmpty {
            return rpName
        }

        return "Tricount"
    }

    private func signIn(with profile: SocialIdentityProfile) async throws -> AuthenticationResultResponse {
        // Use a transaction to prevent race conditions when linking social accounts
        let user: User = try await req.db.transaction { db in
            if let linkedUser = try await self.findUserLinked(to: profile, on: db) {
                try await self.syncVerifiedSocialProfile(profile, to: linkedUser, on: db)
                return linkedUser
            }

            if let normalizedEmail = profile.normalizedEmail,
               let existingEmailUser = try await User.query(on: db)
                .filter(\.$email == normalizedEmail)
                .first() {
                try await self.syncVerifiedSocialProfile(profile, to: existingEmailUser, on: db)
                return existingEmailUser
            }

            guard let normalizedEmail = profile.normalizedEmail else {
                throw AuthError.appleEmailMissing
            }

            let newUser = User(
                email: normalizedEmail,
                displayName: profile.displayName,
                avatarUrl: profile.avatarUrl,
                isEmailVerified: true,
                verifiedAt: Date(),
                provider: profile.provider.rawValue,
                googleId: profile.provider == .google ? profile.subject : nil,
                appleId: profile.provider == .apple ? profile.subject : nil
            )
            try await newUser.save(on: db)
            return newUser
        }
        return try await completePrimaryAuthentication(for: user)
    }

    private func completePrimaryAuthentication(for user: User) async throws -> AuthenticationResultResponse {
        if user.isMFAEnabled {
            let primaryMethods = try await availablePrimaryMFAMethods(for: user)
            guard !primaryMethods.isEmpty else {
                throw AuthError.mfaConfigurationInvalid
            }

            let methods = try await availableMFALoginMethods(for: user, primaryMethods: primaryMethods)
            let options = try await createMFALoginChallenges(for: user, methods: methods)
            guard let defaultChallenge = preferredMFALoginChallenge(from: options, for: user) else {
                throw Abort(.internalServerError, reason: "No MFA login methods are available")
            }
            return .requiresMFA(challenge: defaultChallenge, options: options)
        }

        return .authenticated(from: try await generateTokenPair(for: user))
    }

    private func verifyProfile(with profile: SocialIdentityProfile) async throws -> UserDTO {
        let user = try await currentUser()
        guard let normalizedEmail = profile.normalizedEmail else {
            throw AuthError.appleEmailMissing
        }

        guard normalizedEmail == user.email else {
            throw AuthError.verificationEmailMismatch
        }

        try await syncVerifiedSocialProfile(profile, to: user)
        return UserDTO(from: user)
    }

    private func generateTokenPair(for user: User) async throws -> AuthResponse {
        let (accessToken, rawRefreshToken) = try await issueTokens(for: user)
        return AuthResponse(
            accessToken: accessToken,
            refreshToken: rawRefreshToken,
            expiresIn: Int(TokenLifetime.accessToken),
            user: UserDTO(from: user)
        )
    }

    private func issueTokens(for user: User) async throws -> (accessToken: String, refreshToken: String) {
        guard let userId = user.id else { throw Abort(.internalServerError) }

        let payload = UserJWTPayload(
            subject: .init(value: userId.uuidString),
            expiration: .init(value: Date().addingTimeInterval(TokenLifetime.accessToken)),
            issuedAt: .init(value: Date()),
            userId: userId.uuidString
        )
        let accessToken = try req.jwt.sign(payload)

        let rawRefreshToken = generateSecureToken()
        let tokenHash = sha256(rawRefreshToken)

        let refreshToken = RefreshToken(
            userId: userId,
            tokenHash: tokenHash,
            expiresAt: Date().addingTimeInterval(TokenLifetime.refreshToken)
        )
        try await refreshToken.save(on: req.db)

        return (accessToken, rawRefreshToken)
    }

    private func replaceEmailVerificationOTP(for user: User) async throws -> String {
        guard let userId = user.id else {
            throw Abort(.internalServerError)
        }

        try await EmailVerificationOTP.query(on: req.db)
            .filter(\.$user.$id == userId)
            .filter(\.$isUsed == false)
            .set(\.$isUsed, to: true)
            .update()

        let code = generateOTPCode()
        let otp = EmailVerificationOTP(
            userId: userId,
            email: user.email,
            codeHash: sha256(code),
            expiresAt: EmailVerificationOTP.expirationFromNow
        )
        try await otp.save(on: req.db)
        return code
    }

    private func replacePasswordResetOTP(for user: User) async throws -> String {
        guard let userId = user.id else {
            throw Abort(.internalServerError)
        }

        try await PasswordResetOTP.query(on: req.db)
            .filter(\.$user.$id == userId)
            .filter(\.$isUsed == false)
            .set(\.$isUsed, to: true)
            .update()

        let code = generateOTPCode()
        let otp = PasswordResetOTP(
            userId: userId,
            email: user.email,
            codeHash: sha256(code),
            expiresAt: PasswordResetOTP.expirationFromNow
        )
        try await otp.save(on: req.db)
        return code
    }

    private func replaceEmailMFAEnableCode(for user: User) async throws -> String {
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

    private func createEmailMFALoginChallenge(for user: User) async throws -> MFAChallengeResponse {
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

        return MFAChallengeResponse(
            method: "email",
            challengeToken: challengeToken,
            expiresIn: Int(EmailMFAChallenge.lifetime.interval),
            displayName: "Email OTP",
            verificationType: "otp",
            destinationHint: maskedEmail(user.email)
        )
    }

    private func createAuthenticatorAppMFALoginChallenge(for user: User) async throws -> MFAChallengeResponse {
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

    private func createPhoneMFALoginChallenge(for user: User) async throws -> MFAChallengeResponse {
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

        return MFAChallengeResponse(
            method: EmailMFAChallenge.Method.phone.rawValue,
            challengeToken: challengeToken,
            expiresIn: Int(EmailMFAChallenge.lifetime.interval),
            displayName: "SMS OTP",
            verificationType: "otp",
            destinationHint: maskedPhoneNumber(phoneNumber)
        )
    }

    private func createBackupCodeMFALoginChallenge(for user: User) async throws -> MFAChallengeResponse {
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

    private func createPasskeyMFALoginChallenge(for user: User) async throws -> MFAChallengeResponse {
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

    private func createMFALoginChallenges(
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

    private func availableMFALoginMethods(
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

    private func isMFAMethodAvailable(
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

    private func availablePrimaryMFAMethods(
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

    private func fallbackPrimaryMFAMethod(
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

    private func prioritizedMFAMethods(
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

    private func preferredMFALoginChallenge(
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

    private func validMFALoginChallenge(
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

    private func invalidateEmailMFAChallenges(
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

    private func invalidateAuthenticatorAppSetupChallenges(for userId: UUID) async throws {
        try await AuthenticatorAppSetupChallenge.query(on: req.db)
            .filter(\.$user.$id == userId)
            .filter(\.$isUsed == false)
            .set(\.$isUsed, to: true)
            .update()
    }

    private func replacePhoneVerificationOTP(for user: User, phoneNumber: String) async throws -> String {
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

    private func replaceBackupCodes() async throws -> BackupCodesResponse {
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

    private func hasAnyPrimaryMFAMethod(for user: User) async throws -> Bool {
        let userId = try requireUserID(from: user)
        if user.isEmailVerified || (user.isPhoneVerified && user.phoneNumber != nil) || user.totpSecret != nil {
            return true
        }

        return try await hasRegisteredPasskeys(for: userId)
    }

    private func hasActiveBackupCodes(for userId: UUID) async throws -> Bool {
        try await BackupCode.query(on: req.db)
            .filter(\.$user.$id == userId)
            .filter(\.$usedAt == nil)
            .count() > 0
    }

    private func hasRegisteredPasskeys(for userId: UUID) async throws -> Bool {
        try await PasskeyCredential.query(on: req.db)
            .filter(\.$user.$id == userId)
            .count() > 0
    }

    private func matchingBackupCode(_ code: String, for userId: UUID) async throws -> BackupCode? {
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

    private func maskedEmail(_ email: String) -> String {
        let parts = email.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return email }

        let local = parts[0]
        let prefix = local.prefix(1)
        return "\(prefix)***@\(parts[1])"
    }

    private func maskedPhoneNumber(_ phoneNumber: String) -> String {
        let visiblePrefix = phoneNumber.prefix(2)
        let visibleSuffix = phoneNumber.suffix(2)
        let maskedCount = max(0, phoneNumber.count - 4)
        return "\(visiblePrefix)\(String(repeating: "*", count: maskedCount))\(visibleSuffix)"
    }

    private func ensurePhoneNumberIsAvailable(_ phoneNumber: String, excluding userID: UUID?) async throws {
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

    private func revokeActiveRefreshTokens(for userId: UUID) async throws {
        try await RefreshToken.query(on: req.db)
            .filter(\.$user.$id == userId)
            .filter(\.$isRevoked == false)
            .set(\.$isRevoked, to: true)
            .update()
    }

    private func syncVerifiedSocialProfile(_ profile: SocialIdentityProfile, to user: User, on db: (any Database)? = nil) async throws {
        let database = db ?? req.db
        try await ensureSocialAccountIsAvailable(profile, excluding: user.id, on: database)

        switch profile.provider {
        case .google:
            user.googleId = profile.subject
        case .apple:
            user.appleId = profile.subject
        }

        user.isEmailVerified = true
        user.verifiedAt = user.verifiedAt ?? Date()

        if user.avatarUrl == nil {
            user.avatarUrl = profile.avatarUrl
        }

        if user.provider == profile.provider.rawValue, profile.canRefreshPrimaryProfile {
            if let normalizedEmail = profile.normalizedEmail {
                try await ensureEmailIsAvailable(normalizedEmail, excluding: user.id, on: database)
                user.email = normalizedEmail
            }
            user.displayName = profile.displayName
            user.avatarUrl = profile.avatarUrl ?? user.avatarUrl
        }

        try await user.save(on: database)
    }

    private func findUserLinked(to profile: SocialIdentityProfile, on db: (any Database)? = nil) async throws -> User? {
        let database = db ?? req.db
        switch profile.provider {
        case .google:
            return try await User.query(on: database)
                .filter(\.$googleId == profile.subject)
                .first()
        case .apple:
            return try await User.query(on: database)
                .filter(\.$appleId == profile.subject)
                .first()
        }
    }

    private func ensureSocialAccountIsAvailable(_ profile: SocialIdentityProfile, excluding userID: UUID?, on db: (any Database)? = nil) async throws {
        if let existing = try await findUserLinked(to: profile, on: db),
           existing.id != userID {
            throw AuthError.socialAccountAlreadyLinked
        }
    }

    private func ensureEmailIsAvailable(_ email: String, excluding userID: UUID?, on db: (any Database)? = nil) async throws {
        let database = db ?? req.db
        guard let existing = try await User.query(on: database)
            .filter(\.$email == email)
            .first()
        else {
            return
        }

        if existing.id != userID {
            throw AuthError.emailAlreadyExists
        }
    }

    private func googleProfile(from idToken: String) async throws -> SocialIdentityProfile {
        guard !idToken.isEmpty else {
            throw Abort(.badRequest, reason: "idToken is required")
        }

        let profile = try await req.googleTokenVerifier.verifyToken(idToken)
        return SocialIdentityProfile(
            provider: .google,
            subject: profile.googleId,
            email: profile.email,
            displayName: profile.displayName,
            avatarUrl: profile.avatarUrl
        )
    }

    private func appleProfile(from idToken: String) async throws -> SocialIdentityProfile {
        guard !idToken.isEmpty else {
            throw Abort(.badRequest, reason: "idToken is required")
        }

        let profile = try await req.appleTokenVerifier.verifyToken(idToken)
        return SocialIdentityProfile(
            provider: .apple,
            subject: profile.appleId,
            email: profile.email,
            displayName: profile.displayName,
            avatarUrl: nil
        )
    }

    private func generateSecureToken() -> String {
        let key = SymmetricKey(size: .bits256)
        return key.withUnsafeBytes { Base64URL.encode(Data(Array($0))) }
    }

    private func generateOTPCode() -> String {
        let value = Int.random(in: 0...999_999)
        return String(format: "%06d", value)
    }

    private func generateBackupCode() -> String {
        let key = SymmetricKey(size: .bits256)
        let hex = key.withUnsafeBytes { bytes in
            Data(bytes.prefix(4)).map { String(format: "%02X", $0) }.joined()
        }
        let prefix = hex.prefix(4)
        let suffix = hex.suffix(4)
        return "\(prefix)-\(suffix)"
    }

    private func sha256(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }

    private func normalizeSixDigitCode(_ code: String, reason: String) throws -> String {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count == 6, normalized.allSatisfy(\.isNumber) else {
            throw Abort(.badRequest, reason: reason)
        }

        return normalized
    }

    private func normalizeBackupCode(_ code: String) throws -> String {
        let normalized = code
            .uppercased()
            .filter { $0.isLetter || $0.isNumber }

        guard normalized.count == 8 else {
            throw Abort(.badRequest, reason: "Backup code must be 8 characters")
        }

        return normalized
    }

    // MARK: - Validation

    private func validatePassword(_ password: String) throws {
        guard password.count >= PasswordPolicy.minLength else {
            throw Abort(.badRequest, reason: "Password must be at least \(PasswordPolicy.minLength) characters")
        }
        guard password.count <= PasswordPolicy.maxLength else {
            throw Abort(.badRequest, reason: "Password must not exceed \(PasswordPolicy.maxLength) characters")
        }
        guard password.contains(where: { $0.isUppercase }) else {
            throw Abort(.badRequest, reason: "Password must contain at least one uppercase letter")
        }
        guard password.contains(where: { $0.isLowercase }) else {
            throw Abort(.badRequest, reason: "Password must contain at least one lowercase letter")
        }
        guard password.contains(where: { $0.isNumber }) else {
            throw Abort(.badRequest, reason: "Password must contain at least one digit")
        }
    }

    private func validateDisplayName(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= DisplayNamePolicy.minLength && trimmed.count <= DisplayNamePolicy.maxLength else {
            throw Abort(.badRequest, reason: "Display name must be \(DisplayNamePolicy.minLength)–\(DisplayNamePolicy.maxLength) characters")
        }
    }

}
