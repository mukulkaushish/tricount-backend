import Foundation
import Logging
import Vapor

private struct RequestIDStorageKey: StorageKey {
    typealias Value = String
}

private struct CleanLoggerStorageKey: StorageKey {
    typealias Value = Logger
}

extension Request {
    var requestID: String {
        get {
            if let existing = storage[RequestIDStorageKey.self] {
                return existing
            }

            let value = Self.resolveRequestID(from: self)
            storage[RequestIDStorageKey.self] = value
            return value
        }
        set {
            storage[RequestIDStorageKey.self] = newValue
        }
    }

    /// A clean logger with no Vapor-injected metadata.
    /// Use this instead of `request.logger` to avoid the trailing `[request-id: ..., method: ...]` noise.
    var cleanLogger: Logger {
        get {
            if let cached = storage[CleanLoggerStorageKey.self] {
                return cached
            }
            var l = Logger(label: "tricount.access")
            l.logLevel = logger.logLevel
            return l
        }
        set {
            storage[CleanLoggerStorageKey.self] = newValue
        }
    }

    func prepareAccessLogger() {
        // Build a clean logger once per request — no Vapor metadata attached.
        var l = Logger(label: "tricount.access")
        l.logLevel = application.logger.logLevel
        cleanLogger = l
    }

    /// Returns a sanitized, truncated snapshot of the request body for logging.
    /// Redacts sensitive fields (password, token, secret, otp, code) and caps at 2KB.
    var sanitizedBodySnapshot: String? {
        guard let contentType = headers.contentType,
              contentType.subType == "json",
              var buffer = body.data,
              buffer.readableBytes > 0
        else {
            return nil
        }

        let maxBytes = 2048
        let bytesToRead = min(buffer.readableBytes, maxBytes)
        guard let raw = buffer.readString(length: bytesToRead) else { return nil }

        let sensitivePattern = #"("(?:password|token|secret|otp|code|refresh_token|id_token|credential|authData)")\s*:\s*"[^"]*""#
        let redacted = raw.replacingOccurrences(
            of: sensitivePattern,
            with: #"$1: "***""#,
            options: .regularExpression
        )

        let truncated = buffer.readableBytes > maxBytes
        return truncated ? redacted + "...(truncated)" : redacted
    }

    var accessLogRoutePath: String? {
        guard let route else { return nil }
        let path = route.path.map { "\($0)" }.joined(separator: "/")
        return path.isEmpty ? "/" : "/\(path)"
    }

    var accessLogUserID: String? {
        if headers.bearerAuthorization != nil {
            return try? authenticatedUserID.uuidString
        }
        return nil
    }

    var isAssetLikeRequest: Bool {
        guard method == .GET || method == .HEAD else { return false }
        let lastPathComponent = url.path.split(separator: "/").last.map(String.init) ?? ""
        return lastPathComponent.contains(".")
    }

    func accessLogLevel(for status: HTTPStatus) -> Logger.Level {
        if status == .notFound && isAssetLikeRequest {
            return .debug
        }
        return status.accessLogLevel
    }

    /// Extracts a clean IP string from the client identifier.
    var cleanIP: String {
        let raw = clientIdentifier
        // Strip [IPv4] or [IPv6] prefix and port suffix for readability
        // e.g. "[IPv4]127.0.0.1/127.0.0.1:49700" → "127.0.0.1"
        if let slashIndex = raw.firstIndex(of: "/") {
            let afterSlash = raw[raw.index(after: slashIndex)...]
            if let colonIndex = afterSlash.lastIndex(of: ":") {
                return String(afterSlash[afterSlash.startIndex..<colonIndex])
            }
            return String(afterSlash)
        }
        return raw
    }

    private static func resolveRequestID(from request: Request) -> String {
        if let incoming = request.headers.first(name: "X-Request-ID") {
            let trimmed = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return String(trimmed.prefix(128))
            }
        }
        return UUID().uuidString.lowercased()
    }
}

extension Response {
    func attachAccessLogHeaders(requestID: String, durationMilliseconds: Double) {
        headers.replaceOrAdd(name: "X-Request-ID", value: requestID)

        let metric = "app;dur=\(String(format: "%.2f", durationMilliseconds))"
        if let existing = headers.first(name: "Server-Timing"), !existing.isEmpty {
            headers.replaceOrAdd(name: "Server-Timing", value: "\(existing), \(metric)")
        } else {
            headers.replaceOrAdd(name: "Server-Timing", value: metric)
        }
    }
}

extension HTTPStatus {
    var accessLogLevel: Logger.Level {
        switch code {
        case 500...: return .error
        case 400...: return .warning
        default: return .info
        }
    }
}
