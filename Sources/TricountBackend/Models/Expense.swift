import Fluent
import Vapor

final class Expense: Model, @unchecked Sendable {
    static let schema = "expenses"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "group_id")
    var group: Group

    @Parent(key: "paid_by")
    var paidBy: User

    @Field(key: "amount")
    var amount: Int64

    @Field(key: "currency")
    var currency: String

    @Field(key: "title")
    var title: String

    @Field(key: "notes")
    var notes: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    @Field(key: "deleted_at")
    var deletedAt: Date?

    @Children(for: \.$expense)
    var splits: [ExpenseSplit]

    init() {}

    init(id: UUID? = nil, groupID: UUID, paidByID: UUID, amount: Int64, currency: String = "INR", title: String, notes: String? = nil) {
        self.id = id
        self.$group.id = groupID
        self.$paidBy.id = paidByID
        self.amount = amount
        self.currency = currency
        self.title = title
        self.notes = notes
    }
}
