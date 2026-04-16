import Fluent
import Vapor

/// Singleton invite per group. One row per `group_id` — token is the permanent shareable secret.
final class GroupInvite: Model, @unchecked Sendable {
    static let schema = "group_invites"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "group_id")
    var group: Group

    @Parent(key: "invited_by")
    var invitedBy: User

    @Field(key: "invite_token")
    var inviteToken: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, groupID: UUID, invitedByID: UUID, inviteToken: String) {
        self.id = id
        self.$group.id = groupID
        self.$invitedBy.id = invitedByID
        self.inviteToken = inviteToken
    }
}
