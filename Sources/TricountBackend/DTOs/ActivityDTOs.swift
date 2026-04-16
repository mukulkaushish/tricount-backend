import Vapor

// MARK: - Activity Log List
struct ActivityLogResponse: Content {
    let id: UUID
    let actor: UserBasicInfo
    let type: String
    let referenceId: UUID?
    let metadata: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, actor, type
        case referenceId = "reference_id"
        case metadata
        case createdAt = "created_at"
    }
}

struct ListActivityLogsResponse: Content {
    let activities: [ActivityLogResponse]
    let total: Int
}

// MARK: - Balance Information
struct UserBalanceResponse: Content {
    let userId: UUID
    let balance: Int64
    let currency: String

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case balance, currency
    }
}

struct GroupBalanceResponse: Content {
    let groupId: UUID
    let balances: [UserBalanceResponse]

    enum CodingKeys: String, CodingKey {
        case groupId = "group_id"
        case balances
    }
}

// MARK: - Debt Simplification
struct SimplifiedDebtResponse: Content {
    let from: UserBasicInfo
    let to: UserBasicInfo
    let amount: Int64
}

struct SimplifyDebtsResponse: Content {
    let transactions: [SimplifiedDebtResponse]
}
