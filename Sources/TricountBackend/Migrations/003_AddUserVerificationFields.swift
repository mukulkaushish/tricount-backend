import Fluent

struct AddUserVerificationFields: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("users")
            .field("is_email_verified", .bool)
            .update()

        try await database.schema("users")
            .field("verified_at", .datetime)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("users")
            .deleteField("verified_at")
            .update()

        try await database.schema("users")
            .deleteField("is_email_verified")
            .update()
    }
}
