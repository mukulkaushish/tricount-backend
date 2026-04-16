import Fluent
import Vapor
import Foundation

struct InviteService {
    let req: Request

    private var groups: GroupService { req.services.groups }

    func create(groupID: UUID, _ input: CreateInviteRequest, invitedByID: UUID) async throws -> GroupInvite {
        try await groups.assertUserIsAdmin(groupID: groupID, userID: invitedByID)

        let expiresAt = Date().addingTimeInterval(7 * 24 * 60 * 60)
        let invite = GroupInvite(
            groupID: groupID,
            invitedByID: invitedByID,
            inviteeContact: input.inviteeContact,
            inviteToken: UUID().uuidString,
            status: "pending",
            expiresAt: expiresAt
        )
        try await invite.save(on: req.db)

        try await groups.logActivity(groupID: groupID, actorID: invitedByID, type: "INVITE_CREATED", referenceId: try invite.requireID())

        return invite
    }

    func getByToken(_ token: String) async throws -> GroupInvite {
        guard let invite = try await GroupInvite
            .query(on: req.db)
            .filter(\.$inviteToken == token)
            .first() else {
            throw Abort(.notFound, reason: "Invalid invite token")
        }

        guard invite.expiresAt > Date() else {
            throw Abort(.badRequest, reason: "Invite has expired")
        }

        guard invite.status == "pending" else {
            throw Abort(.badRequest, reason: "Invite already used")
        }

        return invite
    }

    func accept(_ input: AcceptInviteRequest, userID: UUID) async throws {
        let invite = try await getByToken(input.inviteToken)

        let existingMember = try await GroupMember
            .query(on: req.db)
            .filter(\.$group.$id == invite.$group.id)
            .filter(\.$user.$id == userID)
            .first()

        if let existing = existingMember {
            existing.status = "active"
            try await existing.update(on: req.db)
        } else {
            let member = GroupMember(
                groupID: invite.$group.id,
                userID: userID,
                role: "member",
                status: "active"
            )
            try await member.save(on: req.db)
        }

        invite.status = "accepted"
        try await invite.update(on: req.db)

        try await groups.logActivity(groupID: invite.$group.id, actorID: userID, type: "INVITE_ACCEPTED", referenceId: try invite.requireID())
    }

    func listForUser(userID: UUID) async throws -> [GroupInvite] {
        try await GroupInvite
            .query(on: req.db)
            .filter(\.$inviteeContact != "")
            .filter(\.$status == "pending")
            .filter(\.$expiresAt > Date())
            .all()
    }
}
