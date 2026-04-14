import Vapor

/// Composes the auth module from smaller route collections.
///
/// The external API remains under `/v1/auth/*`, but route ownership is split by
/// capability so the module can scale without a single giant controller.
struct AuthController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let auth = routes.documented().grouped("auth")

        try AuthSessionController().boot(routes: auth.section(.authSession))
        try AuthMFALoginController().boot(routes: auth.section(.authMFALogin))

        let protected = auth.bearerProtected()
        try AuthAccountController().boot(routes: protected.section(.authAccount))
        try AuthMFASettingsController().boot(routes: protected.section(.authMFASettings))
        try AuthPasskeyManagementController().boot(routes: protected.section(.authPasskeyManagement))
    }
}
