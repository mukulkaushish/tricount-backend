import Vapor
import Fluent

struct GroupController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let auth = routes
            .grouped("groups")
            .grouped(JWTAuthMiddleware())
            .grouped(VerifiedUserMiddleware())
            .grouped(IdempotencyMiddleware())

        // No group context needed
        auth.post(use: createGroup)
            .documented(auth: .bearer, response: .raw(CreateGroupResponse.self, status: .created), requestBody: .json(CreateGroupRequest.self))
        auth.get(use: listGroups)
            .documented(auth: .bearer, response: .raw(ListGroupsResponse.self))

        // Group-scoped: membership validated by middleware
        let scoped = auth.grouped(":id").grouped(GroupMemberMiddleware())
        scoped.get(use: getGroup)
            .documented(auth: .bearer, response: .raw(GroupDetailsResponse.self))
        scoped.put(use: updateGroup)
            .documented(auth: .bearer, response: .raw(GroupDetailsResponse.self), requestBody: .json(UpdateGroupRequest.self))
        scoped.delete(use: deleteGroup)
            .documented(auth: .bearer, response: .empty())

        scoped.post("members", use: addMember)
            .documented(auth: .bearer, response: .raw(AddMemberResponse.self, status: .created), requestBody: .json(AddMemberRequest.self))
        scoped.get("members", use: getMembers)
            .documented(auth: .bearer, response: .raw(ListMembersResponse.self))
        scoped.delete("members", ":userId", use: removeMember)
            .documented(auth: .bearer, response: .empty())
        scoped.put("members", ":userId", "role", use: updateMemberRole)
            .documented(auth: .bearer, response: .raw(GroupMemberResponse.self), requestBody: .json(UpdateMemberRequest.self))
        scoped.post("leave", use: leaveGroup)
            .documented(auth: .bearer, response: .empty())

        scoped.get("activities", use: listActivities)
            .documented(auth: .bearer, response: .raw(ListActivityLogsResponse.self))
        scoped.get("balance", use: getGroupBalance)
            .documented(auth: .bearer, response: .raw(GroupBalanceResponse.self))
        scoped.get("balance", "simplified", use: getSimplifiedDebts)
            .documented(auth: .bearer, response: .raw(SimplifyDebtsResponse.self))
    }

    // MARK: - Group CRUD

    func createGroup(req: Request) async throws -> Response {
        let userID = try req.authenticatedUserID
        let input = try req.content.decode(CreateGroupRequest.self)

        let group = try await req.services.groups.create(input, createdByID: userID)
        let groupID = try group.requireID()
        let response = CreateGroupResponse(
            id: groupID,
            name: group.name,
            iconUrl: group.iconUrl,
            createdBy: userID,
            simplifyDebtsEnabled: group.simplifyDebtsEnabled,
            allowMemberEdit: group.allowMemberEdit,
            allowMemberDelete: group.allowMemberDelete,
            memberCount: try await req.services.groups.activeMemberCount(groupID: groupID),
            createdAt: group.createdAt ?? Date()
        )

        let httpResponse = Response(status: .created)
        try httpResponse.content.encode(response)
        return httpResponse
    }

    func listGroups(req: Request) async throws -> ListGroupsResponse {
        let userID = try req.authenticatedUserID
        let svc = req.services.groups

        let groups = try await svc.list(userID: userID)
        let groupIDs = try groups.map { try $0.requireID() }
        let counts = try await svc.activeMemberCounts(groupIDs: groupIDs)

        let responses = try groups.map { group -> GroupListResponse in
            let id = try group.requireID()
            return GroupListResponse(
                id: id,
                name: group.name,
                iconUrl: group.iconUrl,
                memberCount: counts[id] ?? 0,
                createdAt: group.createdAt ?? Date()
            )
        }

        return ListGroupsResponse(groups: responses, total: responses.count)
    }

    func getGroup(req: Request) async throws -> GroupDetailsResponse {
        let ctx = try req.groupContext
        let group = try await req.services.groups.get(groupID: ctx.groupID)
        return try await buildDetailsResponse(req, group: group)
    }

    func updateGroup(req: Request) async throws -> GroupDetailsResponse {
        let ctx = try req.groupContext
        let input = try req.content.decode(UpdateGroupRequest.self)
        let group = try await req.services.groups.update(groupID: ctx.groupID, input, userID: ctx.userID)
        return try await buildDetailsResponse(req, group: group)
    }

    func deleteGroup(req: Request) async throws -> HTTPStatus {
        let ctx = try req.groupContext
        try await req.services.groups.delete(groupID: ctx.groupID, actorID: ctx.userID)
        return .noContent
    }

    // MARK: - Members

    func addMember(req: Request) async throws -> AddMemberResponse {
        let ctx = try req.groupContext
        let input = try req.content.decode(AddMemberRequest.self)
        let (member, user, invite) = try await req.services.groups.addMember(
            groupID: ctx.groupID,
            email: input.email,
            name: input.name,
            actorID: ctx.userID
        )

        req.setDevelopmentDebugHeader(name: "X-Debug-Invite-Token", value: invite.inviteToken)

        let requiresVerification = !user.isEmailVerified
        return AddMemberResponse(
            member: try member.toResponse(with: user),
            requiresVerification: requiresVerification,
            inviteToken: requiresVerification ? invite.inviteToken : nil
        )
    }

    func getMembers(req: Request) async throws -> ListMembersResponse {
        let ctx = try req.groupContext
        let members = try await req.services.groups.getMembers(groupID: ctx.groupID)
        let responses = try members.map { try $0.toResponse(with: $0.user) }
        return ListMembersResponse(members: responses, total: responses.count)
    }

    func removeMember(req: Request) async throws -> HTTPStatus {
        let ctx = try req.groupContext
        let targetUserID = try req.requireUUIDParameter("userId")
        try await req.services.groups.removeMember(groupID: ctx.groupID, userID: targetUserID, actorID: ctx.userID)
        return .ok
    }

    func updateMemberRole(req: Request) async throws -> GroupMemberResponse {
        let ctx = try req.groupContext
        let targetUserID = try req.requireUUIDParameter("userId")
        let input = try req.content.decode(UpdateMemberRequest.self)

        guard let role = input.role else {
            throw Abort(.badRequest, reason: "Role is required")
        }

        let member = try await req.services.groups.updateMemberRole(groupID: ctx.groupID, userID: targetUserID, role: role, actorID: ctx.userID)
        let user = try await User.requireFind(targetUserID, on: req.db)
        return try member.toResponse(with: user)
    }

    func leaveGroup(req: Request) async throws -> HTTPStatus {
        let ctx = try req.groupContext
        try await req.services.groups.leaveGroup(groupID: ctx.groupID, userID: ctx.userID)
        return .ok
    }

    // MARK: - Activities & Balances

    func listActivities(req: Request) async throws -> ListActivityLogsResponse {
        let ctx = try req.groupContext

        let activities = try await GroupActivity
            .query(on: req.db)
            .filter(\.$group.$id == ctx.groupID)
            .sort(\.$createdAt, .descending)
            .with(\.$actor)
            .all()

        let responses = try activities.map { activity in
            ActivityLogResponse(
                id: try activity.requireID(),
                actor: try activity.actor.toBasicInfo(),
                type: activity.type,
                referenceId: activity.referenceId,
                metadata: activity.metadata,
                createdAt: activity.createdAt ?? Date()
            )
        }

        return ListActivityLogsResponse(activities: responses, total: responses.count)
    }

    func getGroupBalance(req: Request) async throws -> GroupBalanceResponse {
        let ctx = try req.groupContext
        let balances = try await req.services.balances.getGroupBalances(groupID: ctx.groupID)
        return GroupBalanceResponse(groupId: ctx.groupID, balances: balances)
    }

    func getSimplifiedDebts(req: Request) async throws -> SimplifyDebtsResponse {
        let ctx = try req.groupContext
        let simplifications = try await req.services.balances.simplifyDebts(groupID: ctx.groupID)
        return SimplifyDebtsResponse(transactions: simplifications)
    }

    // MARK: - Private Helpers

    private func buildDetailsResponse(_ req: Request, group: Group) async throws -> GroupDetailsResponse {
        let groupID = try group.requireID()
        let createdByUser = try await User.requireFind(group.$createdBy.id, on: req.db, notFoundMessage: "Creator user not found")

        return GroupDetailsResponse(
            id: groupID,
            name: group.name,
            iconUrl: group.iconUrl,
            createdBy: try createdByUser.toBasicInfo(),
            simplifyDebtsEnabled: group.simplifyDebtsEnabled,
            allowMemberEdit: group.allowMemberEdit,
            allowMemberDelete: group.allowMemberDelete,
            memberCount: try await req.services.groups.activeMemberCount(groupID: groupID),
            createdAt: group.createdAt ?? Date(),
            updatedAt: group.updatedAt ?? Date()
        )
    }
}
