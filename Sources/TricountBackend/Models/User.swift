import Fluent
import Foundation
import Vapor

final class User: Model, @unchecked Sendable {
    static let schema = "users"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "email")
    var email: String

    @Field(key: "password_hash")
    var passwordHash: String?

    @Field(key: "display_name")
    var displayName: String

    @Field(key: "avatar_url")
    var avatarUrl: String?

    @OptionalField(key: "is_email_verified")
    var isEmailVerifiedStorage: Bool?

    @OptionalField(key: "verified_at")
    var verifiedAt: Date?

    @OptionalField(key: "is_mfa_enabled")
    var isMFAEnabledStorage: Bool?

    @OptionalField(key: "mfa_method")
    var mfaMethod: String?

    @OptionalField(key: "phone_number")
    var phoneNumber: String?

    @OptionalField(key: "is_phone_verified")
    var isPhoneVerifiedStorage: Bool?

    @OptionalField(key: "phone_verified_at")
    var phoneVerifiedAt: Date?

    @OptionalField(key: "totp_secret")
    var totpSecret: String?

    var isEmailVerified: Bool {
        get { isEmailVerifiedStorage ?? false }
        set { isEmailVerifiedStorage = newValue }
    }

    var isMFAEnabled: Bool {
        get { isMFAEnabledStorage ?? false }
        set { isMFAEnabledStorage = newValue }
    }

    var isPhoneVerified: Bool {
        get { isPhoneVerifiedStorage ?? false }
        set { isPhoneVerifiedStorage = newValue }
    }

    /// "email" | "google" | "apple"
    @Field(key: "provider")
    var provider: String

    @Field(key: "google_id")
    var googleId: String?

    @OptionalField(key: "apple_id")
    var appleId: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        email: String,
        passwordHash: String? = nil,
        displayName: String,
        avatarUrl: String? = nil,
        isEmailVerified: Bool = false,
        verifiedAt: Date? = nil,
        isMFAEnabled: Bool = false,
        mfaMethod: String? = nil,
        phoneNumber: String? = nil,
        isPhoneVerified: Bool = false,
        phoneVerifiedAt: Date? = nil,
        totpSecret: String? = nil,
        provider: String = "email",
        googleId: String? = nil,
        appleId: String? = nil
    ) {
        self.id = id
        self.email = email
        self.passwordHash = passwordHash
        self.displayName = displayName
        self.avatarUrl = avatarUrl
        self.isEmailVerifiedStorage = isEmailVerified
        self.verifiedAt = verifiedAt
        self.isMFAEnabledStorage = isMFAEnabled
        self.mfaMethod = mfaMethod
        self.phoneNumber = phoneNumber
        self.isPhoneVerifiedStorage = isPhoneVerified
        self.phoneVerifiedAt = phoneVerifiedAt
        self.totpSecret = totpSecret
        self.provider = provider
        self.googleId = googleId
        self.appleId = appleId
    }
}

extension User: Authenticatable {}
