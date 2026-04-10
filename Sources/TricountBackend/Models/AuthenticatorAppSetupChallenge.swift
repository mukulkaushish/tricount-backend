import Fluent
import Foundation

final class AuthenticatorAppSetupChallenge: Model, @unchecked Sendable {
    static let schema = "authenticator_app_setup_challenges"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Field(key: "secret")
    var secret: String

    @Field(key: "expires_at")
    var expiresAt: Date

    @Field(key: "is_used")
    var isUsed: Bool

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userId: UUID,
        secret: String,
        expiresAt: Date,
        isUsed: Bool = false
    ) {
        self.id = id
        self.$user.id = userId
        self.secret = secret
        self.expiresAt = expiresAt
        self.isUsed = isUsed
    }

    var isExpired: Bool { expiresAt < Date() }
    var isValid: Bool { !isUsed && !isExpired }
}
