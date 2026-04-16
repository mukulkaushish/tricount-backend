import Fluent
import Vapor

final class LedgerEntry: Model, @unchecked Sendable {
    static let schema = "ledger_entries"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "group_id")
    var group: Group

    @Parent(key: "user_id")
    var user: User

    @Field(key: "amount")
    var amount: Int64

    @Field(key: "reference_type")
    var referenceType: String

    @Field(key: "reference_id")
    var referenceId: UUID

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, groupID: UUID, userID: UUID, amount: Int64, referenceType: String, referenceId: UUID) {
        self.id = id
        self.$group.id = groupID
        self.$user.id = userID
        self.amount = amount
        self.referenceType = referenceType
        self.referenceId = referenceId
    }
}
