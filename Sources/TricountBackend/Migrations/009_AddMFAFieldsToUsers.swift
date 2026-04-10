import Fluent

struct AddMFAFieldsToUsers: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("users")
            .field("is_mfa_enabled", .bool)
            .update()

        try await database.schema("users")
            .field("mfa_method", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("users")
            .deleteField("mfa_method")
            .update()

        try await database.schema("users")
            .deleteField("is_mfa_enabled")
            .update()
    }
}
