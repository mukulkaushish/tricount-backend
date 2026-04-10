import Fluent

struct CreatePasskeyCredential: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("passkey_credentials")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("credential_id", .string, .required)
            .field("public_key", .string, .required)
            .field("sign_count", .int, .required)
            .field("aaguid", .string)
            .field("transports", .string)
            .field("last_used_at", .datetime)
            .field("created_at", .datetime)
            .unique(on: "credential_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("passkey_credentials").delete()
    }
}
