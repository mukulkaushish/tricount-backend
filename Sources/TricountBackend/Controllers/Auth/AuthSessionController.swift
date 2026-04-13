import Vapor

/// Handles public authentication entry points such as login, registration,
/// refresh, password reset, and social sign-in.
struct AuthSessionController: DocumentedRouteCollection {
    func boot(routes: DocumentedRoutesBuilder) throws {
        routes.postData("login", use: login)
            .rateLimit(.custom(
                identifier: "auth.login",
                limit: 10,
                windowSeconds: 900
            ))
        routes.postData("register", status: .created, use: register)
        routes.postData("forgot-password", use: forgotPassword)
            .rateLimit(.custom(
                identifier: "auth.forgot-password",
                limit: 3,
                windowSeconds: 3600,
                keyStrategy: .bodyEmail
            ))
        routes.postData("reset-password", use: resetPassword)
        routes.postData("google", use: googleSignIn)
        routes.postData("apple", use: appleSignIn)
        routes.postData("refresh", use: refresh)
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

        try await req.authService.forgotPassword(dto: body)
        return MessageResponse(message: "If the account exists, a password reset link will be sent.")
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
}
