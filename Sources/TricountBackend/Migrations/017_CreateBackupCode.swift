import Fluent

struct CreateBackupCode: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("backup_codes")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("code_hash", .string, .required)
            .field("used_at", .datetime)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("backup_codes").delete()
    }
}
