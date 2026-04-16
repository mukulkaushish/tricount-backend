import Fluent
import Vapor

final class ExpenseSplit: Model, @unchecked Sendable {
    static let schema = "expense_splits"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "expense_id")
    var expense: Expense

    @Parent(key: "user_id")
    var user: User

    @Field(key: "amount")
    var amount: Int64

    init() {}

    init(id: UUID? = nil, expenseID: UUID, userID: UUID, amount: Int64) {
        self.id = id
        self.$expense.id = expenseID
        self.$user.id = userID
        self.amount = amount
    }
}
