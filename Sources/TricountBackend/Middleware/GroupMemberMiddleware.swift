import Vapor
import Fluent

/// Context stored on the request after `GroupMemberMiddleware` validates membership.
/// Eliminates the repeated "extract userID → extract groupID → assert member" pattern
/// from every group-scoped handler.
struct GroupContext {
    let groupID: UUID
    let userID: UUID
    let member: GroupMember
}

private struct GroupContextKey: StorageKey {
    typealias Value = GroupContext
}

extension Request {
    /// Populated by `GroupMemberMiddleware`. Throws if accessed outside a group-scoped route.
    var groupContext: GroupContext {
        get throws {
            guard let ctx = storage[GroupContextKey.self] else {
                throw Abort(.internalServerError, reason: "GroupContext not available — is GroupMemberMiddleware applied?")
            }
            return ctx
        }
    }
}

/// Validates the authenticated user is an active member of the group identified by the `:id`
/// route parameter. On success, stores a `GroupContext` so handlers can access `req.groupContext`
/// without redundant queries.
struct GroupMemberMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let userID = try request.authenticatedUserID
        let groupID = try request.requireUUIDParameter("id")

        guard let member = try await GroupMember
            .query(on: request.db)
            .filter(\.$group.$id == groupID)
            .filter(\.$user.$id == userID)
            .filter(\.$status == "active")
            .first() else {
            throw Abort(.forbidden, reason: "User is not a member of this group")
        }

        request.storage[GroupContextKey.self] = GroupContext(
            groupID: groupID,
            userID: userID,
            member: member
        )

        return try await next.respond(to: request)
    }
}
