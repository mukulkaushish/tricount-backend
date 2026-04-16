import Fluent
import SQLKit

struct CreateLedgerEntry: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("ledger_entries")
            .id()
            .field("group_id", .uuid, .required)
            .field("user_id", .uuid, .required)
            .field("amount", .int, .required)
            .field("reference_type", .string, .required)
            .field("reference_id", .uuid, .required)
            .field("created_at", .datetime, .required)
            .create()

        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("CREATE INDEX idx_ledger_entries_group_id ON ledger_entries (group_id)").run()
        try await sql.raw("CREATE INDEX idx_ledger_entries_user_id ON ledger_entries (user_id)").run()
        try await sql.raw("CREATE INDEX idx_ledger_entries_reference ON ledger_entries (reference_type, reference_id)").run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("ledger_entries").delete()
    }
}
