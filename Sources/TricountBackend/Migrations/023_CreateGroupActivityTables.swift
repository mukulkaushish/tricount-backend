import Fluent
import SQLKit

struct CreateGroupActivityTables: AsyncMigration {
    func prepare(on database: any Database) async throws {
        // Create group_invites table
        try await database.schema("group_invites")
            .id()
            .field("group_id", .uuid, .required)
            .field("invited_by", .uuid, .required)
            .field("invitee_contact", .string, .required)
            .field("invite_token", .string, .required)
            .field("status", .string, .required, .sql(.default("pending")))
            .field("expires_at", .datetime, .required)
            .field("created_at", .datetime, .required)
            .unique(on: "invite_token")
            .create()

        // Create group_activities table
        try await database.schema("group_activities")
            .id()
            .field("group_id", .uuid, .required)
            .field("actor_id", .uuid, .required)
            .field("type", .string, .required)
            .field("reference_id", .uuid)
            .field("metadata", .string)
            .field("created_at", .datetime, .required)
            .create()

        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("CREATE INDEX idx_group_invites_group_id ON group_invites (group_id)").run()
        try await sql.raw("CREATE INDEX idx_group_invites_invited_by ON group_invites (invited_by)").run()
        try await sql.raw("CREATE INDEX idx_group_invites_invitee_contact ON group_invites (invitee_contact)").run()
        try await sql.raw("CREATE INDEX idx_group_invites_status ON group_invites (status)").run()
        try await sql.raw("CREATE INDEX idx_group_activities_group_id ON group_activities (group_id)").run()
        try await sql.raw("CREATE INDEX idx_group_activities_actor_id ON group_activities (actor_id)").run()
        try await sql.raw("CREATE INDEX idx_group_activities_type ON group_activities (type)").run()
        try await sql.raw("CREATE INDEX idx_group_activities_created_at ON group_activities (created_at)").run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("group_activities").delete()
        try await database.schema("group_invites").delete()
    }
}
