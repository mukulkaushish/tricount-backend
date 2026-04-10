import Fluent

struct CreatePasswordResetOTP: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("password_reset_otps")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("email", .string, .required)
            .field("code_hash", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("is_used", .bool, .required)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("password_reset_otps").delete()
    }
}
