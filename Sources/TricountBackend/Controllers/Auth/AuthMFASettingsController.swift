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
        try await req.authServices.mfaSettings.enable(dto: body)
    }

    @Sendable
    func disableMFA(req: Request) async throws -> UserDTO {
        try await req.authServices.mfaSettings.disable()
    }

    @Sendable
    func requestEmailMFAEnable(req: Request) async throws -> MessageResponse {
        try await req.authServices.mfaSettings.requestEmailEnable()
    }

    @Sendable
    func confirmEmailMFAEnable(req: Request, body: ConfirmEmailMFAEnableRequest) async throws -> UserDTO {
        try await req.authServices.mfaSettings.confirmEmailEnable(dto: body)
    }

    @Sendable
    func disableEmailMFA(req: Request) async throws -> UserDTO {
        try await req.authServices.mfaSettings.disableEmail()
    }

    @Sendable
    func beginAuthenticatorAppMFASetup(req: Request) async throws -> AuthenticatorAppMFASetupResponse {
        try await req.authServices.mfaSettings.beginAuthenticatorAppSetup()
    }

    @Sendable
    func confirmAuthenticatorAppMFAEnable(
        req: Request,
        body: ConfirmEmailMFAEnableRequest
    ) async throws -> UserDTO {
        try await req.authServices.mfaSettings.confirmAuthenticatorAppEnable(dto: body)
    }

    @Sendable
    func disableAuthenticatorAppMFA(req: Request) async throws -> UserDTO {
        try await req.authServices.mfaSettings.disableAuthenticatorApp()
    }

    @Sendable
    func generateBackupCodes(req: Request) async throws -> BackupCodesResponse {
        try await req.authServices.mfaSettings.generateBackupCodes()
    }

    @Sendable
    func regenerateBackupCodes(req: Request) async throws -> BackupCodesResponse {
        try await req.authServices.mfaSettings.regenerateBackupCodes()
    }

    @Sendable
    func requestPhoneVerification(
        req: Request,
        body: SetupPhoneVerificationRequest
    ) async throws -> MessageResponse {
        try await req.authServices.mfaSettings.requestPhoneVerification(dto: body)
    }

    @Sendable
    func confirmPhoneVerification(
        req: Request,
        body: ConfirmPhoneVerificationRequest
    ) async throws -> UserDTO {
        try await req.authServices.mfaSettings.confirmPhoneVerification(dto: body)
    }

    @Sendable
    func removePhoneNumber(req: Request) async throws -> UserDTO {
        try await req.authServices.mfaSettings.removePhoneNumber()
    }
}
