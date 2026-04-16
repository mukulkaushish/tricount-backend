import Fluent
import SQLKit

/// Breaking: converts `group_invites` from per-email tokens to one singleton invite per group.
/// Drops `invitee_contact`, `expires_at`, `status` and their indexes; adds unique on `group_id`.
/// Existing invite rows are discarded.
struct AlterGroupInvitesSingleton: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("group_invites").delete()

        try await database.schema("group_invites")
            .id()
            .field("group_id", .uuid, .required)
            .field("invited_by", .uuid, .required)
            .field("invite_token", .string, .required)
            .field("created_at", .datetime, .required)
            .unique(on: "group_id")
            .unique(on: "invite_token")
            .create()

        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("CREATE INDEX idx_group_invites_invited_by ON group_invites (invited_by)").run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("group_invites").delete()
    }
}
