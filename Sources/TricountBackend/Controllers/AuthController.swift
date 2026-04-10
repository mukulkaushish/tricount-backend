import Vapor

/// Handles all `/v1/auth/*` endpoints defined in API_CONTRACT.md.
struct AuthController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let auth = routes.documented().grouped("auth")

        auth.postData("login", use: login)
            .rateLimit(.custom(
                identifier: "auth.login",
                limit: 10,
                windowSeconds: 900
            ))
        auth.postData("register", status: .created, use: register)

        auth.postData("forgot-password", use: forgotPassword)
            .rateLimit(.custom(
                identifier: "auth.forgot-password",
                limit: 3,
                windowSeconds: 3600,
                keyStrategy: .bodyEmail
            ))
        auth.postData("reset-password", use: resetPassword)
        auth.postData("google", use: googleSignIn)
        auth.postData("apple", use: appleSignIn)
        auth.postData("refresh", use: refresh)
        auth.postData("mfa", "email", "verify", use: verifyEmailMFALogin)
        auth.postData("mfa", "authenticator-app", "verify", use: verifyAuthenticatorAppMFALogin)
        auth.postData("passkeys", "authenticate", "options", use: beginPasskeyAuthentication)
        auth.postData("passkeys", "authenticate", "verify", use: finishPasskeyAuthentication)

        let protected = auth.bearerProtected()
        protected.getData("me", use: me)

        protected.postData("verify-profile", "google", use: verifyGoogleProfile)
        protected.postData("verify-profile", "apple", use: verifyAppleProfile)
        protected.postData("verify-profile", "email", "request-otp", use: requestEmailVerificationOTP)
            .rateLimit(.custom(
                identifier: "auth.verify-email-otp",
                limit: 5,
                windowSeconds: 3600
            ))
        protected.postData("verify-profile", "email", "confirm", use: confirmEmailVerificationOTP)
        protected.postData("mfa", "email", "enable", use: requestEmailMFAEnable)
        protected.postData("mfa", "email", "confirm-enable", use: confirmEmailMFAEnable)
        protected.postData("mfa", "email", "disable", use: disableEmailMFA)
        protected.postData("mfa", "authenticator-app", "setup", use: beginAuthenticatorAppMFASetup)
        protected.postData("mfa", "authenticator-app", "confirm-enable", use: confirmAuthenticatorAppMFAEnable)
        protected.postData("mfa", "authenticator-app", "disable", use: disableAuthenticatorAppMFA)
        protected.postData("phone", "request-verification", use: requestPhoneVerification)
        protected.postData("phone", "confirm-verification", use: confirmPhoneVerification)
        protected.postData("phone", "remove", use: removePhoneNumber)
        protected.getRaw("passkeys", use: listPasskeys)
        protected.postData("passkeys", "remove", use: removePasskey)
        protected.postData("passkeys", "reset", use: resetPasskeys)
        protected.postData("passkeys", "register", "options", use: beginPasskeyRegistration)
        protected.postData("passkeys", "register", "verify", status: .created, use: finishPasskeyRegistration)
        protected.postNoContent("logout", use: logout)
    }

    @Sendable
    func login(req: Request, body: LoginRequest) async throws -> AuthenticationResultResponse {
        try await req.authService.login(dto: body)
    }

    @Sendable
    func register(req: Request, body: RegisterRequest) async throws -> AuthResponse {
        try await req.authService.register(dto: body)
    }

    @Sendable
    func forgotPassword(req: Request, body: ForgotPasswordRequest) async throws -> MessageResponse {
        let normalizedEmail = AuthValidation.normalizeEmail(body.email)
        guard AuthValidation.isValidEmail(normalizedEmail) else {
            throw Abort(.badRequest, reason: "Invalid email format")
        }
        return try await req.authService.forgotPassword(dto: body)
    }

    @Sendable
    func resetPassword(req: Request, body: ResetPasswordRequest) async throws -> MessageResponse {
        try await req.authService.resetPassword(dto: body)
    }

    @Sendable
    func googleSignIn(req: Request, body: GoogleLoginRequest) async throws -> AuthenticationResultResponse {
        try await req.authService.googleSignIn(dto: body)
    }

    @Sendable
    func appleSignIn(req: Request, body: AppleLoginRequest) async throws -> AuthenticationResultResponse {
        try await req.authService.appleSignIn(dto: body)
    }

    @Sendable
    func refresh(req: Request, body: RefreshTokenRequest) async throws -> TokenRefreshResponse {
        try await req.authService.refresh(dto: body)
    }

    @Sendable
    func beginPasskeyAuthentication(
        req: Request,
        body: PasskeyAuthenticationOptionsRequest
    ) async throws -> PasskeyAuthenticationOptionsResponse {
        try await req.authService.beginPasskeyAuthentication(dto: body)
    }

    @Sendable
    func finishPasskeyAuthentication(
        req: Request,
        body: PasskeyAuthenticationVerificationRequest
    ) async throws -> AuthenticationResultResponse {
        try await req.authService.finishPasskeyAuthentication(dto: body)
    }

    @Sendable
    func verifyEmailMFALogin(req: Request, body: MFALoginVerifyRequest) async throws -> AuthResponse {
        try await req.authService.verifyEmailMFALogin(dto: body)
    }

    @Sendable
    func verifyAuthenticatorAppMFALogin(req: Request, body: MFALoginVerifyRequest) async throws -> AuthResponse {
        try await req.authService.verifyAuthenticatorAppMFALogin(dto: body)
    }

    @Sendable
    func me(req: Request) async throws -> UserDTO {
        UserDTO(from: try await req.authService.currentUser())
    }

    @Sendable
    func verifyGoogleProfile(req: Request, body: VerifyProfileRequest) async throws -> UserDTO {
        try await req.authService.verifyGoogleProfile(dto: body)
    }

    @Sendable
    func verifyAppleProfile(req: Request, body: VerifyProfileRequest) async throws -> UserDTO {
        try await req.authService.verifyAppleProfile(dto: body)
    }

    @Sendable
    func requestEmailVerificationOTP(req: Request) async throws -> MessageResponse {
        try await req.authService.requestEmailVerificationOTP()
    }

    @Sendable
    func confirmEmailVerificationOTP(req: Request, body: VerifyEmailOTPRequest) async throws -> UserDTO {
        try await req.authService.confirmEmailVerificationOTP(dto: body)
    }

    @Sendable
    func requestEmailMFAEnable(req: Request) async throws -> MessageResponse {
        try await req.authService.requestEmailMFAEnable()
    }

    @Sendable
    func confirmEmailMFAEnable(req: Request, body: ConfirmEmailMFAEnableRequest) async throws -> UserDTO {
        try await req.authService.confirmEmailMFAEnable(dto: body)
    }

    @Sendable
    func disableEmailMFA(req: Request) async throws -> UserDTO {
        try await req.authService.disableEmailMFA()
    }

    @Sendable
    func beginAuthenticatorAppMFASetup(req: Request) async throws -> AuthenticatorAppMFASetupResponse {
        try await req.authService.beginAuthenticatorAppMFASetup()
    }

    @Sendable
    func confirmAuthenticatorAppMFAEnable(
        req: Request,
        body: ConfirmEmailMFAEnableRequest
    ) async throws -> UserDTO {
        try await req.authService.confirmAuthenticatorAppMFAEnable(dto: body)
    }

    @Sendable
    func disableAuthenticatorAppMFA(req: Request) async throws -> UserDTO {
        try await req.authService.disableAuthenticatorAppMFA()
    }

    @Sendable
    func requestPhoneVerification(
        req: Request,
        body: SetupPhoneVerificationRequest
    ) async throws -> MessageResponse {
        try await req.authService.requestPhoneVerification(dto: body)
    }

    @Sendable
    func confirmPhoneVerification(
        req: Request,
        body: ConfirmPhoneVerificationRequest
    ) async throws -> UserDTO {
        try await req.authService.confirmPhoneVerification(dto: body)
    }

    @Sendable
    func removePhoneNumber(req: Request) async throws -> UserDTO {
        try await req.authService.removePhoneNumber()
    }

    @Sendable
    func listPasskeys(req: Request) async throws -> [PasskeyCredentialDTO] {
        try await req.authService.listPasskeys()
    }

    @Sendable
    func removePasskey(req: Request, body: RemovePasskeyRequest) async throws -> MessageResponse {
        try await req.authService.removePasskey(dto: body)
    }

    @Sendable
    func resetPasskeys(req: Request) async throws -> MessageResponse {
        try await req.authService.resetPasskeys()
    }

    @Sendable
    func beginPasskeyRegistration(req: Request) async throws -> PasskeyRegistrationOptionsResponse {
        try await req.authService.beginPasskeyRegistration()
    }

    @Sendable
    func finishPasskeyRegistration(
        req: Request,
        body: PasskeyRegistrationVerificationRequest
    ) async throws -> PasskeyCredentialDTO {
        try await req.authService.finishPasskeyRegistration(dto: body)
    }

    @Sendable
    func logout(req: Request) async throws {
        try await req.authService.logout()
    }
}
