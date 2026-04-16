import Fluent
import Vapor
import Crypto
import Foundation

/// Mutation-safe replay middleware (Phase 9 — sync queue support).
///
/// When a client sends an `Idempotency-Key` header, the middleware either replays a previously cached response for the
/// same `(key, user_id)` pair or caches the fresh response so the next retry with the same key is a no-op write.
///
/// Intended to be layered AFTER `JWTAuthMiddleware` so the authenticated user ID is available. If the header is absent
/// the middleware is a pass-through.
struct IdempotencyMiddleware: AsyncMiddleware {
    static let headerName = "Idempotency-Key"
    static let cacheLifetime: TimeInterval = 24 * 60 * 60

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let rawKey = request.headers.first(name: Self.headerName) else {
            return try await next.respond(to: request)
        }
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count >= 8, key.count <= 128 else {
            throw Abort(.badRequest, reason: "Idempotency-Key must be 8–128 chars")
        }

        let userID: UUID
        do {
            userID = try request.authenticatedUserID
        } catch {
            // Without an authenticated user we can't safely scope the cache; fall through so the request still runs
            // and fails on its own auth middleware if applicable.
            return try await next.respond(to: request)
        }

        let bodyBytes = request.body.data.flatMap { Data(buffer: $0) } ?? Data()
        let requestHash = Self.sha256Hex(
            request.method.rawValue + " " + request.url.path + "\n" + String(data: bodyBytes, encoding: .utf8).orEmpty()
        )

        if let cached = try await SyncOperation.query(on: request.db)
            .filter(\.$idempotencyKey == key)
            .filter(\.$userId == userID)
            .first() {
            if cached.expiresAt <= Date() {
                try await cached.delete(on: request.db)
            } else {
                guard cached.requestHash == requestHash else {
                    throw Abort(.unprocessableEntity, reason: "Idempotency-Key replayed with a different request payload")
                }
                return Self.renderCached(cached)
            }
        }

        let response = try await next.respond(to: request)

        // Only cache success responses — 4xx/5xx may be transient.
        if (200..<300).contains(Int(response.status.code)) {
            let (bodyString, contentType) = Self.extract(from: response)
            let record = SyncOperation(
                idempotencyKey: key,
                userId: userID,
                method: request.method.rawValue,
                path: request.url.path,
                requestHash: requestHash,
                statusCode: Int(response.status.code),
                responseBody: bodyString,
                responseContentType: contentType,
                expiresAt: Date().addingTimeInterval(Self.cacheLifetime)
            )
            // Race: another concurrent write may land first. If so, treat the existing row as authoritative.
            do {
                try await record.save(on: request.db)
            } catch {
                request.logger.debug("Idempotency row already present, skipping cache write", metadata: [
                    "key": .string(key)
                ])
            }
        }

        return response
    }

    private static func renderCached(_ record: SyncOperation) -> Response {
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: record.responseContentType)
        headers.replaceOrAdd(name: "Idempotent-Replayed", value: "true")

        let body = Response.Body(string: record.responseBody)
        return Response(status: .init(statusCode: record.statusCode), headers: headers, body: body)
    }

    private static func extract(from response: Response) -> (String, String) {
        let contentType = response.headers.contentType?.serialize() ?? "application/json"
        let bodyString: String
        if let buffer = response.body.buffer {
            bodyString = String(buffer: buffer)
        } else if let string = response.body.string {
            bodyString = string
        } else {
            bodyString = ""
        }
        return (bodyString, contentType)
    }

    private static func sha256Hex(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private extension Optional where Wrapped == String {
    func orEmpty() -> String { self ?? "" }
}
