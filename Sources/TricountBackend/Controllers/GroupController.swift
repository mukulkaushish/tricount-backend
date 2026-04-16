import Vapor
import Fluent

struct GroupController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let groups = routes.grouped("groups")

        groups.post(use: createGroup)
        groups.get(use: listGroups)
        groups.get(":id", use: getGroup)
        groups.put(":id", use: updateGroup)

        groups.post(":id", "members", use: addMember)
        groups.get(":id", "members", use: getMembers)
        groups.delete(":id", "members", ":userId", use: removeMember)
        groups.put(":id", "members", ":userId", "role", use: updateMemberRole)
        groups.post(":id", "leave", use: leaveGroup)

        groups.get(":id", "activities", use: listActivities)
        groups.get(":id", "balance", use: getGroupBalance)
        groups.get(":id", "balance", "simplified", use: getSimplifiedDebts)
    }

    func createGroup(req: Request) async throws -> Response {
        let payload = try req.auth.require(UserJWTPayload.self)
        let input = try req.content.decode(CreateGroupRequest.self)

        let group = try await GroupService.createGroup(req, input, createdByID: UUID(uuidString: payload.userId)!)
        let response = CreateGroupResponse(
            id: try group.requireID(),
            name: group.name,
            iconUrl: group.iconUrl,
            createdBy: UUID(uuidString: payload.userId)!,
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
        let payload = try req.auth.require(UserJWTPayload.self)

        let groups = try await GroupService.listGroups(req, userID: UUID(uuidString: payload.userId)!)
        var responses: [GroupListResponse] = []

        for group in groups {
            let groupID = try group.requireID()
            let memberCount = try await GroupMember
                .query(on: req.db)
                .filter(\.$group.$id == groupID)
                .filter(\.$status == "active")
                .count()

            responses.append(GroupListResponse(
                id: try group.requireID(),
                name: group.name,
                iconUrl: group.iconUrl,
                memberCount: memberCount,
                createdAt: group.createdAt ?? Date()
            ))
        }

        return ListGroupsResponse(groups: responses, total: responses.count)
    }

    func getGroup(req: Request) async throws -> GroupDetailsResponse {
        let payload = try req.auth.require(UserJWTPayload.self)
        guard let groupID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid group ID")
        }

        try await GroupService.assertUserIsMember(req, groupID: groupID, userID: UUID(uuidString: payload.userId)!)

        let group = try await GroupService.getGroup(req, groupID: groupID)
        guard let createdByUser = try await User.find(try group.$createdBy.id, on: req.db) else {
            throw Abort(.notFound, reason: "Creator user not found")
        }

        let memberCount = try await GroupMember
            .query(on: req.db)
            .filter(\.$group.$id == groupID)
            .filter(\.$status == "active")
            .count()

        return GroupDetailsResponse(
            id: try group.requireID(),
            name: group.name,
            iconUrl: group.iconUrl,
            createdBy: UserBasicInfo(
                id: try createdByUser.requireID(),
                displayName: createdByUser.displayName,
                email: createdByUser.email,
                avatarUrl: nil
            ),
            simplifyDebtsEnabled: group.simplifyDebtsEnabled,
            allowMemberEdit: group.allowMemberEdit,
            allowMemberDelete: group.allowMemberDelete,
            memberCount: memberCount,
            createdAt: group.createdAt ?? Date(),
            updatedAt: group.updatedAt ?? Date()
        )
    }

    func updateGroup(req: Request) async throws -> GroupDetailsResponse {
        let payload = try req.auth.require(UserJWTPayload.self)
        guard let groupID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid group ID")
        }

        let input = try req.content.decode(UpdateGroupRequest.self)
        let updatedGroup = try await GroupService.updateGroup(req, groupID: groupID, input, userID: UUID(uuidString: payload.userId)!)

        guard let createdByUser = try await User.find(try updatedGroup.$createdBy.id, on: req.db) else {
            throw Abort(.notFound, reason: "Creator user not found")
        }

        let memberCount = try await GroupMember
            .query(on: req.db)
            .filter(\.$group.$id == groupID)
            .filter(\.$status == "active")
            .count()

        return GroupDetailsResponse(
            id: try updatedGroup.requireID(),
            name: updatedGroup.name,
            iconUrl: updatedGroup.iconUrl,
            createdBy: UserBasicInfo(
                id: try createdByUser.requireID(),
                displayName: createdByUser.displayName,
                email: createdByUser.email,
                avatarUrl: nil
            ),
            simplifyDebtsEnabled: updatedGroup.simplifyDebtsEnabled,
            allowMemberEdit: updatedGroup.allowMemberEdit,
            allowMemberDelete: updatedGroup.allowMemberDelete,
            memberCount: memberCount,
            createdAt: updatedGroup.createdAt ?? Date(),
            updatedAt: updatedGroup.updatedAt ?? Date()
        )
    }

    func addMember(req: Request) async throws -> GroupMemberResponse {
        let payload = try req.auth.require(UserJWTPayload.self)
        guard let groupID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid group ID")
        }

        let input = try req.content.decode(AddMemberRequest.self)
        let member = try await GroupService.addMember(req, groupID: groupID, userID: input.userId, role: input.role ?? "member", actorID: UUID(uuidString: payload.userId)!)

        guard let memberUser = try await User.find(input.userId, on: req.db) else {
            throw Abort(.notFound, reason: "User not found")
        }

        return GroupMemberResponse(
            id: try member.requireID(),
            user: UserBasicInfo(
                id: try memberUser.requireID(),
                displayName: memberUser.displayName,
                email: memberUser.email,
                avatarUrl: nil
            ),
            role: member.role,
            status: member.status,
            joinedAt: member.joinedAt ?? Date(),
            leftAt: member.leftAt
        )
    }

    func getMembers(req: Request) async throws -> ListMembersResponse {
        let payload = try req.auth.require(UserJWTPayload.self)
        guard let groupID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid group ID")
        }

        try await GroupService.assertUserIsMember(req, groupID: groupID, userID: UUID(uuidString: payload.userId)!)

        let members = try await GroupService.getMembers(req, groupID: groupID)
        var responses: [GroupMemberResponse] = []

        for member in members {
            guard let memberUser = try await User.find(try member.$user.id, on: req.db) else {
                throw Abort(.notFound, reason: "User not found")
            }

            responses.append(GroupMemberResponse(
                id: try member.requireID(),
                user: UserBasicInfo(
                    id: try memberUser.requireID(),
                    displayName: memberUser.displayName,
                    email: memberUser.email,
                    avatarUrl: nil
                ),
                role: member.role,
                status: member.status,
                joinedAt: member.joinedAt ?? Date(),
                leftAt: member.leftAt
            ))
        }

        return ListMembersResponse(members: responses, total: responses.count)
    }

    func removeMember(req: Request) async throws -> HTTPStatus {
        let payload = try req.auth.require(UserJWTPayload.self)
        guard let groupID = req.parameters.get("id", as: UUID.self),
              let userID = req.parameters.get("userId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid parameters")
        }

        try await GroupService.removeMember(req, groupID: groupID, userID: userID, actorID: UUID(uuidString: payload.userId)!)
        return .ok
    }

    func updateMemberRole(req: Request) async throws -> GroupMemberResponse {
        let payload = try req.auth.require(UserJWTPayload.self)
        guard let groupID = req.parameters.get("id", as: UUID.self),
              let userID = req.parameters.get("userId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid parameters")
        }

        let input = try req.content.decode(UpdateMemberRequest.self)
        guard let role = input.role else {
            throw Abort(.badRequest, reason: "Role is required")
        }

        let member = try await GroupService.updateMemberRole(req, groupID: groupID, userID: userID, role: role, actorID: UUID(uuidString: payload.userId)!)

        guard let memberUser = try await User.find(userID, on: req.db) else {
            throw Abort(.notFound, reason: "User not found")
        }

        return GroupMemberResponse(
            id: try member.requireID(),
            user: UserBasicInfo(
                id: try memberUser.requireID(),
                displayName: memberUser.displayName,
                email: memberUser.email,
                avatarUrl: nil
            ),
            role: member.role,
            status: member.status,
            joinedAt: member.joinedAt ?? Date(),
            leftAt: member.leftAt
        )
    }

    func leaveGroup(req: Request) async throws -> HTTPStatus {
        let payload = try req.auth.require(UserJWTPayload.self)
        guard let groupID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid group ID")
        }

        try await GroupService.leaveGroup(req, groupID: groupID, userID: UUID(uuidString: payload.userId)!)
        return .ok
    }

    func listActivities(req: Request) async throws -> ListActivityLogsResponse {
        let payload = try req.auth.require(UserJWTPayload.self)
        guard let groupID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid group ID")
        }

        try await GroupService.assertUserIsMember(req, groupID: groupID, userID: UUID(uuidString: payload.userId)!)

        let activities = try await GroupActivity
            .query(on: req.db)
            .filter(\.$group.$id == groupID)
            .sort(\.$createdAt, .descending)
            .all()

        var responses: [ActivityLogResponse] = []

        for activity in activities {
            guard let actor = try await User.find(try activity.$actor.id, on: req.db) else {
                throw Abort(.notFound, reason: "Actor not found")
            }

            responses.append(ActivityLogResponse(
                id: try activity.requireID(),
                actor: UserBasicInfo(id: try actor.requireID(), displayName: actor.displayName, email: actor.email, avatarUrl: nil),
                type: activity.type,
                referenceId: activity.referenceId,
                metadata: activity.metadata,
                createdAt: activity.createdAt ?? Date()
            ))
        }

        return ListActivityLogsResponse(activities: responses, total: responses.count)
    }

    func getGroupBalance(req: Request) async throws -> GroupBalanceResponse {
        let payload = try req.auth.require(UserJWTPayload.self)
        guard let groupID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid group ID")
        }

        try await GroupService.assertUserIsMember(req, groupID: groupID, userID: UUID(uuidString: payload.userId)!)

        let balances = try await BalanceService.getGroupBalances(req, groupID: groupID)

        return GroupBalanceResponse(groupId: groupID, balances: balances)
    }

    func getSimplifiedDebts(req: Request) async throws -> SimplifyDebtsResponse {
        let payload = try req.auth.require(UserJWTPayload.self)
        guard let groupID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid group ID")
        }

        try await GroupService.assertUserIsMember(req, groupID: groupID, userID: UUID(uuidString: payload.userId)!)

        let simplifications = try await BalanceService.simplifyDebts(req, groupID: groupID)

        return SimplifyDebtsResponse(transactions: simplifications)
    }
}
