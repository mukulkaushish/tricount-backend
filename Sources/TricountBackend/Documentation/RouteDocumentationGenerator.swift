import Foundation
import Vapor

struct RouteDocumentationGenerator {
    private let application: Application
    private let errorSchema = DocumentationSchemaFactory.make(for: ErrorResponse.self)

    init(application: Application) {
        self.application = application
    }

    func write(to outputDirectory: URL) throws {
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let snapshot = makeSnapshot()
        let jsonURL = outputDirectory.appendingPathComponent("routes.json")
        let markdownURL = outputDirectory.appendingPathComponent("routes.md")

        let jsonData = try JSONSerialization.data(
            withJSONObject: snapshot.jsonObject,
            options: [.prettyPrinted, .sortedKeys]
        )
        try jsonData.write(to: jsonURL, options: .atomic)

        let markdown = renderMarkdown(for: snapshot)
        try markdown.write(to: markdownURL, atomically: true, encoding: .utf8)

        let html = renderHTML(for: snapshot)
        let htmlURL = outputDirectory.appendingPathComponent("index.html")
        try html.write(to: htmlURL, atomically: true, encoding: .utf8)
    }

    private func makeSnapshot() -> RouteDocumentationSnapshot {
        let routes = application.routes.all
            .map(makeEntry(for:))
            .sorted(using: [
                KeyPathComparator(\.path),
                KeyPathComparator(\.method),
            ])

        let schemas = routes
            .flatMap(\.schemas)
            .reduce(into: [String: DocumentationSchema]()) { schemas, entry in
                schemas[entry.name] = schemas[entry.name] ?? entry.schema
            }

        return RouteDocumentationSnapshot(
            service: "tricount-backend",
            environment: application.environment.name,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            routeCount: routes.count,
            schemas: schemas,
            routes: routes
        )
    }

    private func makeEntry(for route: Route) -> RouteDocumentationEntry {
        let metadata = route.routeDocumentationMetadata ?? RouteDocumentationMetadata.fallback(from: route)
        let errors = makeStandardErrors(for: route, metadata: metadata)

        return RouteDocumentationEntry(
            method: route.method.rawValue,
            path: Self.pathString(for: route),
            summary: route.userInfo["description"] as? String,
            auth: metadata.auth.rawValue,
            rateLimit: RouteRateLimitDocumentation(policy: route.rateLimitPolicy),
            requestBody: metadata.requestBody.map(RouteDocumentationRequestBodyEntry.init),
            successResponse: RouteDocumentationSuccessResponseEntry(response: metadata.successResponse),
            errors: errors.map(RouteDocumentationErrorEntry.init)
        )
    }

    private func makeStandardErrors(
        for route: Route,
        metadata: RouteDocumentationMetadata
    ) -> [RouteDocumentationError] {
        var errors: [RouteDocumentationError] = []

        if metadata.requestBody != nil {
            errors.append(
                RouteDocumentationError(
                    statusCode: Int(HTTPStatus.badRequest.code),
                    code: "BAD_REQUEST",
                    reason: "Request body is invalid, malformed, or missing required fields.",
                    schema: errorSchema
                )
            )
        }

        if metadata.auth == .bearer {
            errors.append(
                RouteDocumentationError(
                    statusCode: Int(HTTPStatus.unauthorized.code),
                    code: "UNAUTHORIZED",
                    reason: "Missing, invalid, or expired bearer token.",
                    schema: errorSchema
                )
            )
        }

        if let policy = route.rateLimitPolicy, !policy.isDisabled {
            errors.append(
                RouteDocumentationError(
                    statusCode: Int(HTTPStatus.tooManyRequests.code),
                    code: "RATE_LIMIT_EXCEEDED",
                    reason: "Too many requests for the configured rate-limit window.",
                    schema: errorSchema
                )
            )
        }

        return errors.sorted { $0.statusCode < $1.statusCode }
    }

