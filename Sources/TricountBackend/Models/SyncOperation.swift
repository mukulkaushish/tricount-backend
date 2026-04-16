import Fluent
import Vapor

/// Persistent record of a completed mutation request that carried an `Idempotency-Key` header.
/// A retry with the same key from the same user replays the cached response verbatim.
final class SyncOperation: Model, @unchecked Sendable {
    static let schema = "sync_operations"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "idempotency_key")
    var idempotencyKey: String

    @Field(key: "user_id")
    var userId: UUID

    @Field(key: "method")
    var method: String

    @Field(key: "path")
    var path: String

    @Field(key: "request_hash")
    var requestHash: String

    @Field(key: "status_code")
    var statusCode: Int

    @Field(key: "response_body")
    var responseBody: String

    @Field(key: "response_content_type")
    var responseContentType: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Field(key: "expires_at")
    var expiresAt: Date

    init() {}

    init(
        id: UUID? = nil,
        idempotencyKey: String,
        userId: UUID,
        method: String,
        path: String,
        requestHash: String,
        statusCode: Int,
        responseBody: String,
        responseContentType: String,
        expiresAt: Date
    ) {
        self.id = id
        self.idempotencyKey = idempotencyKey
        self.userId = userId
        self.method = method
        self.path = path
        self.requestHash = requestHash
        self.statusCode = statusCode
        self.responseBody = responseBody
        self.responseContentType = responseContentType
        self.expiresAt = expiresAt
    }
}
