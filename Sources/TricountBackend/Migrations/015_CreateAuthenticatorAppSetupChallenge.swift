import Fluent

struct CreateAuthenticatorAppSetupChallenge: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("authenticator_app_setup_challenges")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("secret", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("is_used", .bool, .required)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("authenticator_app_setup_challenges").delete()
    }
}
