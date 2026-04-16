import Fluent
import SQLKit

/// Phase 9 — Sync queue support. `sync_operations` persists idempotency records so that mutation endpoints can replay a
/// cached response when the Flutter client retries a queued operation.
struct CreateSyncOperations: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("sync_operations")
            .id()
            .field("idempotency_key", .string, .required)
            .field("user_id", .uuid, .required)
            .field("method", .string, .required)
            .field("path", .string, .required)
            .field("request_hash", .string, .required)
            .field("status_code", .int, .required)
            .field("response_body", .string, .required)
            .field("response_content_type", .string, .required)
            .field("created_at", .datetime, .required)
            .field("expires_at", .datetime, .required)
            .unique(on: "idempotency_key", "user_id")
            .create()

        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("CREATE INDEX idx_sync_operations_expires_at ON sync_operations (expires_at)").run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("sync_operations").delete()
    }
}
