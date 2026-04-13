import Vapor

/// Handles public second-step MFA verification and passkey login challenges.
struct AuthMFALoginController: DocumentedRouteCollection {
    func boot(routes: DocumentedRoutesBuilder) throws {
        routes.postData("mfa", "email", "verify", use: verifyEmailMFALogin)
        routes.postData("mfa", "phone", "verify", use: verifyPhoneMFALogin)
        routes.postData("mfa", "authenticator-app", "verify", use: verifyAuthenticatorAppMFALogin)
        routes.postData("mfa", "backup-codes", "verify", use: verifyBackupCodeMFALogin)
        routes.postData("mfa", "passkeys", "authenticate", "options", use: beginPasskeyMFALogin)
        routes.postData("mfa", "passkeys", "authenticate", "verify", use: finishPasskeyMFALogin)
        routes.postData("passkeys", "authenticate", "options", use: beginPasskeyAuthentication)
        routes.postData("passkeys", "authenticate", "verify", use: finishPasskeyAuthentication)
    }

    @Sendable
    func verifyEmailMFALogin(req: Request, body: MFALoginVerifyRequest) async throws -> AuthResponse {
        try await req.authService.verifyEmailMFALogin(dto: body)
    }

    @Sendable
    func verifyPhoneMFALogin(req: Request, body: MFALoginVerifyRequest) async throws -> AuthResponse {
        try await req.authService.verifyPhoneMFALogin(dto: body)
    }

    @Sendable
    func verifyAuthenticatorAppMFALogin(req: Request, body: MFALoginVerifyRequest) async throws -> AuthResponse {
        try await req.authService.verifyAuthenticatorAppMFALogin(dto: body)
    }

    @Sendable
    func verifyBackupCodeMFALogin(req: Request, body: MFALoginVerifyRequest) async throws -> AuthResponse {
        try await req.authService.verifyBackupCodeMFALogin(dto: body)
    }

    @Sendable
    func beginPasskeyMFALogin(
        req: Request,
        body: PasskeyMFALoginOptionsRequest
    ) async throws -> PasskeyAuthenticationOptionsResponse {
        try await req.authService.beginPasskeyMFALogin(dto: body)
    }

    @Sendable
    func finishPasskeyMFALogin(
        req: Request,
        body: PasskeyMFALoginVerificationRequest
    ) async throws -> AuthResponse {
        try await req.authService.finishPasskeyMFALogin(dto: body)
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
}
