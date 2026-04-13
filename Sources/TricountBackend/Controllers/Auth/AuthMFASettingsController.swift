import Vapor

/// Handles authenticated MFA setup, enablement, recovery-code management,
/// and verified phone enrollment.
struct AuthMFASettingsController: DocumentedRouteCollection {
    func boot(routes: DocumentedRoutesBuilder) throws {
        routes.postData("mfa", "enable", use: enableMFA)
        routes.postData("mfa", "disable", use: disableMFA)
        routes.postData("mfa", "email", "enable", use: requestEmailMFAEnable)
        routes.postData("mfa", "email", "confirm-enable", use: confirmEmailMFAEnable)
        routes.postData("mfa", "email", "disable", use: disableEmailMFA)
        routes.postData("mfa", "authenticator-app", "setup", use: beginAuthenticatorAppMFASetup)
        routes.postData("mfa", "authenticator-app", "confirm-enable", use: confirmAuthenticatorAppMFAEnable)
        routes.postData("mfa", "authenticator-app", "disable", use: disableAuthenticatorAppMFA)
        routes.postData("mfa", "backup-codes", "generate", use: generateBackupCodes)
        routes.postData("mfa", "backup-codes", "regenerate", use: regenerateBackupCodes)
        routes.postData("phone", "request-verification", use: requestPhoneVerification)
        routes.postData("phone", "confirm-verification", use: confirmPhoneVerification)
        routes.postData("phone", "remove", use: removePhoneNumber)
    }

    @Sendable
    func enableMFA(req: Request, body: EnableMFARequest) async throws -> UserDTO {
        try await req.authService.enableMFA(dto: body)
    }

    @Sendable
    func disableMFA(req: Request) async throws -> UserDTO {
        try await req.authService.disableMFA()
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
    func generateBackupCodes(req: Request) async throws -> BackupCodesResponse {
        try await req.authService.generateBackupCodes()
    }

    @Sendable
    func regenerateBackupCodes(req: Request) async throws -> BackupCodesResponse {
        try await req.authService.regenerateBackupCodes()
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
}
