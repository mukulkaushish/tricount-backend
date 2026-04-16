import Vapor
import Fluent

struct InviteController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let auth = routes
            .grouped(JWTAuthMiddleware())
            .grouped(VerifiedUserMiddleware())
            .grouped(IdempotencyMiddleware())

        // Group-scoped: singleton invite (admin fetches to share)
        let groupInvite = auth
            .grouped("groups", ":id")
            .grouped(GroupMemberMiddleware())
            .grouped("invite")
        groupInvite.get(use: getGroupInvite)
            .documented(auth: .bearer, response: .raw(GroupInviteResponse.self))

        // Standalone invite routes
        let inviteRoutes = auth.grouped("invites")
        inviteRoutes.post("accept", use: acceptInvite)
            .documented(auth: .bearer, response: .raw(AcceptInviteResponse.self), requestBody: .json(AcceptInviteRequest.self))
        inviteRoutes.get(":token", use: getInviteByToken)
            .documented(auth: .bearer, response: .raw(InvitePreviewResponse.self))
    }

    func getGroupInvite(req: Request) async throws -> GroupInviteResponse {
        let ctx = try req.groupContext
        let invite = try await req.services.invites.getOrCreate(groupID: ctx.groupID, actorID: ctx.userID)
        req.setDevelopmentDebugHeader(name: "X-Debug-Invite-Token", value: invite.inviteToken)
        return GroupInviteResponse(
            id: try invite.requireID(),
            groupId: invite.$group.id,
            inviteToken: invite.inviteToken,
            invitedBy: invite.$invitedBy.id,
            createdAt: invite.createdAt ?? Date()
        )
    }

    func acceptInvite(req: Request) async throws -> AcceptInviteResponse {
        let userID = try req.authenticatedUserID
        let input = try req.content.decode(AcceptInviteRequest.self)
        let groupID = try await req.services.invites.accept(input, userID: userID)
        return AcceptInviteResponse(
            groupId: groupID,
            status: "success",
            message: "Successfully joined the group"
        )
    }

    func getInviteByToken(req: Request) async throws -> InvitePreviewResponse {
        guard let token = req.parameters.get("token", as: String.self) else {
            throw Abort(.badRequest, reason: "Invalid token")
        }

        let invite = try await req.services.invites.getByToken(token)
        async let groupQuery = Group.requireFind(invite.$group.id, on: req.db)
        async let inviterQuery = User.requireFind(invite.$invitedBy.id, on: req.db)
        let (group, inviter) = try await (groupQuery, inviterQuery)

        return InvitePreviewResponse(
            inviteToken: invite.inviteToken,
            group: GroupBasicInfo(id: try group.requireID(), name: group.name, iconUrl: group.iconUrl),
            invitedBy: try inviter.toBasicInfo()
        )
    }
}
