import Vapor

// MARK: - Set/Update Payment Identity
struct UpdatePaymentIdentityRequest: Content {
    let upiId: String?
    let qrUrl: String?

    enum CodingKeys: String, CodingKey {
        case upiId = "upi_id"
        case qrUrl = "qr_url"
    }
}

struct PaymentIdentityResponse: Content {
    let userId: UUID
    let upiId: String?
    let qrUrl: String?
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case upiId = "upi_id"
        case qrUrl = "qr_url"
        case updatedAt = "updated_at"
    }
}
