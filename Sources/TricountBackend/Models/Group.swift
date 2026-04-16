import Fluent
import Vapor

final class Group: Model, @unchecked Sendable {
    static let schema = "groups"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "name")
    var name: String

    @Field(key: "icon_url")
    var iconUrl: String?

    @Parent(key: "created_by")
    var createdBy: User

    @Field(key: "simplify_debts_enabled")
    var simplifyDebtsEnabled: Bool

    @Field(key: "allow_member_edit")
    var allowMemberEdit: Bool

    @Field(key: "allow_member_delete")
    var allowMemberDelete: Bool

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    @Children(for: \.$group)
    var members: [GroupMember]

    @Children(for: \.$group)
    var expenses: [Expense]

    init() {}

    init(id: UUID? = nil, name: String, iconUrl: String? = nil, createdByID: UUID, simplifyDebtsEnabled: Bool = true, allowMemberEdit: Bool = true, allowMemberDelete: Bool = true) {
        self.id = id
        self.name = name
        self.iconUrl = iconUrl
        self.$createdBy.id = createdByID
        self.simplifyDebtsEnabled = simplifyDebtsEnabled
        self.allowMemberEdit = allowMemberEdit
        self.allowMemberDelete = allowMemberDelete
    }
}
