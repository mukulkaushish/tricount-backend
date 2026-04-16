import Vapor
import Fluent

/// Read-only user lookups scoped to the authenticated caller. Currently exposes a single status probe that admins use
/// before adding someone to a group, so the UI can preview `exists` / `is_verified` / `is_placeholder`.
struct UserController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let auth = routes
            .grouped("users")
            .grouped(JWTAuthMiddleware())
            .grouped(VerifiedUserMiddleware())

        auth.get("status", use: getEmailStatus)
            .documented(auth: .bearer, response: .raw(UserStatusResponse.self))
            .rateLimit(.custom(identifier: "user-status", limit: 30, windowSeconds: 60))
    }

    func getEmailStatus(req: Request) async throws -> UserStatusResponse {
        guard let rawEmail = req.query[String.self, at: "email"] else {
            throw Abort(.badRequest, reason: "Query parameter 'email' is required")
        }

        let email = AuthValidation.normalizeEmail(rawEmail)
        guard AuthValidation.isValidEmail(email) else {
            throw Abort(.unprocessableEntity, reason: "Invalid email format")
        }

        guard let user = try await User.query(on: req.db)
            .filter(\.$email == email)
            .first() else {
            return UserStatusResponse(exists: false, isVerified: false, isPlaceholder: false, displayName: nil)
        }

        return UserStatusResponse(
            exists: true,
            isVerified: user.isEmailVerified,
            isPlaceholder: user.provider == "placeholder",
            displayName: user.displayName
        )
    }
}
