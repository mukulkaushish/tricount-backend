import Vapor
import Fluent

/// Ensures the authenticated user has verified their email before proceeding.
/// Must be placed after `JWTAuthMiddleware` in the middleware chain.
struct VerifiedUserMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let userID = try request.authenticatedUserID
        let user = try await User.requireFind(userID, on: request.db)

        guard user.isEmailVerified else {
            throw AuthError.emailNotVerified
        }

        return try await next.respond(to: request)
    }
}
