import Fluent
import SQLKit

/// Adds composite indexes for query patterns that the single-column indexes can't serve efficiently:
/// - `ledger_entries (reference_type, reference_id)` is already single — extend with `group_id` for BalanceService scans
/// - `expenses (group_id, deleted_at)` for active-expense listings
/// - `payments (group_id, reversed_at)` for active-payment listings
/// - `group_members (group_id, status, role)` for admin-count and membership checks
/// - `group_activities (group_id, created_at)` for descending-time activity feed
struct AddCompositeIndexes: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }

        try await sql.raw("CREATE INDEX idx_ledger_entries_group_reference ON ledger_entries (group_id, reference_type, reference_id)").run()
        try await sql.raw("CREATE INDEX idx_expenses_group_deleted ON expenses (group_id, deleted_at)").run()
        try await sql.raw("CREATE INDEX idx_payments_group_reversed ON payments (group_id, reversed_at)").run()
        try await sql.raw("CREATE INDEX idx_group_members_group_status_role ON group_members (group_id, status, role)").run()
        try await sql.raw("CREATE INDEX idx_group_activities_group_created ON group_activities (group_id, created_at)").run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }

        try await sql.raw("DROP INDEX idx_group_activities_group_created ON group_activities").run()
        try await sql.raw("DROP INDEX idx_group_members_group_status_role ON group_members").run()
        try await sql.raw("DROP INDEX idx_payments_group_reversed ON payments").run()
        try await sql.raw("DROP INDEX idx_expenses_group_deleted ON expenses").run()
        try await sql.raw("DROP INDEX idx_ledger_entries_group_reference ON ledger_entries").run()
    }
}
