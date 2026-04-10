import Fluent
import Foundation

final class PasskeyCredential: Model, @unchecked Sendable {
    static let schema = "passkey_credentials"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Field(key: "credential_id")
    var credentialId: String

    @Field(key: "public_key")
    var publicKey: String

    @Field(key: "sign_count")
    var signCount: Int

    @OptionalField(key: "aaguid")
    var aaguid: String?

    @OptionalField(key: "transports")
    var transportsStorage: String?

    @OptionalField(key: "last_used_at")
    var lastUsedAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userId: UUID,
        credentialId: String,
        publicKey: String,
        signCount: Int,
        aaguid: String? = nil,
        transports: [String] = [],
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.$user.id = userId
        self.credentialId = credentialId
        self.publicKey = publicKey
        self.signCount = signCount
        self.aaguid = aaguid
        self.transports = transports
        self.lastUsedAt = lastUsedAt
    }

    var transports: [String] {
        get {
            guard let transportsStorage,
                  let data = transportsStorage.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String].self, from: data) else {
                return []
            }

            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue),
                  let json = String(data: data, encoding: .utf8) else {
                transportsStorage = nil
                return
            }

            transportsStorage = json
        }
    }
}
