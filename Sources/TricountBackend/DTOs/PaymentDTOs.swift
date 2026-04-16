import Vapor

// MARK: - Create Payment
struct CreatePaymentRequest: Content {
    let payerId: UUID
    let receiverId: UUID
    let amount: Int64

    enum CodingKeys: String, CodingKey {
        case payerId = "payer_id"
        case receiverId = "receiver_id"
        case amount
    }
}

struct CreatePaymentResponse: Content {
    let id: UUID
    let groupId: UUID
    let payer: UserBasicInfo
    let receiver: UserBasicInfo
    let amount: Int64
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case groupId = "group_id"
        case payer, receiver, amount
        case createdAt = "created_at"
    }
}

// MARK: - Get Payment
struct PaymentDetailsResponse: Content {
    let id: UUID
    let groupId: UUID
    let payer: UserBasicInfo
    let receiver: UserBasicInfo
    let amount: Int64
    let createdAt: Date
    let reversedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case groupId = "group_id"
        case payer, receiver, amount
        case createdAt = "created_at"
        case reversedAt = "reversed_at"
    }
}

// MARK: - Reverse Payment
struct ReversePaymentRequest: Content {
}

// MARK: - List Payments
struct PaymentListResponse: Content {
    let id: UUID
    let payer: UserBasicInfo
    let receiver: UserBasicInfo
    let amount: Int64
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, payer, receiver, amount
        case createdAt = "created_at"
    }
}

struct ListPaymentsResponse: Content {
    let payments: [PaymentListResponse]
    let total: Int
}
