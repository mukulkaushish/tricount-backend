import Fluent
import Vapor
import Foundation

struct InviteService {
    let req: Request

    private var groups: GroupService { req.services.groups }

    /// Returns the singleton invite for this group, creating it if missing. Admin only.
    func getOrCreate(groupID: UUID, actorID: UUID) async throws -> GroupInvite {
        try await groups.assertUserIsAdmin(groupID: groupID, userID: actorID)
        return try await ensureForGroup(groupID: groupID, invitedByID: actorID)
    }

    /// Internal variant that skips the admin check. Intended for trusted callers (e.g. `GroupService.addMember`)
    /// that have already established admin authority. Tolerates the `unique(group_id)` race by re-reading on conflict.
    func ensureForGroup(groupID: UUID, invitedByID: UUID) async throws -> GroupInvite {
        if let existing = try await GroupInvite.query(on: req.db)
            .filter(\.$group.$id == groupID)
            .first() {
            return existing
        }

        let invite = GroupInvite(
            groupID: groupID,
            invitedByID: invitedByID,
            inviteToken: UUID().uuidString
        )
        do {
            try await invite.save(on: req.db)
            try await groups.logActivity(groupID: groupID, actorID: invitedByID, type: "INVITE_CREATED", referenceId: try invite.requireID())
            return invite
        } catch {
            if let raced = try await GroupInvite.query(on: req.db)
                .filter(\.$group.$id == groupID)
                .first() {
                return raced
            }
            throw error
        }
    }

    /// Returns the singleton invite for this group without creating one. Caller must already be a member.
    func get(groupID: UUID) async throws -> GroupInvite? {
        try await GroupInvite.query(on: req.db)
            .filter(\.$group.$id == groupID)
            .first()
    }

    func getByToken(_ token: String) async throws -> GroupInvite {
        guard let invite = try await GroupInvite
            .query(on: req.db)
            .filter(\.$inviteToken == token)
            .first() else {
            throw Abort(.notFound, reason: "Invalid invite token")
        }
        return invite
    }

    /// Accepting user must already appear in the group's member list (added by admin). Idempotent for active members;
    /// reactivates rows that were marked `left` or `removed`.
    func accept(_ input: AcceptInviteRequest, userID: UUID) async throws -> UUID {
        let invite = try await getByToken(input.inviteToken)
        let groupID = invite.$group.id

        guard let existing = try await GroupMember.query(on: req.db)
            .filter(\.$group.$id == groupID)
            .filter(\.$user.$id == userID)
            .first() else {
            throw Abort(.forbidden, reason: "You are not on the member list for this group. Ask the group admin to add you.")
        }

        if existing.status != "active" {
            existing.status = "active"
            existing.leftAt = nil
            try await existing.update(on: req.db)
            try await groups.logActivity(groupID: groupID, actorID: userID, type: "INVITE_ACCEPTED", referenceId: try invite.requireID())
        }
        return groupID
    }
}
