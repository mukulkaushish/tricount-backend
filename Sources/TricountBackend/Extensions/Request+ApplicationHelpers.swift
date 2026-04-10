import Vapor

extension Request {
    var authService: AuthService {
        AuthService(req: self)
    }

    var authenticatedUserID: UUID {
        get throws {
            let payload = try jwtPayload
            guard let userID = UUID(uuidString: payload.userId) else {
                throw AuthError.invalidToken
            }
            return userID
        }
    }

    var isProductionEnvironment: Bool {
        application.environment == .production
    }

    func requireUUIDParameter(_ name: String) throws -> UUID {
        guard let rawValue = parameters.get(name),
              let value = UUID(uuidString: rawValue) else {
            throw Abort(.badRequest, reason: "Invalid or missing '\(name)' route parameter.")
        }

        return value
    }
}
