import Fluent
import SQLKit

struct CreateGroupTables: AsyncMigration {
    func prepare(on database: any Database) async throws {
        // Create groups table
        try await database.schema("groups")
            .id()
            .field("name", .string, .required)
            .field("icon_url", .string)
            .field("created_by", .uuid, .required)
            .field("simplify_debts_enabled", .bool, .required, .sql(.default(false)))
            .field("allow_member_edit", .bool, .required, .sql(.default(false)))
            .field("allow_member_delete", .bool, .required, .sql(.default(false)))
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime, .required)
            .create()

        // Create group_members table
        try await database.schema("group_members")
            .id()
            .field("group_id", .uuid, .required)
            .field("user_id", .uuid, .required)
            .field("role", .string, .required, .sql(.default("member")))
            .field("status", .string, .required, .sql(.default("active")))
            .field("joined_at", .datetime, .required)
            .field("left_at", .datetime)
            .unique(on: "group_id", "user_id")
            .create()

        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("CREATE INDEX idx_groups_created_by ON `groups` (created_by)").run()
        try await sql.raw("CREATE INDEX idx_group_members_group_id ON group_members (group_id)").run()
        try await sql.raw("CREATE INDEX idx_group_members_user_id ON group_members (user_id)").run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("group_members").delete()
        try await database.schema("groups").delete()
    }
}
