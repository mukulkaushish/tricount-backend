import Vapor
import Fluent

struct InviteController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let auth = routes.grouped(JWTAuthMiddleware())

        // Group-scoped invite routes (require membership)
        let groupInvites = auth
            .grouped("groups", ":id")
            .grouped(GroupMemberMiddleware())
            .grouped("invites")
        groupInvites.post(use: createInvite)
        groupInvites.get(use: listUserInvites)

        // Standalone invite routes (auth only, no group context)
        let inviteRoutes = auth.grouped("invites")
        inviteRoutes.post("accept", use: acceptInvite)
        inviteRoutes.get(":token", use: getInviteByToken)
    }

    func createInvite(req: Request) async throws -> Response {
        let ctx = try req.groupContext

        let input = try req.content.decode(CreateInviteRequest.self)
        let invite = try await req.services.invites.create(groupID: ctx.groupID, input, invitedByID: ctx.userID)

        let response = CreateInviteResponse(
            id: try invite.requireID(),
            groupId: ctx.groupID,
            inviteeContact: invite.inviteeContact,
            inviteToken: invite.inviteToken,
            status: invite.status,
            expiresAt: invite.expiresAt,
            createdAt: invite.createdAt ?? Date()
        )

        var httpResponse = Response(status: .created)
        try httpResponse.content.encode(response)
        return httpResponse
    }

    func listUserInvites(req: Request) async throws -> ListInvitesResponse {
        let userID = try req.authenticatedUserID

        let invites = try await req.services.invites.listForUser(userID: userID)
        var responses: [InviteListResponse] = []

        for invite in invites {
            let group = try await Group.requireFind(invite.$group.id, on: req.db)
            let inviter = try await User.requireFind(invite.$invitedBy.id, on: req.db)

            responses.append(InviteListResponse(
                id: try invite.requireID(),
                group: GroupBasicInfo(id: try group.requireID(), name: group.name, iconUrl: group.iconUrl),
                invitedBy: try inviter.toBasicInfo(),
                inviteeContact: invite.inviteeContact,
                status: invite.status,
                expiresAt: invite.expiresAt,
                createdAt: invite.createdAt ?? Date()
            ))
        }

        return ListInvitesResponse(invites: responses, total: responses.count)
    }

    func acceptInvite(req: Request) async throws -> AcceptInviteResponse {
        let userID = try req.authenticatedUserID
        let input = try req.content.decode(AcceptInviteRequest.self)

        try await req.services.invites.accept(input, userID: userID)
        let invite = try await req.services.invites.getByToken(input.inviteToken)

        return AcceptInviteResponse(
            groupId: invite.$group.id,
            status: "success",
            message: "Successfully joined the group"
        )
    }

    func getInviteByToken(req: Request) async throws -> CreateInviteResponse {
        guard let token = req.parameters.get("token", as: String.self) else {
            throw Abort(.badRequest, reason: "Invalid token")
        }

        let invite = try await req.services.invites.getByToken(token)

        return CreateInviteResponse(
            id: try invite.requireID(),
            groupId: invite.$group.id,
            inviteeContact: invite.inviteeContact,
            inviteToken: invite.inviteToken,
            status: invite.status,
            expiresAt: invite.expiresAt,
            createdAt: invite.createdAt ?? Date()
        )
    }
}
