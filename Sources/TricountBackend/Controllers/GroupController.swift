import Vapor
import Fluent

struct GroupController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let auth = routes.grouped("groups").grouped(JWTAuthMiddleware())

        // No group context needed
        auth.post(use: createGroup)
        auth.get(use: listGroups)

        // Group-scoped: membership validated by middleware
        let scoped = auth.grouped(":id").grouped(GroupMemberMiddleware())
        scoped.get(use: getGroup)
        scoped.put(use: updateGroup)

        scoped.post("members", use: addMember)
        scoped.get("members", use: getMembers)
        scoped.delete("members", ":userId", use: removeMember)
        scoped.put("members", ":userId", "role", use: updateMemberRole)
        scoped.post("leave", use: leaveGroup)

        scoped.get("activities", use: listActivities)
        scoped.get("balance", use: getGroupBalance)
        scoped.get("balance", "simplified", use: getSimplifiedDebts)
    }

    // MARK: - Group CRUD

    func createGroup(req: Request) async throws -> Response {
        let userID = try req.authenticatedUserID
        let input = try req.content.decode(CreateGroupRequest.self)

        let group = try await req.services.groups.create(input, createdByID: userID)
        let response = CreateGroupResponse(
            id: try group.requireID(),
            name: group.name,
            iconUrl: group.iconUrl,
            createdBy: userID,
            simplifyDebtsEnabled: group.simplifyDebtsEnabled,
            allowMemberEdit: group.allowMemberEdit,
            allowMemberDelete: group.allowMemberDelete,
            createdAt: group.createdAt ?? Date()
        )

        var httpResponse = Response(status: .created)
        try httpResponse.content.encode(response)
        return httpResponse
    }

    func listGroups(req: Request) async throws -> ListGroupsResponse {
        let userID = try req.authenticatedUserID
        let svc = req.services.groups

        let groups = try await svc.list(userID: userID)
        var responses: [GroupListResponse] = []

        for group in groups {
            let groupID = try group.requireID()
            responses.append(GroupListResponse(
                id: groupID,
                name: group.name,
                iconUrl: group.iconUrl,
                memberCount: try await svc.activeMemberCount(groupID: groupID),
                createdAt: group.createdAt ?? Date()
            ))
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

    // MARK: - Members

    func addMember(req: Request) async throws -> GroupMemberResponse {
        let ctx = try req.groupContext
        let input = try req.content.decode(AddMemberRequest.self)
        let member = try await req.services.groups.addMember(groupID: ctx.groupID, userID: input.userId, role: input.role ?? "member", actorID: ctx.userID)
        let user = try await User.requireFind(input.userId, on: req.db)
        return try member.toResponse(with: user)
    }

    func getMembers(req: Request) async throws -> ListMembersResponse {
        let ctx = try req.groupContext
        let members = try await req.services.groups.getMembers(groupID: ctx.groupID)

        var responses: [GroupMemberResponse] = []
        for member in members {
            let user = try await User.requireFind(member.$user.id, on: req.db)
            try responses.append(member.toResponse(with: user))
        }

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
            .all()

        var responses: [ActivityLogResponse] = []
        for activity in activities {
            let actor = try await User.requireFind(activity.$actor.id, on: req.db)
            responses.append(ActivityLogResponse(
                id: try activity.requireID(),
                actor: try actor.toBasicInfo(),
                type: activity.type,
                referenceId: activity.referenceId,
                metadata: activity.metadata,
                createdAt: activity.createdAt ?? Date()
            ))
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
