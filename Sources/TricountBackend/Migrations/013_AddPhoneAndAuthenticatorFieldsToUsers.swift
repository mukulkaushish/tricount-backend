import Fluent

struct AddPhoneAndAuthenticatorFieldsToUsers: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("users")
            .field("phone_number", .string)
            .update()

        try await database.schema("users")
            .field("is_phone_verified", .bool)
            .update()

        try await database.schema("users")
            .field("phone_verified_at", .datetime)
            .update()

        try await database.schema("users")
            .field("totp_secret", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("users")
            .deleteField("totp_secret")
            .update()

        try await database.schema("users")
            .deleteField("phone_verified_at")
            .update()

        try await database.schema("users")
            .deleteField("is_phone_verified")
            .update()

        try await database.schema("users")
            .deleteField("phone_number")
            .update()
    }
}
