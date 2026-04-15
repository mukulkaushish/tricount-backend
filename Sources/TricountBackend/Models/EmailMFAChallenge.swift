import Fluent
import Foundation

final class EmailMFAChallenge: Model, ExpiringRecord, @unchecked Sendable {
    static let schema = "email_mfa_challenges"
    static let lifetime: OTPLifetime = .tenMinutes

    enum Purpose: String, Sendable {
        case login
        case enable
    }

    enum Method: String, Sendable {
        case email
        case authenticatorApp = "authenticator_app"
        case phone
        case backupCode = "backup_code"
        case passkey

        var isPrimaryFactor: Bool {
            self != .backupCode
        }
    }

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Field(key: "purpose")
    var purposeRawValue: String

    @OptionalField(key: "method")
    var methodRawValueStorage: String?

    @OptionalField(key: "challenge_token_hash")
    var challengeTokenHash: String?

    @Field(key: "code_hash")
    var codeHash: String

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
        purpose: Purpose,
        method: Method = .email,
        challengeTokenHash: String? = nil,
        codeHash: String,
        expiresAt: Date,
        isUsed: Bool = false
    ) {
        self.id = id
        self.$user.id = userId
        self.purposeRawValue = purpose.rawValue
        self.methodRawValueStorage = method.rawValue
        self.challengeTokenHash = challengeTokenHash
        self.codeHash = codeHash
        self.expiresAt = expiresAt
        self.isUsed = isUsed
    }

    var purpose: Purpose {
        get { Purpose(rawValue: purposeRawValue) ?? .login }
        set { purposeRawValue = newValue.rawValue }
    }

    var method: Method {
        get { Method(rawValue: methodRawValueStorage ?? Method.email.rawValue) ?? .email }
        set { methodRawValueStorage = newValue.rawValue }
    }
}
