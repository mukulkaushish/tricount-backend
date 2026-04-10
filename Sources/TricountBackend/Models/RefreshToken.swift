import Fluent
import Vapor

final class RefreshToken: Model, @unchecked Sendable {
    static let schema = "refresh_tokens"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    /// SHA-256 hash of the raw token — never store the raw value
    @Field(key: "token_hash")
    var tokenHash: String

    @Field(key: "expires_at")
    var expiresAt: Date

    @Field(key: "is_revoked")
    var isRevoked: Bool

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userId: UUID,
        tokenHash: String,
        expiresAt: Date,
        isRevoked: Bool = false
    ) {
        self.id = id
        self.$user.id = userId
        self.tokenHash = tokenHash
        self.expiresAt = expiresAt
        self.isRevoked = isRevoked
    }

    var isExpired: Bool { expiresAt < Date() }
    var isValid: Bool { !isRevoked && !isExpired }
}