    private func renderMarkdown(for snapshot: RouteDocumentationSnapshot) -> String {
        var lines: [String] = [
            "# Tricount API Reference",
            "",
            "- Generated at: \(snapshot.generatedAt)",
            "- Environment: \(snapshot.environment)",
            "- Route count: \(snapshot.routeCount)",
            "- Schema count: \(snapshot.schemas.count)",
            "",
            "> Auto-generated at application startup from the registered Vapor routes and their typed request/response DTOs.",
            "",
            "| Method | Path | Auth | Success | Rate Limit |",
            "|---|---|---|---|---|",
        ]

        for route in snapshot.routes {
            lines.append(
                "| \(route.method) | \(route.path) | \(route.auth) | \(route.successResponse.summary) | \(route.rateLimit.summary) |"
            )
        }

        for route in snapshot.routes {
            lines.append("")
            lines.append("## \(route.method) \(route.path)")
            if let summary = route.summary, !summary.isEmpty {
                lines.append("")
                lines.append(summary)
            }

            lines.append("")
            lines.append("- Auth: \(route.auth)")
            lines.append("- Rate limit: \(route.rateLimit.summary)")
            lines.append("- Success: \(route.successResponse.summary)")

            if let requestBody = route.requestBody {
                lines.append("")
                lines.append("### Request Body")
                lines.append("")
                lines.append("- Content-Type: \(requestBody.contentType)")
                lines.append("- Type: \(requestBody.typeName)")
                lines.append("")
                lines.append(contentsOf: makeFieldTableLines(for: requestBody.schema))
            }

            if let successSchema = route.successResponse.schema {
                lines.append("")
                lines.append("### Success Response")
                lines.append("")
                lines.append("- Status: \(route.successResponse.statusCode)")
                if let contentType = route.successResponse.contentType {
                    lines.append("- Content-Type: \(contentType)")
                }
                if let typeName = route.successResponse.typeName {
                    lines.append("- Type: \(typeName)")
                }
                lines.append("- Envelope: \(route.successResponse.envelope)")
                lines.append("")
                lines.append(contentsOf: makeFieldTableLines(for: successSchema))
            }

            if !route.errors.isEmpty {
                lines.append("")
                lines.append("### Standard Errors")
                lines.append("")
                lines.append("| Status | Code | Reason |")
                lines.append("|---|---|---|")
                for error in route.errors {
                    lines.append("| \(error.statusCode) | \(error.code) | \(error.reason) |")
                }
            }
        }

        if !snapshot.schemas.isEmpty {
            lines.append("")
            lines.append("## Schemas")
            for name in snapshot.schemas.keys.sorted() {
                guard let schema = snapshot.schemas[name] else { continue }
                lines.append("")
                lines.append("### \(name)")
                lines.append("")
                lines.append(contentsOf: makeFieldTableLines(for: schema))
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - HTML Rendering

    private func renderHTML(for snapshot: RouteDocumentationSnapshot) -> String {
        var html = htmlHead(for: snapshot)
        let groups = routeGroups(from: snapshot.routes)

        // --- Sidebar ---
        html += "<aside class=\"sidebar\" id=\"sidebar\">\n"
        html += "  <div class=\"sidebar-brand\"><span class=\"brand-icon\">T</span> Tricount API</div>\n"
        html += "  <div class=\"sidebar-search\">\n"
        html += "    <svg class=\"search-icon\" width=\"14\" height=\"14\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\"><circle cx=\"11\" cy=\"11\" r=\"8\"/><path d=\"m21 21-4.3-4.3\"/></svg>\n"
        html += "    <input type=\"text\" id=\"search\" placeholder=\"Search endpoints...\" autocomplete=\"off\">\n"
        html += "  </div>\n"
        html += "  <nav class=\"sidebar-nav\" id=\"sidebar-nav\">\n"

        for group in groups {
            html += "  <div class=\"nav-group\">\n"
            html += "    <div class=\"nav-group-title\">\(escapeHTML(group.title))</div>\n"
            for route in group.routes {
                let m = route.method.lowercased()
                html += "    <a class=\"nav-item\" href=\"#\(routeAnchor(route))\" data-search=\"\(escapeHTML(route.method.lowercased())) \(escapeHTML(route.path.lowercased()))\">"
                html += "<span class=\"nav-method \(m)\">\(escapeHTML(route.method))</span>"
                html += "<span class=\"nav-path\">\(escapeHTML(shortPath(route.path, group: group.prefix)))</span></a>\n"
            }
            html += "  </div>\n"
        }

        if !snapshot.schemas.isEmpty {
            html += "  <div class=\"nav-group\">\n"
            html += "    <div class=\"nav-group-title\">Schemas</div>\n"
            for name in snapshot.schemas.keys.sorted() {
                html += "    <a class=\"nav-item\" href=\"#schema-\(escapeHTML(name))\" data-search=\"schema \(escapeHTML(name.lowercased()))\">"
                html += "<span class=\"nav-schema-icon\">{ }</span>"
                html += "<span class=\"nav-path\">\(escapeHTML(name))</span></a>\n"
            }
            html += "  </div>\n"
        }

        html += "  </nav>\n"
        html += "  <div class=\"sidebar-footer\">\n"
        html += "    <span class=\"env-badge\">\(escapeHTML(snapshot.environment))</span>\n"
        html += "    <span class=\"stat\">\(snapshot.routeCount) endpoints</span>\n"
        html += "    <button class=\"theme-toggle\" id=\"theme-toggle\" aria-label=\"Toggle theme\">\n"
        html += "      <svg class=\"icon-sun\" width=\"16\" height=\"16\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\"><circle cx=\"12\" cy=\"12\" r=\"5\"/><path d=\"M12 1v2M12 21v2M4.22 4.22l1.42 1.42M18.36 18.36l1.42 1.42M1 12h2M21 12h2M4.22 19.78l1.42-1.42M18.36 5.64l1.42-1.42\"/></svg>\n"
        html += "      <svg class=\"icon-moon\" width=\"16\" height=\"16\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\"><path d=\"M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z\"/></svg>\n"
        html += "    </button>\n"
        html += "  </div>\n"
        html += "</aside>\n"

        // --- Overlay for mobile sidebar ---
        html += "<div class=\"sidebar-overlay\" id=\"sidebar-overlay\"></div>\n"

        // --- Mobile header ---
        html += "<header class=\"mobile-header\" id=\"mobile-header\">\n"
        html += "  <button class=\"menu-btn\" id=\"menu-btn\" aria-label=\"Menu\">\n"
        html += "    <svg width=\"20\" height=\"20\" viewBox=\"0 0 20 20\" fill=\"none\"><path d=\"M3 5h14M3 10h14M3 15h14\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\"/></svg>\n"
        html += "  </button>\n"
        html += "  <span class=\"mobile-title\">Tricount API</span>\n"
        html += "  <button class=\"theme-toggle mobile-theme\" id=\"theme-toggle-mobile\" aria-label=\"Toggle theme\">\n"
        html += "    <svg class=\"icon-sun\" width=\"16\" height=\"16\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\"><circle cx=\"12\" cy=\"12\" r=\"5\"/><path d=\"M12 1v2M12 21v2M4.22 4.22l1.42 1.42M18.36 18.36l1.42 1.42M1 12h2M21 12h2M4.22 19.78l1.42-1.42M18.36 5.64l1.42-1.42\"/></svg>\n"
        html += "    <svg class=\"icon-moon\" width=\"16\" height=\"16\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\"><path d=\"M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z\"/></svg>\n"
        html += "  </button>\n"
        html += "</header>\n"

        // --- Main content ---
        html += "<main class=\"content\">\n"

        // Hero
        html += "<div class=\"hero\">\n"
        html += "  <h1>API Reference</h1>\n"
        html += "  <p class=\"hero-sub\">Complete endpoint documentation for <strong>tricount-backend</strong></p>\n"
        html += "  <div class=\"hero-stats\">\n"
        html += "    <div class=\"stat-card\"><div class=\"stat-value\">\(snapshot.routeCount)</div><div class=\"stat-label\">Endpoints</div></div>\n"
        html += "    <div class=\"stat-card\"><div class=\"stat-value\">\(snapshot.schemas.count)</div><div class=\"stat-label\">Schemas</div></div>\n"
        html += "    <div class=\"stat-card\"><div class=\"stat-value\">\(escapeHTML(snapshot.environment))</div><div class=\"stat-label\">Environment</div></div>\n"
        html += "  </div>\n"
        html += "</div>\n"

        // --- Environment Variables Legend (Hoppscotch <<variable>> syntax) ---
        html += "<div class=\"env-legend\">\n"
        html += "  <div class=\"env-legend-title\">"
        html += "<svg width=\"14\" height=\"14\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\"><circle cx=\"12\" cy=\"12\" r=\"3\"/><path d=\"M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z\"/></svg>"
        html += " Environment Variables <span class=\"env-hint\">(Hoppscotch &lt;&lt;variable&gt;&gt; syntax \u{2014} copy &amp; paste directly)</span></div>\n"
        html += "  <table class=\"env-table\">\n"
        html += "    <thead><tr><th>Variable</th><th>Description</th><th>Default</th></tr></thead>\n"
        html += "    <tbody>\n"
        html += "    <tr><td><code>&lt;&lt;baseURL&gt;&gt;</code></td><td>API base URL</td><td class=\"env-default\">http://127.0.0.1:8080</td></tr>\n"
        html += "    <tr><td><code>&lt;&lt;accessToken&gt;&gt;</code></td><td>JWT access token from login/register</td><td class=\"env-default\">\u{2014}</td></tr>\n"
        html += "    <tr><td><code>&lt;&lt;refreshToken&gt;&gt;</code></td><td>Refresh token from login/register</td><td class=\"env-default\">\u{2014}</td></tr>\n"
        html += "    <tr><td><code>&lt;&lt;userEmail&gt;&gt;</code></td><td>Test user email</td><td class=\"env-default\">user@example.com</td></tr>\n"
        html += "    <tr><td><code>&lt;&lt;userPassword&gt;&gt;</code></td><td>Test user password</td><td class=\"env-default\">Password1</td></tr>\n"
        html += "    <tr><td><code>&lt;&lt;challengeToken&gt;&gt;</code></td><td>MFA challenge token from login response</td><td class=\"env-default\">\u{2014}</td></tr>\n"
        html += "    <tr><td><code>&lt;&lt;otpCode&gt;&gt;</code></td><td>6-digit OTP code from email/SMS</td><td class=\"env-default\">\u{2014}</td></tr>\n"
        html += "    <tr><td><code>&lt;&lt;idToken&gt;&gt;</code></td><td>Google/Apple OAuth ID token</td><td class=\"env-default\">\u{2014}</td></tr>\n"
        html += "    <tr><td><code>&lt;&lt;displayName&gt;&gt;</code></td><td>User display name</td><td class=\"env-default\">Test User</td></tr>\n"
        html += "    <tr><td><code>&lt;&lt;phoneNumber&gt;&gt;</code></td><td>Phone in E.164 format</td><td class=\"env-default\">+919876543210</td></tr>\n"
        html += "    </tbody>\n"
        html += "  </table>\n"
        html += "</div>\n"

        for group in groups {
            html += "<section class=\"endpoint-group\" id=\"group-\(escapeHTML(group.prefix))\">\n"
            html += "  <h2>\(escapeHTML(group.title))</h2>\n"
            for route in group.routes { html += renderRouteCard(route) }
            html += "</section>\n"
        }

        if !snapshot.schemas.isEmpty {
            html += "<section class=\"endpoint-group\" id=\"group-schemas\">\n"
            html += "  <h2>Schemas</h2>\n"
            for name in snapshot.schemas.keys.sorted() {
                guard let schema = snapshot.schemas[name] else { continue }
                html += "<div class=\"card\" id=\"schema-\(escapeHTML(name))\">\n"
                html += "  <div class=\"card-header\"><span class=\"schema-title\">{ } \(escapeHTML(name))</span></div>\n"
                html += "  <div class=\"card-body\">\(fieldTable(for: schema))</div>\n"
                html += "</div>\n"
            }
            html += "</section>\n"
        }

        html += "<footer class=\"page-footer\">Generated \(escapeHTML(snapshot.generatedAt))</footer>\n"
        html += "</main>\n"
        html += htmlScript()
        html += "</body>\n</html>\n"
        return html
    }

    private func renderRouteCard(_ route: RouteDocumentationEntry) -> String {
        let m = route.method.lowercased()
        var h = "<div class=\"card\" id=\"\(routeAnchor(route))\">\n"

        // --- Card header (full width) ---
        h += "<div class=\"card-header\"><div class=\"endpoint-line\">"
        h += "<span class=\"method-pill \(m)\">\(escapeHTML(route.method))</span>"
        h += "<code class=\"endpoint-path\">\(escapeHTML(route.path))</code></div>\n"
        h += "<div class=\"tag-row\">\(authBadge(route.auth))\n"
        if route.rateLimit.summary != "disabled" {
            h += "<span class=\"tag tag-rate\">\(escapeHTML(route.rateLimit.summary))</span>\n"
        }
        h += "</div></div>\n"

        // --- Two-panel body ---
        h += "<div class=\"card-panels\">\n"

        // Left panel: details
        h += "<div class=\"panel-left\">\n"
        if let summary = route.summary, !summary.isEmpty {
            h += "<div class=\"card-description\">\(escapeHTML(summary))</div>\n"
        }
        if let rb = route.requestBody {
            h += "<div class=\"detail-section\"><div class=\"detail-header\">"
            h += "<span class=\"detail-icon req\">&#x2191;</span> Request Body</div>\n"
            h += "<div class=\"detail-meta\"><code>\(escapeHTML(rb.contentType))</code> &middot; <code>\(escapeHTML(rb.typeName))</code></div>\n"
            h += fieldTable(for: rb.schema) + "</div>\n"
        }
        if let ss = route.successResponse.schema {
            h += "<div class=\"detail-section\"><div class=\"detail-header\">"
            h += "<span class=\"detail-icon res\">&#x2193;</span> Response <span class=\"status-code\">\(route.successResponse.statusCode)</span></div>\n"
            h += "<div class=\"detail-meta\">"
            if let ct = route.successResponse.contentType { h += "<code>\(escapeHTML(ct))</code> &middot; " }
            if let tn = route.successResponse.typeName { h += "<code>\(escapeHTML(tn))</code> &middot; " }
            h += "Envelope: <code>\(escapeHTML(route.successResponse.envelope))</code></div>\n"
            h += fieldTable(for: ss) + "</div>\n"
        }
        if !route.errors.isEmpty {
            h += "<div class=\"detail-section\"><div class=\"detail-header\">"
            h += "<span class=\"detail-icon err\">!</span> Errors</div>\n"
            h += "<table class=\"error-table\"><thead><tr><th>Status</th><th>Code</th><th>Reason</th></tr></thead><tbody>\n"
            for e in route.errors {
                h += "<tr><td><span class=\"status-code err\">\(e.statusCode)</span></td>"
                h += "<td><code>\(escapeHTML(e.code))</code></td><td>\(escapeHTML(e.reason))</td></tr>\n"
            }
            h += "</tbody></table></div>\n"
        }
        h += "</div>\n" // end panel-left

        // Right panel: curl
        h += "<div class=\"panel-right\">\n"
        h += "<div class=\"curl-panel\">\n"
        h += "  <div class=\"curl-header\"><span class=\"curl-label\">&gt;_ cURL</span>"
        h += "<button class=\"copy-btn\" data-target=\"curl-\(routeAnchor(route))\" title=\"Copy to clipboard\">"
        h += "<svg width=\"12\" height=\"12\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\"><rect x=\"9\" y=\"9\" width=\"13\" height=\"13\" rx=\"2\"/><path d=\"M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1\"/></svg>"
        h += " Copy</button></div>\n"
        h += "  <pre class=\"curl-block\" id=\"curl-\(routeAnchor(route))\"><code>"
        h += escapeHTML(curlExample(for: route))
        h += "</code></pre>\n"
        h += "</div>\n"
        h += "</div>\n" // end panel-right

        h += "</div>\n" // end card-panels
        h += "</div>\n" // end card
        return h
    }

    private func curlExample(for route: RouteDocumentationEntry) -> String {
        var parts: [String] = ["curl -X \(route.method) \"<<baseURL>>\(route.path)\""]
        parts.append("  -H \"Content-Type: application/json\"")
        if route.auth == "bearer" {
            parts.append("  -H \"Authorization: Bearer <<accessToken>>\"")
        }
        if let rb = route.requestBody {
            let sampleBody = sampleJSON(for: rb.schema, indent: 4)
            parts.append("  -d '\(sampleBody)'")
        }
        return parts.joined(separator: " \\\n")
    }

    private func sampleJSON(for schema: DocumentationSchema, indent: Int = 2) -> String {
        let fields = schema.flattenedFields()
        guard !fields.isEmpty else { return "{}" }

        let pad = String(repeating: " ", count: indent)
        var lines: [String] = ["{"]
        let topLevel = fields.filter { !$0.path.contains(".") }
        for (i, field) in topLevel.enumerated() {
            let comma = i < topLevel.count - 1 ? "," : ""
            let value = sampleValue(for: field.type, fieldName: field.path)
            lines.append("\(pad)\"\(field.path)\": \(value)\(comma)")
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    private func sampleValue(for type: String, fieldName: String = "") -> String {
        // Map well-known field names to Hoppscotch <<variable>> syntax
        let name = fieldName.lowercased()
        switch name {
        case "email":                           return "\"<<userEmail>>\""
        case "password", "newpassword":         return "\"<<userPassword>>\""
        case "idtoken":                         return "\"<<idToken>>\""
        case "refreshtoken":                    return "\"<<refreshToken>>\""
        case "challengetoken":                  return "\"<<challengeToken>>\""
        case "code":                            return "\"<<otpCode>>\""
        case "phonenumber":                     return "\"<<phoneNumber>>\""
        case "credentialid":                    return "\"<<credentialId>>\""
        case "displayname":                     return "\"<<displayName>>\""
        case "title":                           return "\"<<title>>\""
        default: break
        }

        let clean = type.replacingOccurrences(of: "?", with: "")
        switch clean {
        case "string":          return "\"...\""
        case "string(uuid)":    return "\"00000000-0000-0000-0000-000000000000\""
        case "string(email)":   return "\"user@example.com\""
        case "string(date)":    return "\"2025-01-01T00:00:00Z\""
        case "boolean", "bool": return "true"
        case "integer", "int":  return "0"
        case "number", "double", "float": return "0.0"
        default:
            if clean.hasPrefix("Array") { return "[]" }
            if clean.hasPrefix("object") { return "{}" }
            return "\"...\""
        }
    }

    private func fieldTable(for schema: DocumentationSchema) -> String {
        let fields = rootFieldRows(for: schema)
        guard !fields.isEmpty else { return "<p class=\"empty\">No structured fields documented.</p>\n" }
        var h = "<table class=\"field-table\"><thead><tr><th>Field</th><th>Type</th><th>Required</th></tr></thead><tbody>\n"
        for f in fields {
            let dot = f.required
                ? "<span class=\"req-dot yes\" title=\"Required\"></span>"
                : "<span class=\"req-dot no\" title=\"Optional\"></span>"
            h += "<tr><td><code class=\"field-name\">\(escapeHTML(f.path))</code></td>"
            h += "<td><code class=\"field-type\">\(escapeHTML(f.type))</code></td>"
            h += "<td class=\"req-cell\">\(dot)</td></tr>\n"
        }
        return h + "</tbody></table>\n"
    }

    private func authBadge(_ auth: String) -> String {
        auth == "bearer"
            ? "<span class=\"tag tag-auth-bearer\">Bearer Auth</span>"
            : "<span class=\"tag tag-public\">Public</span>"
    }

    private func routeAnchor(_ route: RouteDocumentationEntry) -> String {
        "\(route.method.lowercased())-\(route.path.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: CharacterSet(charactersIn: "-")))"
    }

    private func escapeHTML(_ string: String) -> String {
        string.replacingOccurrences(of: "&", with: "&amp;")
              .replacingOccurrences(of: "<", with: "&lt;")
              .replacingOccurrences(of: ">", with: "&gt;")
              .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func routeGroups(from routes: [RouteDocumentationEntry]) -> [RouteGroup] {
        var groups: [String: [RouteDocumentationEntry]] = [:]
        var order: [String] = []
        for route in routes {
            let segs = route.path.split(separator: "/").map(String.init)
            let prefix = segs.count >= 2 ? segs.prefix(2).joined(separator: "/") : (segs.first ?? "root")
            if groups[prefix] == nil { order.append(prefix) }
            groups[prefix, default: []].append(route)
        }
        return order.compactMap { key in
            groups[key].map { RouteGroup(prefix: key, title: key == "root" ? "Root" : key.replacingOccurrences(of: "/", with: " / ").capitalized, routes: $0) }
        }
    }

    private func shortPath(_ fullPath: String, group: String) -> String {
        let prefix = "/" + group
        if fullPath.hasPrefix(prefix) {
            let rest = String(fullPath.dropFirst(prefix.count))
            return rest.isEmpty ? "/" : rest
        }
        return fullPath
    }

    // swiftlint:disable function_body_length
    private func htmlHead(for snapshot: RouteDocumentationSnapshot) -> String {
        """
        <!DOCTYPE html>
        <html lang="en" data-theme="dark">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="dark light">
        <title>Tricount API Reference</title>
        <style>
        *,*::before,*::after{box-sizing:border-box;margin:0;padding:0}

        /* ===== DARK THEME (default) ===== */
        :root,[data-theme="dark"]{
          --bg:#09090b;--bg-sidebar:#0c0c0f;--surface:#18181b;--surface-hover:#1f1f23;--surface-active:#27272a;
          --border:#27272a;--border-light:#3f3f46;
          --text:#fafafa;--text-secondary:#a1a1aa;--text-muted:#71717a;
          --accent:#818cf8;--accent-subtle:rgba(129,140,248,0.08);
          --green:#34d399;--green-bg:rgba(52,211,153,0.12);
          --blue:#60a5fa;--blue-bg:rgba(96,165,250,0.12);
          --red:#f87171;--red-bg:rgba(248,113,113,0.12);
          --yellow:#fbbf24;--yellow-bg:rgba(251,191,36,0.12);
          --purple:#a78bfa;--purple-bg:rgba(167,139,250,0.12);
          --shadow:0 1px 3px rgba(0,0,0,.4);
          --shadow-lg:0 8px 30px rgba(0,0,0,.5);
          --overlay:rgba(0,0,0,.6);
        }

        /* ===== LIGHT THEME ===== */
        [data-theme="light"]{
          --bg:#f8fafc;--bg-sidebar:#ffffff;--surface:#ffffff;--surface-hover:#f1f5f9;--surface-active:#e2e8f0;
          --border:#e2e8f0;--border-light:#cbd5e1;
          --text:#0f172a;--text-secondary:#475569;--text-muted:#94a3b8;
          --accent:#6366f1;--accent-subtle:rgba(99,102,241,0.06);
          --green:#059669;--green-bg:rgba(5,150,105,0.08);
          --blue:#2563eb;--blue-bg:rgba(37,99,235,0.08);
          --red:#dc2626;--red-bg:rgba(220,38,38,0.08);
          --yellow:#d97706;--yellow-bg:rgba(217,119,6,0.08);
          --purple:#7c3aed;--purple-bg:rgba(124,58,237,0.08);
          --shadow:0 1px 3px rgba(0,0,0,.06);
          --shadow-lg:0 8px 30px rgba(0,0,0,.1);
          --overlay:rgba(0,0,0,.3);
        }

        :root{
          --radius:10px;--radius-sm:6px;
          --font:-apple-system,BlinkMacSystemFont,'Inter','Segoe UI',Roboto,sans-serif;
          --mono:'SF Mono','JetBrains Mono','Fira Code','Cascadia Code',monospace;
          --sidebar-w:272px;
        }
        html{scroll-behavior:smooth;scroll-padding-top:5rem}
        body{font-family:var(--font);background:var(--bg);color:var(--text);line-height:1.6;font-size:14px;-webkit-font-smoothing:antialiased;transition:background .2s,color .2s}

        /* ===== SIDEBAR ===== */
        .sidebar{position:fixed;top:0;left:0;bottom:0;width:var(--sidebar-w);background:var(--bg-sidebar);border-right:1px solid var(--border);display:flex;flex-direction:column;z-index:100;transition:background .2s,border-color .2s}
        .sidebar-brand{padding:1.25rem 1rem 0.75rem;font-weight:700;font-size:0.95rem;display:flex;align-items:center;gap:0.6rem;color:var(--text)}
        .brand-icon{width:30px;height:30px;border-radius:8px;background:linear-gradient(135deg,#818cf8,#a78bfa);display:flex;align-items:center;justify-content:center;font-weight:800;font-size:0.9rem;color:#fff;flex-shrink:0}
        .sidebar-search{padding:0.4rem 0.75rem;position:relative}
        .search-icon{position:absolute;left:1.15rem;top:50%;transform:translateY(-50%);color:var(--text-muted);pointer-events:none}
        .sidebar-search input{width:100%;padding:0.5rem 0.75rem 0.5rem 2rem;background:var(--surface);border:1px solid var(--border);border-radius:var(--radius-sm);color:var(--text);font-size:0.8rem;outline:none;transition:border-color .15s,background .2s}
        .sidebar-search input:focus{border-color:var(--accent);background:var(--surface-hover)}
        .sidebar-search input::placeholder{color:var(--text-muted)}
        .sidebar-nav{flex:1;overflow-y:auto;padding:0.25rem 0;scrollbar-width:thin;scrollbar-color:var(--border) transparent}
        .sidebar-nav::-webkit-scrollbar{width:4px}
        .sidebar-nav::-webkit-scrollbar-track{background:transparent}
        .sidebar-nav::-webkit-scrollbar-thumb{background:var(--border);border-radius:4px}
        .nav-group{padding:0.15rem 0}
        .nav-group-title{padding:0.6rem 1rem 0.2rem;font-size:0.65rem;font-weight:700;text-transform:uppercase;letter-spacing:0.08em;color:var(--text-muted)}
        .nav-item{display:flex;align-items:center;gap:0.5rem;padding:0.35rem 1rem;color:var(--text-secondary);text-decoration:none;font-size:0.8rem;transition:all .1s;border-left:2px solid transparent;margin:0 0.25rem}
        .nav-item:hover{background:var(--surface-hover);color:var(--text);border-radius:0 var(--radius-sm) var(--radius-sm) 0}
        .nav-item.active{color:var(--accent);background:var(--accent-subtle);border-left-color:var(--accent);border-radius:0 var(--radius-sm) var(--radius-sm) 0}
        .nav-method{font-family:var(--mono);font-size:0.6rem;font-weight:700;min-width:38px;text-align:center;padding:0.15rem 0;border-radius:3px;flex-shrink:0;letter-spacing:.02em}
        .nav-method.get{color:var(--green);background:var(--green-bg)}
        .nav-method.post{color:var(--blue);background:var(--blue-bg)}
        .nav-method.delete{color:var(--red);background:var(--red-bg)}
        .nav-method.put{color:var(--yellow);background:var(--yellow-bg)}
        .nav-method.patch{color:var(--purple);background:var(--purple-bg)}
        .nav-path{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-family:var(--mono);font-size:0.78rem}
        .nav-schema-icon{font-family:var(--mono);font-size:0.65rem;color:var(--purple);min-width:38px;text-align:center;flex-shrink:0;background:var(--purple-bg);border-radius:3px;padding:0.15rem 0}
        .sidebar-footer{padding:0.6rem 1rem;border-top:1px solid var(--border);display:flex;align-items:center;gap:0.5rem;font-size:0.72rem;color:var(--text-muted)}
        .env-badge{padding:0.15rem 0.5rem;background:var(--surface-hover);border:1px solid var(--border);border-radius:var(--radius-sm);font-size:0.65rem;font-weight:700;text-transform:uppercase;letter-spacing:.04em}
        .stat{flex:1}

        /* ===== THEME TOGGLE ===== */
        .theme-toggle{background:var(--surface-hover);border:1px solid var(--border);border-radius:var(--radius-sm);color:var(--text-secondary);width:32px;height:32px;cursor:pointer;display:flex;align-items:center;justify-content:center;transition:all .15s;flex-shrink:0}
        .theme-toggle:hover{background:var(--surface-active);color:var(--text)}
        [data-theme="dark"] .icon-moon{display:none}
        [data-theme="light"] .icon-sun{display:none}

        /* ===== MOBILE ===== */
        .sidebar-overlay{display:none;position:fixed;inset:0;background:var(--overlay);z-index:99;opacity:0;transition:opacity .2s}
        .sidebar-overlay.visible{display:block;opacity:1}
        .mobile-header{display:none;position:sticky;top:0;z-index:90;background:var(--bg-sidebar);border-bottom:1px solid var(--border);padding:0.65rem 1rem;align-items:center;gap:0.75rem;transition:background .2s,border-color .2s}
        .menu-btn{background:none;border:1px solid var(--border);border-radius:var(--radius-sm);color:var(--text);padding:0.35rem;cursor:pointer;display:flex;align-items:center;justify-content:center;transition:all .15s}
        .menu-btn:hover{background:var(--surface-hover)}
        .mobile-title{font-weight:700;font-size:0.9rem;flex:1}
        .mobile-theme{margin-left:auto}

        /* ===== MAIN ===== */
        .content{margin-left:var(--sidebar-w);padding:2rem 2.5rem 4rem;max-width:1280px;transition:margin .2s}

        /* ===== HERO ===== */
        .hero{margin-bottom:2.5rem}
        .hero h1{font-size:1.85rem;font-weight:800;letter-spacing:-0.025em;margin-bottom:0.3rem}
        .hero-sub{color:var(--text-secondary);font-size:0.92rem;margin-bottom:1.25rem}
        .hero-stats{display:grid;grid-template-columns:repeat(3,1fr);gap:0.65rem}
        .stat-card{background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);padding:0.85rem 1rem;box-shadow:var(--shadow);transition:background .2s,border-color .2s,box-shadow .2s}
        .stat-value{font-size:1.15rem;font-weight:700;color:var(--text)}
        .stat-label{font-size:0.65rem;text-transform:uppercase;letter-spacing:.05em;color:var(--text-muted);font-weight:600;margin-top:0.1rem}

        /* ===== SECTIONS ===== */
        .endpoint-group{margin-bottom:2rem}
        .endpoint-group h2{font-size:1.05rem;font-weight:700;color:var(--text);padding-bottom:0.5rem;margin-bottom:0.85rem;border-bottom:1px solid var(--border)}

        /* ===== CARD ===== */
        .card{background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);margin-bottom:0.65rem;overflow:hidden;box-shadow:var(--shadow);transition:all .15s}
        .card:hover{border-color:var(--border-light);box-shadow:var(--shadow),0 0 0 1px var(--border)}
        .card-header{padding:0.85rem 1.1rem;border-bottom:1px solid var(--border)}
        .endpoint-line{display:flex;align-items:center;gap:0.5rem;margin-bottom:0.4rem;flex-wrap:wrap}
        .method-pill{font-family:var(--mono);font-size:0.68rem;font-weight:700;padding:0.2rem 0.55rem;border-radius:4px;text-transform:uppercase;letter-spacing:.02em}
        .method-pill.get{background:var(--green-bg);color:var(--green)}
        .method-pill.post{background:var(--blue-bg);color:var(--blue)}
        .method-pill.delete{background:var(--red-bg);color:var(--red)}
        .method-pill.put{background:var(--yellow-bg);color:var(--yellow)}
        .method-pill.patch{background:var(--purple-bg);color:var(--purple)}
        .endpoint-path{font-family:var(--mono);font-size:0.88rem;font-weight:600;color:var(--text);background:none;padding:0}
        .tag-row{display:flex;gap:0.35rem;flex-wrap:wrap}
        .tag{font-size:0.65rem;font-weight:600;padding:0.12rem 0.45rem;border-radius:4px;border:1px solid transparent}
        .tag-auth-bearer{background:var(--yellow-bg);color:var(--yellow);border-color:rgba(251,191,36,0.15)}
        .tag-public{background:var(--surface-hover);color:var(--text-muted);border-color:var(--border)}
        .tag-rate{background:var(--purple-bg);color:var(--purple);border-color:rgba(167,139,250,0.15)}
        .card-description{padding:0.65rem 1.1rem 0;color:var(--text-secondary);font-size:0.83rem}
        .card-body{padding:0.4rem 1.1rem 0.85rem}

        /* ===== DETAIL SECTIONS ===== */
        .detail-section{margin-top:0.65rem;padding-top:0.65rem;border-top:1px solid var(--border)}
        .detail-header{font-size:0.75rem;font-weight:700;text-transform:uppercase;letter-spacing:.04em;color:var(--text-secondary);margin-bottom:0.35rem;display:flex;align-items:center;gap:0.35rem}
        .detail-icon{width:18px;height:18px;border-radius:4px;display:inline-flex;align-items:center;justify-content:center;font-size:0.65rem;font-weight:800}
        .detail-icon.req{background:var(--blue-bg);color:var(--blue)}
        .detail-icon.res{background:var(--green-bg);color:var(--green)}
        .detail-icon.err{background:var(--red-bg);color:var(--red)}
        .detail-meta{font-size:0.75rem;color:var(--text-muted);margin-bottom:0.4rem}
        .detail-meta code{font-size:0.72rem;background:var(--surface-hover);padding:0.1rem 0.3rem;border-radius:3px;color:var(--text-secondary)}
        .status-code{font-family:var(--mono);font-size:0.7rem;font-weight:700;padding:0.1rem 0.4rem;border-radius:3px;background:var(--green-bg);color:var(--green)}
        .status-code.err{background:var(--red-bg);color:var(--red)}
        .schema-title{font-family:var(--mono);font-weight:700;font-size:0.92rem;color:var(--purple)}

        /* ===== TABLES ===== */
        .field-table,.error-table{width:100%;border-collapse:collapse;font-size:0.8rem}
        .field-table thead th,.error-table thead th{text-align:left;padding:0.4rem 0.55rem;font-size:0.65rem;font-weight:700;text-transform:uppercase;letter-spacing:.05em;color:var(--text-muted);border-bottom:1px solid var(--border)}
        .field-table tbody td,.error-table tbody td{padding:0.38rem 0.55rem;border-bottom:1px solid var(--border);vertical-align:top;transition:background .1s}
        .field-table tbody tr:last-child td,.error-table tbody tr:last-child td{border-bottom:none}
        .field-table tbody tr:hover td,.error-table tbody tr:hover td{background:var(--surface-hover)}
        .field-name{font-family:var(--mono);font-weight:600;font-size:0.78rem;color:var(--accent);background:none;padding:0}
        .field-type{font-family:var(--mono);font-size:0.76rem;color:var(--text-secondary);background:none;padding:0}
        .req-cell{width:28px;text-align:center}
        .req-dot{display:inline-block;width:8px;height:8px;border-radius:50%}
        .req-dot.yes{background:var(--green);box-shadow:0 0 0 2px var(--green-bg)}
        .req-dot.no{background:var(--border-light)}

        /* ===== TWO-PANEL LAYOUT ===== */
        .card-panels{display:grid;grid-template-columns:1fr 1fr;gap:0}
        .panel-left{padding:0.4rem 1.1rem 0.85rem;border-right:1px solid var(--border)}
        .panel-right{position:relative}
        .card-description{padding:0.4rem 0 0;color:var(--text-secondary);font-size:0.83rem}

        /* ===== CURL PANEL (right side) ===== */
        .curl-panel{position:sticky;top:4rem;padding:0}
        .curl-header{display:flex;align-items:center;justify-content:space-between;padding:0.55rem 0.85rem;border-bottom:1px solid var(--border);background:var(--surface-hover)}
        .curl-label{font-family:var(--mono);font-size:0.7rem;font-weight:700;color:var(--text-muted);text-transform:uppercase;letter-spacing:.04em}
        .curl-block{background:var(--bg);padding:0.85rem 1rem;overflow-x:auto;font-family:var(--mono);font-size:0.76rem;line-height:1.8;color:var(--text-secondary);white-space:pre;scrollbar-width:thin;scrollbar-color:var(--border) transparent;margin:0;border-radius:0}
        .curl-block::-webkit-scrollbar{height:4px}
        .curl-block::-webkit-scrollbar-track{background:transparent}
        .curl-block::-webkit-scrollbar-thumb{background:var(--border);border-radius:4px}
        .curl-block code{font-family:inherit;font-size:inherit;color:inherit;background:none;padding:0}
        .copy-btn{background:var(--surface);border:1px solid var(--border);border-radius:var(--radius-sm);color:var(--text-muted);font-size:0.68rem;font-weight:600;padding:0.2rem 0.55rem;cursor:pointer;transition:all .15s;font-family:var(--font);display:flex;align-items:center;gap:0.3rem}
        .copy-btn:hover{background:var(--surface-active);color:var(--text)}
        .copy-btn.copied{background:var(--green-bg);color:var(--green);border-color:rgba(52,211,153,0.2)}

        /* ===== ENV VARS LEGEND ===== */
        .env-legend{background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);padding:0.85rem 1.1rem;margin-bottom:1.5rem;box-shadow:var(--shadow)}
        .env-legend-title{font-size:0.75rem;font-weight:700;text-transform:uppercase;letter-spacing:.04em;color:var(--text-secondary);margin-bottom:0.5rem;display:flex;align-items:center;gap:0.35rem}
        .env-legend-title svg{color:var(--accent)}
        .env-table{width:100%;border-collapse:collapse;font-size:0.8rem}
        .env-table th{text-align:left;padding:0.35rem 0.55rem;font-size:0.65rem;font-weight:700;text-transform:uppercase;letter-spacing:.05em;color:var(--text-muted);border-bottom:1px solid var(--border)}
        .env-table td{padding:0.35rem 0.55rem;border-bottom:1px solid var(--border);vertical-align:top}
        .env-table tr:last-child td{border-bottom:none}
        .env-table code{font-family:var(--mono);font-size:0.76rem;color:var(--accent);background:var(--accent-subtle);padding:0.1rem 0.35rem;border-radius:3px}
        .env-table .env-default{font-family:var(--mono);font-size:0.74rem;color:var(--text-muted)}
        .env-hint{font-weight:400;font-size:0.7rem;color:var(--text-muted);text-transform:none;letter-spacing:0;margin-left:0.3rem}

        /* ===== FOOTER ===== */
        .page-footer{margin-top:3rem;padding-top:1.25rem;border-top:1px solid var(--border);color:var(--text-muted);font-size:0.72rem}
        .empty{color:var(--text-muted);font-style:italic;font-size:0.8rem;padding:0.4rem 0}

        /* ===== RESPONSIVE ===== */
        @media(max-width:1100px){
          .card-panels{grid-template-columns:1fr}
          .panel-left{border-right:none;border-bottom:1px solid var(--border)}
          .panel-right{position:static}
          .curl-panel{position:static}
        }
        @media(max-width:900px){
          .content{padding:2rem 1.5rem 4rem}
        }
        @media(max-width:768px){
          .sidebar{transform:translateX(-100%);transition:transform .25s cubic-bezier(.4,0,.2,1),background .2s;box-shadow:none;width:min(var(--sidebar-w),85vw)}
          .sidebar.open{transform:translateX(0);box-shadow:var(--shadow-lg)}
          .mobile-header{display:flex}
          .content{margin-left:0;padding:1rem 0.85rem 3rem}
          .hero h1{font-size:1.4rem}
          .hero-stats{grid-template-columns:repeat(3,1fr);gap:0.4rem}
          .stat-card{padding:0.6rem 0.7rem}
          .stat-value{font-size:0.95rem}
          .stat-label{font-size:0.6rem}
          .card-header{padding:0.75rem 0.85rem}
          .card-body{padding:0.35rem 0.85rem 0.75rem}
          .endpoint-path{font-size:0.8rem}
          .method-pill{font-size:0.6rem;padding:0.15rem 0.45rem}
          .field-table,.error-table{font-size:0.75rem}
          .field-table thead th,.error-table thead th{padding:0.35rem 0.4rem;font-size:0.6rem}
          .field-table tbody td,.error-table tbody td{padding:0.3rem 0.4rem}
          .field-name{font-size:0.72rem}
          .field-type{font-size:0.7rem}
          .endpoint-group h2{font-size:0.95rem}
        }
        @media(max-width:400px){
          .hero-stats{grid-template-columns:1fr}
          .stat-card{display:flex;align-items:center;gap:0.5rem;padding:0.5rem 0.75rem}
          .stat-value{font-size:0.9rem;margin-bottom:0}
          .stat-label{margin-top:0}
        }
        </style>
        </head>
        <body>

        """
    }
    // swiftlint:enable function_body_length

    private func htmlScript() -> String {
        """
        <script>
        (function(){
          // --- Theme ---
          function getPreferred(){
            var saved = localStorage.getItem('tricount-docs-theme');
            if(saved) return saved;
            return matchMedia('(prefers-color-scheme:light)').matches ? 'light' : 'dark';
          }
          function applyTheme(t){
            document.documentElement.setAttribute('data-theme',t);
            localStorage.setItem('tricount-docs-theme',t);
          }
          applyTheme(getPreferred());
          function toggle(){applyTheme(document.documentElement.getAttribute('data-theme')==='dark'?'light':'dark');}
          document.getElementById('theme-toggle').addEventListener('click',toggle);
          var mobileToggle=document.getElementById('theme-toggle-mobile');
          if(mobileToggle) mobileToggle.addEventListener('click',toggle);
          matchMedia('(prefers-color-scheme:light)').addEventListener('change',function(e){
            if(!localStorage.getItem('tricount-docs-theme')) applyTheme(e.matches?'light':'dark');
          });

          // --- Mobile sidebar ---
          var sidebar=document.getElementById('sidebar');
          var overlay=document.getElementById('sidebar-overlay');
          var menuBtn=document.getElementById('menu-btn');
          function openSidebar(){sidebar.classList.add('open');overlay.classList.add('visible');}
          function closeSidebar(){sidebar.classList.remove('open');overlay.classList.remove('visible');}
          menuBtn.addEventListener('click',function(){sidebar.classList.contains('open')?closeSidebar():openSidebar();});
          overlay.addEventListener('click',closeSidebar);

          // --- Search ---
          var input=document.getElementById('search');
          var items=document.querySelectorAll('.nav-item');
          var groups=document.querySelectorAll('.nav-group');
          input.addEventListener('input',function(){
            var q=this.value.toLowerCase().trim();
            groups.forEach(function(g){
              var children=g.querySelectorAll('.nav-item');
              var any=false;
              children.forEach(function(item){
                var match=!q||(item.getAttribute('data-search')||'').indexOf(q)!==-1;
                item.style.display=match?'':'none';
                if(match) any=true;
              });
              g.style.display=any?'':'none';
            });
          });

          // --- Active link tracking ---
          var observer=new IntersectionObserver(function(entries){
            entries.forEach(function(e){
              if(e.isIntersecting){
                items.forEach(function(a){a.classList.remove('active');});
                var t=document.querySelector('.nav-item[href=\"#'+e.target.id+'\"]');
                if(t){t.classList.add('active');t.scrollIntoView({block:'nearest',behavior:'smooth'});}
              }
            });
          },{rootMargin:'-80px 0px -65% 0px'});
          document.querySelectorAll('.card[id]').forEach(function(el){observer.observe(el);});

          // --- Close sidebar on nav click (mobile) ---
          items.forEach(function(a){a.addEventListener('click',closeSidebar);});

          // --- Copy curl to clipboard ---
          document.querySelectorAll('.copy-btn').forEach(function(btn){
            btn.addEventListener('click',function(){
              var targetId=this.getAttribute('data-target');
              var block=document.getElementById(targetId);
              if(!block) return;
              var text=block.textContent||block.innerText;
              navigator.clipboard.writeText(text).then(function(){
                btn.textContent='\\u2713 Copied!';
                btn.classList.add('copied');
                setTimeout(function(){btn.innerHTML='&#x2398; Copy';btn.classList.remove('copied');},2000);
              });
            });
          });

          // --- Keyboard shortcut: / to focus search ---
          document.addEventListener('keydown',function(e){
            if(e.key==='/'&&document.activeElement!==input){e.preventDefault();input.focus();}
            if(e.key==='Escape'){input.blur();input.value='';input.dispatchEvent(new Event('input'));closeSidebar();}
          });
        })();
        </script>\n
        """
    }

    private func makeFieldTableLines(for schema: DocumentationSchema) -> [String] {
        let fields = rootFieldRows(for: schema)
        guard !fields.isEmpty else {
            return ["No structured fields documented."]
        }

        var lines = [
            "| Field | Type | Required |",
            "|---|---|---|",
        ]

        for field in fields {
            lines.append("| \(field.path) | \(field.type) | \(field.required ? "yes" : "no") |")
        }

        return lines
    }

    private func rootFieldRows(for schema: DocumentationSchema) -> [DocumentationFieldRow] {
        let flattened = schema.flattenedFields()
        if !flattened.isEmpty {
            return flattened
        }

        switch schema {
        case .array(let items, _):
            let itemFields = items.flattenedFields(prefix: "item")
            if !itemFields.isEmpty {
                return itemFields
            }
            return [DocumentationFieldRow(path: "item", type: items.markdownType, required: true)]
        default:
            return [DocumentationFieldRow(path: "value", type: schema.markdownType, required: true)]
        }
    }

    private static func pathString(for route: Route) -> String {
        let value = route.path.map { "\($0)" }.joined(separator: "/")
        return value.isEmpty ? "/" : "/\(value)"
    }
}

private struct RouteDocumentationSnapshot {
    let service: String
    let environment: String
    let generatedAt: String
    let routeCount: Int
    let schemas: [String: DocumentationSchema]
    let routes: [RouteDocumentationEntry]

    var jsonObject: [String: Any] {
        [
            "service": service,
            "environment": environment,
            "generatedAt": generatedAt,
            "routeCount": routeCount,
            "schemaCount": schemas.count,
            "schemas": Dictionary(uniqueKeysWithValues: schemas.map { ($0.key, $0.value.jsonObject) }),
            "routes": routes.map(\.jsonObject)
        ]
    }
}

private struct RouteDocumentationEntry {
    let method: String
    let path: String
    let summary: String?
    let auth: String
    let rateLimit: RouteRateLimitDocumentation
    let requestBody: RouteDocumentationRequestBodyEntry?
    let successResponse: RouteDocumentationSuccessResponseEntry
    let errors: [RouteDocumentationErrorEntry]

    var schemas: [NamedSchema] {
        var values: [NamedSchema] = []

        if let requestBody {
            values.append(NamedSchema(name: requestBody.typeName, schema: requestBody.schema))
        }

        if let typeName = successResponse.typeName, let payloadSchema = successResponse.payloadSchema {
            values.append(NamedSchema(name: typeName, schema: payloadSchema))
        }

        for error in errors {
            values.append(NamedSchema(name: error.typeName, schema: error.schema))
        }

        return values
    }

    var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "method": method,
            "path": path,
            "auth": auth,
            "rateLimit": rateLimit.jsonObject,
            "successResponse": successResponse.jsonObject,
            "errors": errors.map(\.jsonObject)
        ]

        if let summary {
            object["summary"] = summary
        }
        if let requestBody {
            object["requestBody"] = requestBody.jsonObject
        }

        return object
    }
}

private struct RouteDocumentationRequestBodyEntry {
    let contentType: String
    let typeName: String
    let schema: DocumentationSchema

    init(requestBody: RouteDocumentationRequestBody) {
        self.contentType = requestBody.contentType
        self.typeName = requestBody.typeName
        self.schema = requestBody.schema
    }

    var jsonObject: [String: Any] {
        [
            "contentType": contentType,
            "typeName": typeName,
            "schema": schema.jsonObject
        ]
    }
}

private struct RouteDocumentationSuccessResponseEntry {
    let statusCode: Int
    let contentType: String?
    let typeName: String?
    let envelope: String
    let payloadSchema: DocumentationSchema?
    let schema: DocumentationSchema?
    let summary: String

    init(response: RouteDocumentationResponse) {
        self.statusCode = response.statusCode
        self.contentType = response.contentType
        self.typeName = response.typeName
        self.envelope = response.envelope.rawValue
        self.payloadSchema = response.payloadSchema
        self.schema = response.schema
        switch response.envelope {
        case .empty:
            self.summary = "\(response.statusCode) no-content"
        case .raw:
            self.summary = "\(response.statusCode) raw<\(response.typeName ?? "unknown")>"
        case .data:
            self.summary = "\(response.statusCode) data<\(response.typeName ?? "unknown")>"
        }
    }

    var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "statusCode": statusCode,
            "envelope": envelope,
            "summary": summary
        ]
        if let contentType {
            object["contentType"] = contentType
        }
        if let typeName {
            object["typeName"] = typeName
        }
        if let payloadSchema {
            object["payloadSchema"] = payloadSchema.jsonObject
        }
        if let schema {
            object["schema"] = schema.jsonObject
        }
        return object
    }
}

private struct RouteDocumentationErrorEntry {
    let statusCode: Int
    let code: String
    let reason: String
    let typeName: String
    let schema: DocumentationSchema

    init(error: RouteDocumentationError) {
        self.statusCode = error.statusCode
        self.code = error.code
        self.reason = error.reason
        self.typeName = "ErrorResponse"
        self.schema = error.schema
    }

    var jsonObject: [String: Any] {
        [
            "statusCode": statusCode,
            "code": code,
            "reason": reason,
            "typeName": typeName,
            "schema": schema.jsonObject
        ]
    }
}

private struct NamedSchema {
    let name: String
    let schema: DocumentationSchema
}

private struct RouteGroup {
    let prefix: String
    let title: String
    let routes: [RouteDocumentationEntry]
}

private extension RouteDocumentationMetadata {
    static func fallback(from route: Route) -> RouteDocumentationMetadata {
        let typeName = prettyDocumentationTypeName(route.responseType)
        let hasStructuredType = route.responseType != Response.self
        return RouteDocumentationMetadata(
            auth: .none,
            requestBody: nil,
            successResponse: RouteDocumentationResponse(
                statusCode: Int(HTTPStatus.ok.code),
                contentType: hasStructuredType ? "application/json" : nil,
                typeName: hasStructuredType ? typeName : nil,
                envelope: .raw,
                payloadSchema: hasStructuredType ? .unknown(typeName: typeName) : nil
            )
        )
    }
}

private struct RouteRateLimitDocumentation {
    let mode: String
    let identifier: String?
    let limit: Int?
    let windowSeconds: Int?
    let keyStrategy: String?
    let summary: String

    init(policy: RateLimitPolicy?) {
        guard let policy, !policy.isDisabled else {
            self.mode = "disabled"
            self.identifier = nil
            self.limit = nil
            self.windowSeconds = nil
            self.keyStrategy = nil
            self.summary = "disabled"
            return
        }

        let mode = policy.identifier == RateLimitPolicy.default.identifier ? "default" : "custom"
        self.mode = mode
        self.identifier = policy.identifier
        self.limit = policy.limit
        self.windowSeconds = policy.windowSeconds
        self.keyStrategy = policy.keyStrategy.documentationName
        self.summary = "\(mode) (\(policy.limit) requests / \(policy.windowSeconds)s via \(policy.keyStrategy.documentationName))"
    }

    var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "mode": mode,
            "summary": summary
        ]
        if let identifier {
            object["identifier"] = identifier
        }
        if let limit {
            object["limit"] = limit
        }
        if let windowSeconds {
            object["windowSeconds"] = windowSeconds
        }
        if let keyStrategy {
            object["keyStrategy"] = keyStrategy
        }
        return object
    }
}

private extension RateLimitKeyStrategy {
    var documentationName: String {
        switch self {
        case .ip:
            return "ip"
        case .bodyEmail:
            return "bodyEmail"
        }
    }
}
