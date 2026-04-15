import Fluent
import SQLKit

struct AddBackupCodeIndexes: AsyncMigration {
    private let indexes: [(table: String, column: String)] = [
        ("backup_codes", "user_id"),
        ("backup_codes", "used_at"),
    ]

    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }

        for index in indexes {
            let name = "idx_\(index.table)_\(index.column)"
            let rows = try await sql.raw("""
                SELECT COUNT(*) AS cnt FROM information_schema.statistics WHERE table_schema = DATABASE() AND table_name = '\(unsafeRaw: index.table)' AND index_name = '\(unsafeRaw: name)'
                """).all()
            let exists = (try? rows.first?.decode(column: "cnt", as: Int.self)) ?? 0
            guard exists == 0 else { continue }

            try await sql.raw("""
                CREATE INDEX \(unsafeRaw: name) ON \(unsafeRaw: index.table) (\(unsafeRaw: index.column))
                """).run()
        }
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }

        for index in indexes.reversed() {
            let name = "idx_\(index.table)_\(index.column)"
            do {
                try await sql.raw("DROP INDEX \(unsafeRaw: name) ON \(unsafeRaw: index.table)").run()
            } catch {
                continue
            }
        }
    }
}
