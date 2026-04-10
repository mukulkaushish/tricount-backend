import Fluent
import Foundation

final class PhoneVerificationOTP: Model, @unchecked Sendable {
    static let schema = "phone_verification_otps"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Field(key: "phone_number")
    var phoneNumber: String

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
        phoneNumber: String,
        codeHash: String,
        expiresAt: Date,
        isUsed: Bool = false
    ) {
        self.id = id
        self.$user.id = userId
        self.phoneNumber = phoneNumber
        self.codeHash = codeHash
        self.expiresAt = expiresAt
        self.isUsed = isUsed
    }

    var isExpired: Bool { expiresAt < Date() }
    var isValid: Bool { !isUsed && !isExpired }
}
