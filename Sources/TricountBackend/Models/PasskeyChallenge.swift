import Fluent
import Foundation

final class PasskeyChallenge: Model, @unchecked Sendable {
    static let schema = "passkey_challenges"

    enum Flow: String, Sendable {
        case registration
        case authentication
    }

    @ID(key: .id)
    var id: UUID?

    @OptionalParent(key: "user_id")
    var user: User?

    @Field(key: "flow")
    var flowRawValue: String

    @Field(key: "challenge")
    var challenge: String

    @Field(key: "rp_id")
    var rpId: String

    @Field(key: "expires_at")
    var expiresAt: Date

    @OptionalField(key: "used_at")
    var usedAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userId: UUID? = nil,
        flow: Flow,
        challenge: String,
        rpId: String,
        expiresAt: Date,
        usedAt: Date? = nil
    ) {
        self.id = id
        self.$user.id = userId
        self.flowRawValue = flow.rawValue
        self.challenge = challenge
        self.rpId = rpId
        self.expiresAt = expiresAt
        self.usedAt = usedAt
    }

    var flow: Flow {
        get { Flow(rawValue: flowRawValue) ?? .authentication }
        set { flowRawValue = newValue.rawValue }
    }

    var isExpired: Bool { expiresAt < Date() }
    var isUsed: Bool { usedAt != nil }
    var isValid: Bool { !isExpired && !isUsed }
}
