import Fluent
import Vapor

final class UserPaymentIdentity: Model, @unchecked Sendable {
    static let schema = "user_payment_identities"

    @ID(custom: "user_id")
    var id: UUID?

    @Field(key: "upi_id")
    var upiId: String?

    @Field(key: "qr_url")
    var qrUrl: String?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(userID: UUID, upiId: String? = nil, qrUrl: String? = nil) {
        self.id = userID
        self.upiId = upiId
        self.qrUrl = qrUrl
    }
}
