import Vapor
import Foundation

/// Production-grade structured access logger.
///
/// Emits two JSON log lines per request with matching correlation IDs,
/// compatible with log aggregators (Datadog, CloudWatch, ELK, Grafana Loki).
///
/// ```
/// {"ts":"2026-04-09T12:05:31.042Z","level":"info","event":"req.in","rid":"a0a24712","method":"POST","path":"/v1/auth/login","ip":"127.0.0.1","ua":"HoppscotchKernel/0.2.0","contentType":"application/json","body":{"email":"user@test.com","password":"***"}}
/// {"ts":"2026-04-09T12:05:31.088Z","level":"info","event":"req.out","rid":"a0a24712","method":"POST","path":"/v1/auth/login","status":200,"duration_ms":45.32,"bytes":256}
/// ```
struct LoggingMiddleware: AsyncMiddleware {

    /// Formats a Date as ISO 8601 with millisecond precision (e.g. "2026-04-09T12:05:31.042Z").
    /// Uses manual formatting to avoid non-Sendable ISO8601DateFormatter in Swift 6.
    private static func iso8601(_ date: Date) -> String {
        let interval = date.timeIntervalSince1970
        let seconds = Int(interval)
        let millis = Int((interval - Double(seconds)) * 1000)

        var t = time_t(seconds)
        var tm = tm()
        gmtime_r(&t, &tm)

        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
                      tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
                      tm.tm_hour, tm.tm_min, tm.tm_sec, millis)
    }

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        request.prepareAccessLogger()
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let wallTime = Date()
        let rid = request.requestID
        let shortRID = String(rid.prefix(8))

        let bodySnapshot = request.sanitizedBodySnapshot

        // ── Log incoming request
        logIncoming(request: request, shortRID: shortRID, bodySnapshot: bodySnapshot, at: wallTime)

        do {
            let response = try await next.respond(to: request)
            let durationMs = Self.durationMs(from: DispatchTime.now().uptimeNanoseconds - startedAt)
            response.attachAccessLogHeaders(requestID: rid, durationMilliseconds: durationMs)

            logOutgoing(
                request: request,
                status: response.status,
                shortRID: shortRID,
                durationMs: durationMs,
                responseBytes: response.body.count,
                retryAfter: response.headers.first(name: "Retry-After")
            )
            return response
        } catch {
            let durationMs = Self.durationMs(from: DispatchTime.now().uptimeNanoseconds - startedAt)
            let status = (error as? any AbortError)?.status

            logOutgoing(
                request: request,
                status: status,
                shortRID: shortRID,
                durationMs: durationMs,
                responseBytes: nil,
                retryAfter: nil,
                error: error
            )
            throw error
        }
    }

    // MARK: - Incoming

    private func logIncoming(request: Request, shortRID: String, bodySnapshot: String?, at time: Date) {
        let ts = Self.iso8601( time)
        let method = request.method.rawValue
        let path = request.url.path
        let ip = request.cleanIP

        var parts: [String] = [
            "\"ts\":\"\(ts)\"",
            "\"level\":\"info\"",
            "\"event\":\"req.in\"",
            "\"rid\":\"\(shortRID)\"",
            "\"method\":\"\(method)\"",
            "\"path\":\"\(Self.jsonEscape(path))\"",
            "\"ip\":\"\(ip)\"",
        ]

        if let query = request.url.query, !query.isEmpty {
            parts.append("\"query\":\"\(Self.jsonEscape(query))\"")
        }

        if let userID = request.accessLogUserID {
            parts.append("\"userId\":\"\(userID)\"")
        }

        if let ua = request.headers.first(name: .userAgent), !ua.isEmpty {
            parts.append("\"ua\":\"\(Self.jsonEscape(String(ua.prefix(120))))\"")
        }

        if let ct = request.headers.contentType {
            parts.append("\"contentType\":\"\(ct)\"")
        }

        if let body = bodySnapshot {
            parts.append("\"body\":\(body)")
        }

        request.cleanLogger.info("{\(parts.joined(separator: ","))}")
    }

    // MARK: - Outgoing

    private func logOutgoing(
        request: Request,
        status: HTTPStatus?,
        shortRID: String,
        durationMs: Double,
        responseBytes: Int?,
        retryAfter: String?,
        error: (any Error)? = nil
    ) {
        let ts = Self.iso8601( Date())
        let statusCode = status?.code ?? 0
        let method = request.method.rawValue
        let path = request.url.path
        let level = request.accessLogLevel(for: status ?? .internalServerError)

        var parts: [String] = [
            "\"ts\":\"\(ts)\"",
            "\"level\":\"\(level)\"",
            "\"event\":\"req.out\"",
            "\"rid\":\"\(shortRID)\"",
            "\"method\":\"\(method)\"",
            "\"path\":\"\(Self.jsonEscape(path))\"",
            "\"status\":\(statusCode)",
            "\"duration_ms\":\(Self.formatDuration(durationMs))",
        ]

        if let bytes = responseBytes {
            parts.append("\"bytes\":\(bytes)")
        }

        if let userID = request.accessLogUserID {
            parts.append("\"userId\":\"\(userID)\"")
        }

        if let policy = request.rateLimitPolicy, !policy.isDisabled {
            parts.append("\"rateLimit\":\"\(policy.identifier)\"")
            if let attempt = request.rateLimitAttempt {
                parts.append("\"rateLimitAttempt\":\"\(attempt)/\(policy.limit)\"")
            }
            if let retryAfter {
                parts.append("\"retryAfter\":\(retryAfter)")
            }
        }

        if let route = request.accessLogRoutePath, route != path {
            parts.append("\"route\":\"\(Self.jsonEscape(route))\"")
        }

        if let error {
            let typeName = String(reflecting: type(of: error))
                .split(separator: ".").last.map(String.init) ?? "Error"
            let desc = Self.clipped(String(describing: error), maxLength: 300)
            parts.append("\"errorType\":\"\(Self.jsonEscape(typeName))\"")
            parts.append("\"error\":\"\(Self.jsonEscape(desc))\"")
        }

        request.cleanLogger.log(level: level, "{\(parts.joined(separator: ","))}")
    }

    // MARK: - Helpers

    private static func durationMs(from nanoseconds: UInt64) -> Double {
        Double(nanoseconds) / 1_000_000
    }

    private static func formatDuration(_ ms: Double) -> String {
        if ms < 1 {
            return String(format: "%.3f", ms)
        }
        return String(format: "%.2f", ms)
    }

    private static func jsonEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    private static func clipped(_ value: String, maxLength: Int) -> String {
        guard value.count > maxLength else { return value }
        return String(value.prefix(maxLength)) + "..."
    }
}
