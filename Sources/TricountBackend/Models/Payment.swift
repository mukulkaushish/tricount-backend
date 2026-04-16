import Fluent
import Vapor

final class Payment: Model, @unchecked Sendable {
    static let schema = "payments"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "group_id")
    var group: Group

    @Parent(key: "payer_id")
    var payer: User

    @Parent(key: "receiver_id")
    var receiver: User

    @Field(key: "amount")
    var amount: Int64

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @OptionalField(key: "reversed_at")
    var reversedAt: Date?

    init() {}

    init(id: UUID? = nil, groupID: UUID, payerID: UUID, receiverID: UUID, amount: Int64) {
        self.id = id
        self.$group.id = groupID
        self.$payer.id = payerID
        self.$receiver.id = receiverID
        self.amount = amount
    }
}
