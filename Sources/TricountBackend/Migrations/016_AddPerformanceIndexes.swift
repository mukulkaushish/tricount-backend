import Fluent
import SQLKit

/// Adds indexes on frequently-queried foreign keys and filter columns
/// that were missing from the original table definitions.
///
/// Impact: speeds up login, /me, token refresh, OTP lookups, and cleanup queries.
struct AddPerformanceIndexes: AsyncMigration {

    private let indexes: [(table: String, column: String)] = [
        // users — email already has UNIQUE. Add OAuth + phone lookups.
        ("users", "google_id"),
        ("users", "apple_id"),
        ("users", "phone_number"),

        // refresh_tokens — token_hash has UNIQUE. Add user_id for revoke-all.
        ("refresh_tokens", "user_id"),

        // OTP / challenge tables — user_id for lookups, expires_at for cleanup.
        ("email_verification_otps", "user_id"),
        ("email_verification_otps", "expires_at"),

        ("password_reset_otps", "user_id"),
        ("password_reset_otps", "expires_at"),

        ("email_mfa_challenges", "user_id"),
        ("email_mfa_challenges", "expires_at"),

        ("phone_verification_otps", "user_id"),
        ("phone_verification_otps", "expires_at"),

        ("authenticator_app_setup_challenges", "user_id"),
        ("authenticator_app_setup_challenges", "expires_at"),

        // passkey_credentials — credential_id has UNIQUE.
        ("passkey_credentials", "user_id"),

        // passkey_challenges — challenge has UNIQUE.
        ("passkey_challenges", "user_id"),
        ("passkey_challenges", "expires_at"),
    ]

    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }

        for idx in indexes {
            let name = "idx_\(idx.table)_\(idx.column)"
            // MySQL doesn't support CREATE INDEX IF NOT EXISTS — check first
            let rows = try await sql.raw("""
                SELECT COUNT(*) AS cnt FROM information_schema.statistics WHERE table_schema = DATABASE() AND table_name = '\(unsafeRaw: idx.table)' AND index_name = '\(unsafeRaw: name)'
                """).all()
            let exists = (try? rows.first?.decode(column: "cnt", as: Int.self)) ?? 0
            guard exists == 0 else { continue }

            try await sql.raw("""
                CREATE INDEX \(unsafeRaw: name) ON \(unsafeRaw: idx.table) (\(unsafeRaw: idx.column))
                """).run()
        }
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }

        for idx in indexes.reversed() {
            let name = "idx_\(idx.table)_\(idx.column)"
            do {
                try await sql.raw("DROP INDEX \(unsafeRaw: name) ON \(unsafeRaw: idx.table)").run()
            } catch {
                // These indexes are best-effort performance helpers. In MySQL, a foreign-key-backed
                // index may be required or may already be absent if the server reused/dropped it.
                continue
            }
        }
    }
}
