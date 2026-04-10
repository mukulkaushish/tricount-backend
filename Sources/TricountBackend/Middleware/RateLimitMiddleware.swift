import Vapor
import Foundation
import Crypto

// MARK: - In-memory sliding-window rate limit store

actor RateLimitStore {
    static let shared = RateLimitStore()

    private var buckets: [String: [Date]] = [:]
    private var lastCleanup = Date()
    private let cleanupInterval: TimeInterval = 300 // 5 minutes

    func reset() {
        buckets.removeAll()
    }

    /// Returns whether the request is allowed, the current attempt count, and if rejected the seconds until the window resets.
    func check(key: String, limit: Int, windowSeconds: Int) -> (allowed: Bool, count: Int, retryAfter: Int) {
        let now = Date()
        let windowStart = now.addingTimeInterval(-Double(windowSeconds))

        // Periodically prune keys with no recent timestamps to prevent unbounded growth
        if now.timeIntervalSince(lastCleanup) > cleanupInterval {
            buckets = buckets.filter { !$0.value.allSatisfy { $0 <= windowStart } }
            lastCleanup = now
        }

        var timestamps = buckets[key, default: []].filter { $0 > windowStart }

        if timestamps.count >= limit {
            let retryAfter: Int
            if let oldest = timestamps.first {
                retryAfter = max(1, Int(oldest.addingTimeInterval(Double(windowSeconds)).timeIntervalSince(now)) + 1)
            } else {
                retryAfter = windowSeconds
            }
            buckets[key] = timestamps
            return (false, timestamps.count, retryAfter)
        }

        timestamps.append(now)
        buckets[key] = timestamps
        return (true, timestamps.count, 0)
    }
}

// MARK: - Key extraction strategy

enum RateLimitKeyStrategy: Sendable {
    /// Rate-limit by client IP (or X-Forwarded-For)
    case ip
    /// Rate-limit by the `email` field in the request body (for forgot-password)
    case bodyEmail

    func extract(from request: Request) -> String {
        switch self {
        case .ip:
            return request.clientIdentifier
        case .bodyEmail:
            let email = AuthValidation.normalizeEmail(
                (try? request.content.get(String.self, at: "email")) ?? request.clientIdentifier
            )
            return "email:\(email)"
        }
    }
}

// MARK: - Middleware

struct RateLimitMiddleware: AsyncMiddleware {
    private let defaultPolicy: RateLimitPolicy

    init(defaultPolicy: RateLimitPolicy = .disabled) {
        self.defaultPolicy = defaultPolicy
    }

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        if Self.isStaticAssetRequest(request) {
            return try await next.respond(to: request)
        }

        let policy = request.rateLimitPolicy ?? defaultPolicy
        guard !policy.isDisabled else {
            return try await next.respond(to: request)
        }

        let key = policy.makeKey(for: request)
        let (allowed, count, retryAfter) = await RateLimitStore.shared.check(
            key: key,
            limit: policy.limit,
            windowSeconds: policy.windowSeconds
        )
        request.rateLimitAttempt = count

        guard allowed else {
            request.logger.warning("Rate limit exceeded", metadata: ["key": .string(key)])
            let body = ErrorResponse(
                error: "RATE_LIMIT_EXCEEDED",
                message: "Too many requests. Please try again in \(retryAfter) second(s).",
                statusCode: 429
            )
            let response = try Response.data(body, status: .tooManyRequests)
            response.headers.add(name: "Retry-After", value: "\(retryAfter)")
            response.headers.add(name: "X-RateLimit-Limit", value: "\(policy.limit)")
            return response
        }

        let response = try await next.respond(to: request)
        response.headers.add(name: "X-RateLimit-Limit", value: "\(policy.limit)")
        return response
    }

    private static func isStaticAssetRequest(_ request: Request) -> Bool {
        guard request.method == .GET || request.method == .HEAD else {
            return false
        }

        let lastPathComponent = request.url.path.split(separator: "/").last.map(String.init) ?? ""
        return lastPathComponent.contains(".")
    }
}

// MARK: - Policies

struct RateLimitPolicy: Sendable {
    let identifier: String
    let limit: Int
    let windowSeconds: Int
    let keyStrategy: RateLimitKeyStrategy
    let isDisabled: Bool

    init(
        identifier: String,
        limit: Int,
        windowSeconds: Int,
        keyStrategy: RateLimitKeyStrategy = .ip,
        isDisabled: Bool = false
    ) {
        self.identifier = identifier
        self.limit = limit
        self.windowSeconds = windowSeconds
        self.keyStrategy = keyStrategy
        self.isDisabled = isDisabled
    }

    func makeKey(for request: Request) -> String {
        "\(identifier):\(keyStrategy.extract(from: request))"
    }
}

extension RateLimitPolicy {
    /// 120 req / minute per IP — opt-in policy for routes that should use a shared default limit.
    static let `default` = RateLimitPolicy(identifier: "default", limit: 120, windowSeconds: 60)

    /// Disable rate limiting entirely.
    static let disabled = RateLimitPolicy(identifier: "disabled", limit: 0, windowSeconds: 0, isDisabled: true)

    static func custom(
        identifier: String,
        limit: Int,
        windowSeconds: Int,
        keyStrategy: RateLimitKeyStrategy = .ip
    ) -> RateLimitPolicy {
        RateLimitPolicy(
            identifier: identifier,
            limit: limit,
            windowSeconds: windowSeconds,
            keyStrategy: keyStrategy
        )
    }
}

private let rateLimitRouteUserInfoKey: AnySendableHashable = "tricount.rate-limit-policy"

extension Route {
    @discardableResult
    func rateLimit(_ policy: RateLimitPolicy) -> Route {
        self.userInfo[rateLimitRouteUserInfoKey] = policy
        return self
    }

    var rateLimitPolicy: RateLimitPolicy? {
        self.userInfo[rateLimitRouteUserInfoKey] as? RateLimitPolicy
    }
}

private struct RateLimitAttemptKey: StorageKey {
    typealias Value = Int
}

extension Request {
    var rateLimitAttempt: Int? {
        get { storage[RateLimitAttemptKey.self] }
        set { storage[RateLimitAttemptKey.self] = newValue }
    }

    var clientIdentifier: String {
        headers.first(name: "X-Forwarded-For")
            ?? headers.first(name: "X-Real-IP")
            ?? remoteAddress?.description
            ?? "unknown"
    }

    var rateLimitPolicy: RateLimitPolicy? {
        self.route?.userInfo[rateLimitRouteUserInfoKey] as? RateLimitPolicy
    }
}
