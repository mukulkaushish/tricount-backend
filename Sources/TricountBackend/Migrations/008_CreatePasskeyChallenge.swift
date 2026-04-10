import Fluent

struct CreatePasskeyChallenge: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("passkey_challenges")
            .id()
            .field("user_id", .uuid, .references("users", "id", onDelete: .cascade))
            .field("flow", .string, .required)
            .field("challenge", .string, .required)
            .field("rp_id", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("used_at", .datetime)
            .field("created_at", .datetime)
            .unique(on: "challenge")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("passkey_challenges").delete()
    }
}
