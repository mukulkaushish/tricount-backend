import Fluent
import Vapor

struct GroupService {
    let req: Request

    private static let maxGroupNameLength = 100
    static let validRoles: Set<String> = ["admin", "member"]

    func create(_ input: CreateGroupRequest, createdByID: UUID) async throws -> Group {
        let name = try Self.validateGroupName(input.name)

        let group = Group(
            name: name,
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

        if let rawName = input.name {
            group.name = try Self.validateGroupName(rawName)
        }
        if let iconUrl = input.iconUrl { group.iconUrl = iconUrl }
        if let simplify = input.simplifyDebtsEnabled { group.simplifyDebtsEnabled = simplify }
        if let edit = input.allowMemberEdit { group.allowMemberEdit = edit }
        if let delete = input.allowMemberDelete { group.allowMemberDelete = delete }

        try await group.update(on: req.db)
        try await logActivity(groupID: groupID, actorID: userID, type: "GROUP_UPDATED", referenceId: groupID)

        return group
    }

    /// Deletes a group and all its child rows in a single transaction. Only the user who originally created the group
    /// is allowed to call this, and only when every member's ledger balance is zero.
    func delete(groupID: UUID, actorID: UUID) async throws {
        let group = try await get(groupID: groupID)

        guard group.$createdBy.id == actorID else {
            throw Abort(.forbidden, reason: "Only the group creator can delete the group")
        }

        let balances = try await req.services.balances.getGroupBalances(groupID: groupID)
        if let unsettled = balances.first(where: { $0.balance != 0 }) {
            throw Abort(.badRequest, reason: "Group cannot be deleted while balances are unsettled (e.g. user \(unsettled.userId) has balance \(unsettled.balance))")
        }

        try await req.db.transaction { db in
            let expenseIDs = try await Expense.query(on: db)
                .filter(\.$group.$id == groupID)
                .all(\.$id)

            if !expenseIDs.isEmpty {
                try await ExpenseSplit.query(on: db)
                    .filter(\.$expense.$id ~~ expenseIDs)
                    .delete()
            }

            try await LedgerEntry.query(on: db)
                .filter(\.$group.$id == groupID)
                .delete()

            try await Payment.query(on: db)
                .filter(\.$group.$id == groupID)
                .delete()

            try await Expense.query(on: db)
                .filter(\.$group.$id == groupID)
                .delete(force: true)

            try await GroupActivity.query(on: db)
                .filter(\.$group.$id == groupID)
                .delete()

            try await GroupInvite.query(on: db)
                .filter(\.$group.$id == groupID)
                .delete()

            try await GroupMember.query(on: db)
                .filter(\.$group.$id == groupID)
                .delete()

            try await group.delete(on: db)
        }
    }

    private static func validateGroupName(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw Abort(.badRequest, reason: "Group name cannot be empty")
        }
        guard trimmed.count <= maxGroupNameLength else {
            throw Abort(.badRequest, reason: "Group name must be \(maxGroupNameLength) characters or fewer")
        }
        return trimmed
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

    /// Resolves an email to an existing User or creates a placeholder (unverified) User, then adds them to the group
    /// and triggers an invitation email. Returns the membership row, the resolved User, and the group's singleton
    /// invite so callers can relay verification state without re-fetching.
    func addMember(groupID: UUID, email: String, name: String?, actorID: UUID) async throws -> (member: GroupMember, user: User, invite: GroupInvite) {
        try await assertUserIsAdmin(groupID: groupID, userID: actorID)

        let normalizedEmail = AuthValidation.normalizeEmail(email)
        guard AuthValidation.isValidEmail(normalizedEmail) else {
            throw Abort(.unprocessableEntity, reason: "Invalid email format")
        }

        let user: User
        if let existing = try await User.query(on: req.db)
            .filter(\.$email == normalizedEmail)
            .first() {
            user = existing
        } else {
            let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmedName.isEmpty else {
                throw Abort(.badRequest, reason: "Name is required when inviting a new user")
            }
            user = try await createPlaceholderUser(email: normalizedEmail, displayName: trimmedName)
        }

        let userID = try user.requireID()

        // Explicit self-add short circuit — avoids relying on membership lookup collation edge cases.
        guard userID != actorID else {
            throw Abort(.conflict, reason: "You are already a member of this group")
        }

        // Defense-in-depth: reject when an active membership already exists for this email (resolved user_id). This
        // runs before `upsertMembership` so the error path is unambiguous even if the later reactivation branch changes.
        let activeExisting = try await GroupMember.query(on: req.db)
            .filter(\.$group.$id == groupID)
            .filter(\.$user.$id == userID)
            .filter(\.$status == "active")
            .first()
        if activeExisting != nil {
            throw Abort(.conflict, reason: "A member with email \(normalizedEmail) already exists in this group")
        }

        let member = try await upsertMembership(groupID: groupID, userID: userID)

        try await logActivity(groupID: groupID, actorID: actorID, type: "MEMBER_ADDED", referenceId: userID)

        // Singleton invite: trusted caller already verified admin authority above.
        let invite = try await req.services.invites.ensureForGroup(groupID: groupID, invitedByID: actorID)
        await dispatchInvitationEmail(invitee: user, actorID: actorID, groupID: groupID, invite: invite)
        return (member, user, invite)
    }

    /// Invitation email is best-effort. A delivery failure must not roll back the membership change.
    private func dispatchInvitationEmail(invitee: User, actorID: UUID, groupID: UUID, invite: GroupInvite) async {
        do {
            let group = try await Group.requireFind(groupID, on: req.db)
            let inviter = try await User.requireFind(actorID, on: req.db)
            try await req.authEmailDispatcher.sendGroupInvitation(
                to: invitee.email,
                inviteeName: invitee.displayName,
                groupName: group.name,
                inviterName: inviter.displayName,
                inviteToken: invite.inviteToken
            )
        } catch {
            req.logger.error("Group invitation email dispatch failed", metadata: [
                "group_id": .string(groupID.uuidString),
                "invitee_email": .string(invitee.email),
                "error": .string(String(describing: error))
            ])
        }
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
        try await assertUserIsAdmin(groupID: groupID, userID: actorID)

        guard actorID != userID else {
            throw Abort(.badRequest, reason: "Use the leave-group endpoint to remove yourself")
        }

        let member = try await getMember(groupID: groupID, userID: userID)

        if member.role == "admin" {
            let adminCount = try await activeAdminCount(groupID: groupID)
            guard adminCount > 1 else {
                throw Abort(.badRequest, reason: "Cannot remove the last admin of the group")
            }
        }

        let balance = try await computeUserBalance(groupID: groupID, userID: userID)
        guard balance == 0 else {
            throw Abort(.badRequest, reason: "Cannot remove a member with a non-zero balance")
        }

        member.status = "removed"
        member.leftAt = Date()
        try await member.update(on: req.db)
        try await logActivity(groupID: groupID, actorID: actorID, type: "MEMBER_REMOVED", referenceId: userID)
    }

    func updateMemberRole(groupID: UUID, userID: UUID, role: String, actorID: UUID) async throws -> GroupMember {
        try await assertUserIsAdmin(groupID: groupID, userID: actorID)

        guard Self.validRoles.contains(role) else {
            throw Abort(.badRequest, reason: "Role must be one of: \(Self.validRoles.sorted().joined(separator: ", "))")
        }

        let member = try await getMember(groupID: groupID, userID: userID)

        if member.role == role {
            return member
        }

        // Prevent an admin from demoting themselves (use leave-group or ask another admin) and stripping the last admin.
        if member.role == "admin" && role != "admin" {
            if actorID == userID {
                throw Abort(.badRequest, reason: "Admins cannot demote themselves")
            }
            let adminCount = try await activeAdminCount(groupID: groupID)
            guard adminCount > 1 else {
                throw Abort(.badRequest, reason: "Cannot demote the last admin of the group")
            }
        }

        member.role = role
        try await member.update(on: req.db)
        try await logActivity(groupID: groupID, actorID: actorID, type: "MEMBER_ROLE_UPDATED", referenceId: userID)

        return member
    }

    private func activeAdminCount(groupID: UUID) async throws -> Int {
        try await GroupMember
            .query(on: req.db)
            .filter(\.$group.$id == groupID)
            .filter(\.$role == "admin")
            .filter(\.$status == "active")
            .count()
    }

    func leaveGroup(groupID: UUID, userID: UUID) async throws {
        let member = try await getMember(groupID: groupID, userID: userID)

        let balance = try await computeUserBalance(groupID: groupID, userID: userID)
        guard balance == 0 else {
            throw Abort(.badRequest, reason: "Cannot leave group with non-zero balance")
        }

        if member.role == "admin" {
            let adminCount = try await activeAdminCount(groupID: groupID)
            guard adminCount > 1 else {
                throw Abort(.badRequest, reason: "Cannot leave group as the last admin")
            }
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
            .with(\.$user)
            .all()
    }

    func activeMemberCount(groupID: UUID) async throws -> Int {
        try await GroupMember
            .query(on: req.db)
            .filter(\.$group.$id == groupID)
            .filter(\.$status == "active")
            .count()
    }

    /// Batched version of `activeMemberCount` — single query, O(groupIds) in memory. Missing keys default to 0.
    func activeMemberCounts(groupIDs: [UUID]) async throws -> [UUID: Int] {
        guard !groupIDs.isEmpty else { return [:] }
        let members = try await GroupMember
            .query(on: req.db)
            .filter(\.$group.$id ~~ groupIDs)
            .filter(\.$status == "active")
            .all()
        var counts: [UUID: Int] = [:]
        for member in members {
            counts[member.$group.id, default: 0] += 1
        }
        return counts
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

    /// Batched membership check — single query per call regardless of `userIDs.count`.
    /// Throws if any id is missing or inactive. Safe for empty input (no-op).
    func assertUsersAreMembers(groupID: UUID, userIDs: [UUID]) async throws {
        let unique = Array(Set(userIDs))
        guard !unique.isEmpty else { return }

        let active = try await GroupMember
            .query(on: req.db)
            .filter(\.$group.$id == groupID)
            .filter(\.$user.$id ~~ unique)
            .filter(\.$status == "active")
            .all(\.$user.$id)
        let activeSet = Set(active)

        let missing = unique.filter { !activeSet.contains($0) }
        if !missing.isEmpty {
            throw Abort(.forbidden, reason: "Not all users are active members of this group: \(missing.map(\.uuidString).joined(separator: ", "))")
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

    /// Creates a placeholder user. If a concurrent writer beats us to the `users.email` unique index, swallow the
    /// duplicate and return whichever row actually landed in the DB.
    private func createPlaceholderUser(email: String, displayName: String) async throws -> User {
        let user = User(
            email: email,
            displayName: displayName,
            isEmailVerified: false,
            provider: "placeholder"
        )
        do {
            try await user.save(on: req.db)
            return user
        } catch {
            if let raced = try await User.query(on: req.db)
                .filter(\.$email == email)
                .first() {
                return raced
            }
            throw error
        }
    }

    /// Creates or reactivates a membership row. Handles the `(group_id, user_id)` unique race by re-reading the row
    /// the competing writer just produced, then applying the reactivation logic uniformly.
    private func upsertMembership(groupID: UUID, userID: UUID) async throws -> GroupMember {
        if let existing = try await GroupMember.query(on: req.db)
            .filter(\.$group.$id == groupID)
            .filter(\.$user.$id == userID)
            .first() {
            return try await reactivate(existing)
        }

        let fresh = GroupMember(groupID: groupID, userID: userID, role: "member")
        do {
            try await fresh.save(on: req.db)
            return fresh
        } catch {
            guard let raced = try await GroupMember.query(on: req.db)
                .filter(\.$group.$id == groupID)
                .filter(\.$user.$id == userID)
                .first() else {
                throw error
            }
            return try await reactivate(raced)
        }
    }

    private func reactivate(_ member: GroupMember) async throws -> GroupMember {
        if member.status == "active" {
            throw Abort(.conflict, reason: "User is already a member of this group")
        }
        member.status = "active"
        member.leftAt = nil
        member.role = "member"
        try await member.update(on: req.db)
        return member
    }
}
