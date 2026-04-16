import Fluent
import Vapor

final class GroupMember: Model, @unchecked Sendable {
    static let schema = "group_members"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "group_id")
    var group: Group

    @Parent(key: "user_id")
    var user: User

    @Field(key: "role")
    var role: String

    @Field(key: "status")
    var status: String

    @Timestamp(key: "joined_at", on: .create)
    var joinedAt: Date?

    @OptionalField(key: "left_at")
    var leftAt: Date?

    init() {}

    init(id: UUID? = nil, groupID: UUID, userID: UUID, role: String = "member", status: String = "active") {
        self.id = id
        self.$group.id = groupID
        self.$user.id = userID
        self.role = role
        self.status = status
    }
}
