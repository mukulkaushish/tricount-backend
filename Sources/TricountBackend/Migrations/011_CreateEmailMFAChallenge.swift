import Fluent

struct CreateEmailMFAChallenge: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("email_mfa_challenges")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("purpose", .string, .required)
            .field("challenge_token_hash", .string)
            .field("code_hash", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("is_used", .bool, .required)
            .field("created_at", .datetime)
            .unique(on: "challenge_token_hash")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("email_mfa_challenges").delete()
    }
}
