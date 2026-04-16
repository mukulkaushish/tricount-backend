import Fluent
import Vapor

struct GroupService {
    let req: Request

    func create(_ input: CreateGroupRequest, createdByID: UUID) async throws -> Group {
        let group = Group(
            name: input.name,
            iconUrl: input.iconUrl,
            createdByID: createdByID
        )
        try await group.save(on: req.db)

        let member = GroupMember(
            groupID: try group.requireID(),
            userID: createdByID,
            role: "admin"
        )
        try await member.save(on: req.db)

        try await logActivity(groupID: try group.requireID(), actorID: createdByID, type: "GROUP_CREATED", referenceId: try group.requireID())

        return group
    }

    func get(groupID: UUID) async throws -> Group {
        try await Group.requireFind(groupID, on: req.db, notFoundMessage: "Group not found")
    }

    func update(groupID: UUID, _ input: UpdateGroupRequest, userID: UUID) async throws -> Group {
        let group = try await get(groupID: groupID)

        try await assertUserIsAdmin(groupID: groupID, userID: userID)

        if let name = input.name { group.name = name }
        if let iconUrl = input.iconUrl { group.iconUrl = iconUrl }
        if let simplify = input.simplifyDebtsEnabled { group.simplifyDebtsEnabled = simplify }
        if let edit = input.allowMemberEdit { group.allowMemberEdit = edit }
        if let delete = input.allowMemberDelete { group.allowMemberDelete = delete }

        try await group.update(on: req.db)
        try await logActivity(groupID: groupID, actorID: userID, type: "GROUP_UPDATED", referenceId: groupID)

        return group
    }

    func list(userID: UUID) async throws -> [Group] {
        let members = try await GroupMember
            .query(on: req.db)
            .filter(\.$user.$id == userID)
            .filter(\.$status == "active")
            .all()

        let groupIds = members.compactMap { $0.$group.id }
        guard !groupIds.isEmpty else { return [] }

        return try await Group
            .query(on: req.db)
            .filter(\.$id ~~ groupIds)
            .all()
    }

    func addMember(groupID: UUID, userID: UUID, role: String = "member", actorID: UUID) async throws -> GroupMember {
        try await assertUserIsAdmin(groupID: groupID, userID: actorID)

        let newMember = GroupMember(
            groupID: groupID,
            userID: userID,
            role: role
        )
        try await newMember.save(on: req.db)
        try await logActivity(groupID: groupID, actorID: actorID, type: "MEMBER_ADDED", referenceId: userID)

        return newMember
    }

    func getMember(groupID: UUID, userID: UUID) async throws -> GroupMember {
        guard let member = try await GroupMember
            .query(on: req.db)
            .filter(\.$group.$id == groupID)
            .filter(\.$user.$id == userID)
            .first() else {
            throw Abort(.notFound, reason: "Member not found")
        }
        return member
    }

    func removeMember(groupID: UUID, userID: UUID, actorID: UUID) async throws {
        let member = try await getMember(groupID: groupID, userID: userID)

        try await assertUserIsAdmin(groupID: groupID, userID: actorID)

        member.status = "removed"
        member.leftAt = Date()
        try await member.update(on: req.db)
        try await logActivity(groupID: groupID, actorID: actorID, type: "MEMBER_REMOVED", referenceId: userID)
    }

    func updateMemberRole(groupID: UUID, userID: UUID, role: String, actorID: UUID) async throws -> GroupMember {
        try await assertUserIsAdmin(groupID: groupID, userID: actorID)

        let member = try await getMember(groupID: groupID, userID: userID)

        member.role = role
        try await member.update(on: req.db)
        try await logActivity(groupID: groupID, actorID: actorID, type: "MEMBER_ROLE_UPDATED", referenceId: userID)

        return member
    }

    func leaveGroup(groupID: UUID, userID: UUID) async throws {
        let member = try await getMember(groupID: groupID, userID: userID)

        let balance = try await computeUserBalance(groupID: groupID, userID: userID)
        guard balance == 0 else {
            throw Abort(.badRequest, reason: "Cannot leave group with non-zero balance")
        }

        let adminCount = try await GroupMember
            .query(on: req.db)
            .filter(\.$group.$id == groupID)
            .filter(\.$role == "admin")
            .filter(\.$status == "active")
            .count()

        if member.role == "admin" && adminCount == 1 {
            throw Abort(.badRequest, reason: "Cannot leave group as the last admin")
        }

        member.status = "left"
        member.leftAt = Date()
        try await member.update(on: req.db)
        try await logActivity(groupID: groupID, actorID: userID, type: "MEMBER_LEFT", referenceId: userID)
    }

    func getMembers(groupID: UUID) async throws -> [GroupMember] {
        try await GroupMember
            .query(on: req.db)
            .filter(\.$group.$id == groupID)
            .filter(\.$status == "active")
            .all()
    }

    func activeMemberCount(groupID: UUID) async throws -> Int {
        try await GroupMember
            .query(on: req.db)
            .filter(\.$group.$id == groupID)
            .filter(\.$status == "active")
            .count()
    }

    func assertUserIsMember(groupID: UUID, userID: UUID) async throws {
        let member = try await GroupMember
            .query(on: req.db)
            .filter(\.$group.$id == groupID)
            .filter(\.$user.$id == userID)
            .filter(\.$status == "active")
            .first()

        guard member != nil else {
            throw Abort(.forbidden, reason: "User is not a member of this group")
        }
    }

    func assertUserIsAdmin(groupID: UUID, userID: UUID) async throws {
        guard let member = try await GroupMember
            .query(on: req.db)
            .filter(\.$group.$id == groupID)
            .filter(\.$user.$id == userID)
            .first() else {
            throw Abort(.forbidden, reason: "User is not a member of this group")
        }

        guard member.role == "admin" else {
            throw Abort(.forbidden, reason: "User must be an admin")
        }
    }

    func logActivity(groupID: UUID, actorID: UUID, type: String, referenceId: UUID? = nil, metadata: String? = nil) async throws {
        let activity = GroupActivity(
            groupID: groupID,
            actorID: actorID,
            type: type,
            referenceId: referenceId,
            metadata: metadata
        )
        try await activity.save(on: req.db)
    }

    func computeUserBalance(groupID: UUID, userID: UUID) async throws -> Int64 {
        let entries = try await LedgerEntry
            .query(on: req.db)
            .filter(\.$group.$id == groupID)
            .filter(\.$user.$id == userID)
            .all()

        return entries.reduce(0) { $0 + $1.amount }
    }
}
