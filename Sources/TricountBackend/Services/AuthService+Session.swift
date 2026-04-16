import Fluent
import Vapor
import JWT
import Foundation

/// Session, token, and social sign-in workflows for the auth module.
extension AuthService {
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

        let hash = try await req.passwordHasher.hash(dto.password, on: req.eventLoop)
        let displayName = dto.displayName.trimmingCharacters(in: .whitespacesAndNewlines)

        if let existing = try await User.query(on: req.db)
            .filter(\.$email == email)
            .first() {
            guard existing.provider == "placeholder" else {
                throw AuthError.emailAlreadyExists
            }
            existing.passwordHash = hash
            existing.displayName = displayName
            existing.provider = "email"
            try await existing.save(on: req.db)
            return try await generateTokenPair(for: existing)
        }

        let user = User(
            email: email,
            passwordHash: hash,
            displayName: displayName,
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

    // MARK: - Session Helpers

    func signIn(with profile: SocialIdentityProfile) async throws -> AuthenticationResultResponse {
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

    func completePrimaryAuthentication(for user: User) async throws -> AuthenticationResultResponse {
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

    func generateTokenPair(for user: User) async throws -> AuthResponse {
        let (accessToken, rawRefreshToken) = try await issueTokens(for: user)
        return AuthResponse(
            accessToken: accessToken,
            refreshToken: rawRefreshToken,
            expiresIn: Int(TokenLifetime.accessToken),
            user: UserDTO(from: user)
        )
    }

    func issueTokens(for user: User) async throws -> (accessToken: String, refreshToken: String) {
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

    func revokeActiveRefreshTokens(for userId: UUID) async throws {
        try await RefreshToken.query(on: req.db)
            .filter(\.$user.$id == userId)
            .filter(\.$isRevoked == false)
            .set(\.$isRevoked, to: true)
            .update()
    }

    // MARK: - Social Profile Helpers

    func syncVerifiedSocialProfile(
        _ profile: SocialIdentityProfile,
        to user: User,
        on db: (any Database)? = nil
    ) async throws {
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

        // Placeholder users (added to a group before signing up) adopt the social provider on first sign-in.
        if user.provider == "placeholder" {
            user.provider = profile.provider.rawValue
            if user.displayName.isEmpty {
                user.displayName = profile.displayName
            }
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

    func findUserLinked(to profile: SocialIdentityProfile, on db: (any Database)? = nil) async throws -> User? {
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

    func ensureSocialAccountIsAvailable(
        _ profile: SocialIdentityProfile,
        excluding userID: UUID?,
        on db: (any Database)? = nil
    ) async throws {
        if let existing = try await findUserLinked(to: profile, on: db),
           existing.id != userID {
            throw AuthError.socialAccountAlreadyLinked
        }
    }

    func ensureEmailIsAvailable(_ email: String, excluding userID: UUID?, on db: (any Database)? = nil) async throws {
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

    func googleProfile(from idToken: String) async throws -> SocialIdentityProfile {
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

    func appleProfile(from idToken: String) async throws -> SocialIdentityProfile {
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
}
