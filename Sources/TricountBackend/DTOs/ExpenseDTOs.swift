import Vapor

// MARK: - Expense Split
struct ExpenseSplitInput: Content {
    let userId: UUID
    let amount: Int64

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case amount
    }
}

struct ExpenseSplitResponse: Content {
    let id: UUID
    let user: UserBasicInfo
    let amount: Int64
}

// MARK: - Create Expense
struct CreateExpenseRequest: Content {
    let title: String
    let amount: Int64
    let currency: String?
    let paidBy: UUID
    let splits: [ExpenseSplitInput]
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case title, amount, currency
        case paidBy = "paid_by"
        case splits, notes
    }
}

struct CreateExpenseResponse: Content {
    let id: UUID
    let groupId: UUID
    let title: String
    let amount: Int64
    let currency: String
    let paidBy: UserBasicInfo
    let splits: [ExpenseSplitResponse]
    let notes: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case groupId = "group_id"
        case title, amount, currency
        case paidBy = "paid_by"
        case splits, notes
        case createdAt = "created_at"
    }
}

// MARK: - Get Expense
struct ExpenseDetailsResponse: Content {
    let id: UUID
    let groupId: UUID
    let title: String
    let amount: Int64
    let currency: String
    let paidBy: UserBasicInfo
    let splits: [ExpenseSplitResponse]
    let notes: String?
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case groupId = "group_id"
        case title, amount, currency
        case paidBy = "paid_by"
        case splits, notes
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - Update Expense
struct UpdateExpenseRequest: Content {
    let title: String?
    let amount: Int64?
    let currency: String?
    let paidBy: UUID?
    let splits: [ExpenseSplitInput]?
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case title, amount, currency
        case paidBy = "paid_by"
        case splits, notes
    }
}

// MARK: - List Expenses
struct ExpenseListResponse: Content {
    let id: UUID
    let title: String
    let amount: Int64
    let currency: String
    let paidBy: UserBasicInfo
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, title, amount, currency
        case paidBy = "paid_by"
        case createdAt = "created_at"
    }
}

struct ListExpensesResponse: Content {
    let expenses: [ExpenseListResponse]
    let total: Int
}
