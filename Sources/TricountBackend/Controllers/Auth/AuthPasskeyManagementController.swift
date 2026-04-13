import Vapor

/// Handles authenticated passkey enrollment and lifecycle management.
struct AuthPasskeyManagementController: DocumentedRouteCollection {
    func boot(routes: DocumentedRoutesBuilder) throws {
        routes.getRaw("passkeys", use: listPasskeys)
        routes.postData("passkeys", "remove", use: removePasskey)
        routes.postData("passkeys", "reset", use: resetPasskeys)
        routes.postData("passkeys", "register", "options", use: beginPasskeyRegistration)
        routes.postData("passkeys", "register", "verify", status: .created, use: finishPasskeyRegistration)
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
}
