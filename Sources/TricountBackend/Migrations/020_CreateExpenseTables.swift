import Fluent
import SQLKit

struct CreateExpenseTables: AsyncMigration {
    func prepare(on database: any Database) async throws {
        // Create expenses table
        try await database.schema("expenses")
            .id()
            .field("group_id", .uuid, .required)
            .field("paid_by", .uuid, .required)
            .field("amount", .int, .required)
            .field("currency", .string, .required, .sql(.default("INR")))
            .field("title", .string, .required)
            .field("notes", .string)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime, .required)
            .field("deleted_at", .datetime)
            .create()

        // Create expense_splits table
        try await database.schema("expense_splits")
            .id()
            .field("expense_id", .uuid, .required)
            .field("user_id", .uuid, .required)
            .field("amount", .int, .required)
            .unique(on: "expense_id", "user_id")
            .create()

        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("CREATE INDEX idx_expenses_group_id ON expenses (group_id)").run()
        try await sql.raw("CREATE INDEX idx_expenses_paid_by ON expenses (paid_by)").run()
        try await sql.raw("CREATE INDEX idx_expenses_deleted_at ON expenses (deleted_at)").run()
        try await sql.raw("CREATE INDEX idx_expense_splits_expense_id ON expense_splits (expense_id)").run()
        try await sql.raw("CREATE INDEX idx_expense_splits_user_id ON expense_splits (user_id)").run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("expense_splits").delete()
        try await database.schema("expenses").delete()
    }
}
