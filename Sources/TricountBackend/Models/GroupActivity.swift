import Fluent
import Vapor

final class GroupActivity: Model, @unchecked Sendable {
    static let schema = "group_activities"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "group_id")
    var group: Group

    @Parent(key: "actor_id")
    var actor: User

    @Field(key: "type")
    var type: String

    @Field(key: "reference_id")
    var referenceId: UUID?

    @Field(key: "metadata")
    var metadata: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, groupID: UUID, actorID: UUID, type: String, referenceId: UUID? = nil, metadata: String? = nil) {
        self.id = id
        self.$group.id = groupID
        self.$actor.id = actorID
        self.type = type
        self.referenceId = referenceId
        self.metadata = metadata
    }
}
