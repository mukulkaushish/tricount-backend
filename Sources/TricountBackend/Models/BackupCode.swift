import Fluent
import Foundation

final class BackupCode: Model, @unchecked Sendable {
    static let schema = "backup_codes"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Field(key: "code_hash")
    var codeHash: String

    @OptionalField(key: "used_at")
    var usedAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userId: UUID,
        codeHash: String,
        usedAt: Date? = nil
    ) {
        self.id = id
        self.$user.id = userId
        self.codeHash = codeHash
        self.usedAt = usedAt
    }

    var isUsed: Bool {
        usedAt != nil
    }
}
