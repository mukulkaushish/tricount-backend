import Fluent

struct AddMethodToEmailMFAChallenges: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("email_mfa_challenges")
            .field("method", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("email_mfa_challenges")
            .deleteField("method")
            .update()
    }
}
