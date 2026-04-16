import Fluent
import SQLKit

struct CreateGroup: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("groups")
            .id()
            .field("name", .string, .required)
            .field("icon_url", .string)
            .field("created_by", .uuid, .required)
            .field("simplify_debts_enabled", .bool, .required, .sql(.default(true)))
            .field("allow_member_edit", .bool, .required, .sql(.default(true)))
            .field("allow_member_delete", .bool, .required, .sql(.default(true)))
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime, .required)
            .create()

        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("CREATE INDEX idx_groups_created_by ON `groups` (created_by)").run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("groups").delete()
    }
}
