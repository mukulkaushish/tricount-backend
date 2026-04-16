import Vapor
import Fluent

struct InviteController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let groups = routes.grouped("groups", ":id", "invites")

        groups.post(use: createInvite)
        groups.get(use: listUserInvites)

        let inviteRoutes = routes.grouped("invites")
        inviteRoutes.post("accept", use: acceptInvite)
        inviteRoutes.get(":token", use: getInviteByToken)
    }

    func createInvite(req: Request) async throws -> Response {
        let payload = try req.auth.require(UserJWTPayload.self)
        guard let groupID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid group ID")
        }

        let input = try req.content.decode(CreateInviteRequest.self)
        let invite = try await InviteService.createInvite(req, groupID: groupID, input, invitedByID: UUID(uuidString: payload.userId)!)

        guard let group = try await Group.find(groupID, on: req.db),
              let inviter = try await User.find(invite.$invitedBy.id, on: req.db) else {
            throw Abort(.notFound, reason: "Group or user not found")
        }

        let response = CreateInviteResponse(
            id: try invite.requireID(),
            groupId: groupID,
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
        let payload = try req.auth.require(UserJWTPayload.self)

        let invites = try await InviteService.listUserInvites(req, userID: UUID(uuidString: payload.userId)!)
        var responses: [InviteListResponse] = []

        for invite in invites {
            guard let group = try await Group.find(invite.$group.id, on: req.db),
                  let inviter = try await User.find(invite.$invitedBy.id, on: req.db) else {
                throw Abort(.notFound, reason: "Group or user not found")
            }

            responses.append(InviteListResponse(
                id: try invite.requireID(),
                group: GroupBasicInfo(id: try group.requireID(), name: group.name, iconUrl: group.iconUrl),
                invitedBy: UserBasicInfo(id: try inviter.requireID(), displayName: inviter.displayName, email: inviter.email, avatarUrl: nil),
                inviteeContact: invite.inviteeContact,
                status: invite.status,
                expiresAt: invite.expiresAt,
                createdAt: invite.createdAt ?? Date()
            ))
        }

        return ListInvitesResponse(invites: responses, total: responses.count)
    }

    func acceptInvite(req: Request) async throws -> AcceptInviteResponse {
        let payload = try req.auth.require(UserJWTPayload.self)
        let input = try req.content.decode(AcceptInviteRequest.self)

        try await InviteService.acceptInvite(req, input, userID: UUID(uuidString: payload.userId)!)

        let invite = try await InviteService.getInviteByToken(req, token: input.inviteToken)

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

        let invite = try await InviteService.getInviteByToken(req, token: token)

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
