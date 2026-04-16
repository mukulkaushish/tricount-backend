import Fluent
import Vapor

final class GroupInvite: Model, @unchecked Sendable {
    static let schema = "group_invites"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "group_id")
    var group: Group

    @Parent(key: "invited_by")
    var invitedBy: User

    @Field(key: "invitee_contact")
    var inviteeContact: String

    @Field(key: "invite_token")
    var inviteToken: String

    @Field(key: "status")
    var status: String

    @Field(key: "expires_at")
    var expiresAt: Date

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, groupID: UUID, invitedByID: UUID, inviteeContact: String, inviteToken: String, status: String = "pending", expiresAt: Date) {
        self.id = id
        self.$group.id = groupID
        self.$invitedBy.id = invitedByID
        self.inviteeContact = inviteeContact
        self.inviteToken = inviteToken
        self.status = status
        self.expiresAt = expiresAt
    }
}
