import Fluent
import SQLKit

struct CreatePaymentTables: AsyncMigration {
    func prepare(on database: any Database) async throws {
        // Create payments table
        try await database.schema("payments")
            .id()
            .field("group_id", .uuid, .required)
            .field("payer_id", .uuid, .required)
            .field("receiver_id", .uuid, .required)
            .field("amount", .int, .required)
            .field("created_at", .datetime, .required)
            .field("reversed_at", .datetime)
            .create()

        // Create user_payment_identities table
        try await database.schema("user_payment_identities")
            .field("user_id", .uuid, .required)
            .field("upi_id", .string)
            .field("qr_url", .string)
            .field("updated_at", .datetime, .required)
            .create()

        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("ALTER TABLE user_payment_identities ADD PRIMARY KEY (user_id)").run()
        try await sql.raw("""
            ALTER TABLE user_payment_identities ADD CONSTRAINT fk_user_payment_identities_user_id FOREIGN KEY (user_id) REFERENCES `users`(id) ON DELETE CASCADE
            """).run()
        try await sql.raw("CREATE INDEX idx_payments_group_id ON payments (group_id)").run()
        try await sql.raw("CREATE INDEX idx_payments_payer_id ON payments (payer_id)").run()
        try await sql.raw("CREATE INDEX idx_payments_receiver_id ON payments (receiver_id)").run()
        try await sql.raw("CREATE INDEX idx_user_payment_identities_upi_id ON user_payment_identities (upi_id)").run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("user_payment_identities").delete()
        try await database.schema("payments").delete()
    }
}
