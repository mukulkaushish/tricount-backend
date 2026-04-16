import Foundation
import Vapor

struct RouteDocumentationGenerator {
    nonisolated(unsafe) private static let dateFormatter: ISO8601DateFormatter = ISO8601DateFormatter()

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
        let documentedRoutes = snapshot.routes.filter { $0.path.hasPrefix("/v1/") }
        let schemas = makeSchemas(from: documentedRoutes)

        // 1. Generate OpenAPI 3.1 spec
        let openAPISpec = buildOpenAPISpec(routes: documentedRoutes, schemas: schemas)
        let specData = try JSONSerialization.data(
            withJSONObject: openAPISpec,
            options: [.prettyPrinted, .sortedKeys]
        )
        let specURL = outputDirectory.appendingPathComponent("openapi.json")
        try specData.write(to: specURL, options: .atomic)

        // 2. Generate API Reference HTML (Scalar)
        let html = apiReferenceHTML()
        let htmlURL = outputDirectory.appendingPathComponent("index.html")
        try html.write(to: htmlURL, atomically: true, encoding: .utf8)

        // 3. Generate Postman collections (still useful for quick testing)
        let groups = routeGroups(from: documentedRoutes)
        let sectionArtifacts = sectionCollectionArtifacts(for: groups)

        try cleanupLegacyArtifacts(in: outputDirectory, groups: groups)

        let postman = renderPostmanCollection(
            name: "Tricount Backend",
            description: "Auto-generated from registered Vapor routes.\nTokens auto-extracted from auth responses.",
            routes: documentedRoutes
        )
        let postmanData = try JSONSerialization.data(
            withJSONObject: postman,
            options: [.prettyPrinted, .sortedKeys]
        )
        let postmanURL = outputDirectory.appendingPathComponent("Tricount-Backend.postman_collection.json")
        try postmanData.write(to: postmanURL, options: .atomic)

        for artifact in sectionArtifacts {
            let sectionPostman = renderPostmanCollection(
                name: "Tricount Backend - \(artifact.title)",
                description: "Auto-generated section collection for \(artifact.title).",
                routes: artifact.routes
            )
            let sectionData = try JSONSerialization.data(
                withJSONObject: sectionPostman,
                options: [.prettyPrinted, .sortedKeys]
            )
            let sectionURL = outputDirectory.appendingPathComponent(artifact.fileName)
            try sectionData.write(to: sectionURL, options: .atomic)
        }
    }

    // MARK: - OpenAPI 3.1 Spec

    private func buildOpenAPISpec(
        routes: [RouteDocumentationEntry],
        schemas: [String: DocumentationSchema]
    ) -> [String: Any] {
        var paths: [String: Any] = [:]

        for route in routes {
            let openAPIPath = route.path
                .replacingOccurrences(of: ":([a-zA-Z0-9_]+)", with: "{$1}", options: .regularExpression)

            var operation: [String: Any] = [:]

            // Tags from path grouping
            let segments = route.path.split(separator: "/").map(String.init)
            if segments.count >= 2 {
                let tag = segments[1]
                operation["tags"] = [humanizeSegment(tag)]
            }

            // Summary
            if let summary = route.summary {
                operation["summary"] = summary
            } else {
                operation["summary"] = operationSummary(method: route.method, path: route.path)
            }

            // Operation ID
            operation["operationId"] = operationID(method: route.method, path: route.path)

            // Security
            if route.auth == "bearer" {
                operation["security"] = [["bearerAuth": [] as [String]]]
            } else {
                operation["security"] = [] as [Any]
            }

            // Path parameters
            let pathParams = extractPathParameters(from: route.path)
            if !pathParams.isEmpty {
                operation["parameters"] = pathParams
            }

            // Request body
            if let body = route.requestBody {
                operation["requestBody"] = [
                    "required": true,
                    "content": [
                        body.contentType: [
                            "schema": schemaRef(body.typeName, fallback: body.schema)
                        ]
                    ]
                ] as [String: Any]
            }

            // Responses
            var responses: [String: Any] = [:]

            // Success response
            let statusCode = String(route.successResponse.statusCode)
            if let schema = route.successResponse.schema,
               let typeName = route.successResponse.typeName {
                responses[statusCode] = [
                    "description": "Success",
                    "content": [
                        "application/json": [
                            "schema": schemaRef(typeName, fallback: schema)
                        ]
                    ]
                ] as [String: Any]
            } else {
                responses[statusCode] = [
                    "description": "Success (no content)"
                ] as [String: Any]
            }

            // Error responses
            for error in route.errors {
                let errorStatus = String(error.statusCode)
                responses[errorStatus] = [
                    "description": error.reason,
                    "content": [
                        "application/json": [
                            "schema": ["$ref": "#/components/schemas/ErrorResponse"]
                        ]
                    ]
                ] as [String: Any]
            }

            operation["responses"] = responses

            // Rate limit info as extension
            if route.rateLimit.mode != "disabled" {
                operation["x-rate-limit"] = route.rateLimit.jsonObject
            }

            let method = route.method.lowercased()
            var pathItem = paths[openAPIPath] as? [String: Any] ?? [:]
            pathItem[method] = operation
            paths[openAPIPath] = pathItem
        }

        // Components / schemas
        var componentSchemas: [String: Any] = [:]
        for (name, schema) in schemas {
            componentSchemas[name] = schema.jsonObject
        }
        // Always include ErrorResponse
        componentSchemas["ErrorResponse"] = errorSchema.jsonObject

        // Build tag descriptions from groups
        let tagDescriptions: [[String: String]] = routeGroups(from: routes).map { group in
            ["name": group.title, "description": "Endpoints under /\(group.prefix)"]
        }

        return [
            "openapi": "3.1.0",
            "info": [
                "title": "Tricount API",
                "version": "1.0.0",
                "description": "Expense-splitting backend. Amounts in minor units (paise). All timestamps ISO 8601.",
                "contact": [
                    "name": "Tricount Backend"
                ]
            ] as [String: Any],
            "servers": [
                ["url": "http://localhost:8080", "description": "Local"]
            ],
            "tags": tagDescriptions,
            "paths": paths,
            "components": [
                "schemas": componentSchemas,
                "securitySchemes": [
                    "bearerAuth": [
                        "type": "http",
                        "scheme": "bearer",
                        "bearerFormat": "JWT",
                        "description": "JWT access token from /v1/auth/login or /v1/auth/register"
                    ] as [String: Any]
                ]
            ] as [String: Any]
        ]
    }

    private func schemaRef(_ typeName: String, fallback: DocumentationSchema) -> [String: Any] {
        if isPublicDocumentationType(typeName) && !fallback.isUnknown {
            return ["$ref": "#/components/schemas/\(typeName)"]
        }
        return fallback.jsonObject as? [String: Any] ?? ["type": "object"]
    }

    private func extractPathParameters(from path: String) -> [[String: Any]] {
        path.split(separator: "/")
            .filter { $0.hasPrefix(":") }
            .map { segment in
                let name = String(segment.dropFirst())
                return [
                    "name": name,
                    "in": "path",
                    "required": true,
                    "schema": name.lowercased().contains("id") || name == "id"
                        ? ["type": "string", "format": "uuid"] as [String: Any]
                        : ["type": "string"] as [String: Any]
                ] as [String: Any]
            }
    }

    private func operationID(method: String, path: String) -> String {
        let segments = path
            .split(separator: "/")
            .filter { !$0.hasPrefix(":") && $0 != "v1" }
            .map(String.init)

        let base = segments
            .map { $0.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined() }
            .joined()

        return method.lowercased() + base
    }

    private func operationSummary(method: String, path: String) -> String {
        let segments = path
            .split(separator: "/")
            .filter { !$0.hasPrefix(":") && $0 != "v1" }

        let label = segments
            .map { $0.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ") }
            .joined(separator: " > ")

        return "\(method) \(label)"
    }

    // MARK: - API Reference HTML (Scalar)

    private func apiReferenceHTML() -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>Tricount API</title>
        </head>
        <body>
            <script id="api-reference" data-url="./openapi.json"></script>
            <script>
                document.getElementById('api-reference').dataset.configuration = JSON.stringify({
                    theme: 'kepler',
                    layout: 'modern',
                    darkMode: true,
                    hiddenClients: true,
                    defaultHttpClient: { targetKey: 'shell', clientKey: 'curl' },
                    authentication: {
                        preferredSecurityScheme: 'bearerAuth',
                        http: { bearer: { token: '' } }
                    },
                    metaData: {
                        title: 'Tricount API',
                        description: 'Expense-splitting backend API'
                    }
                });
            </script>
            <script src="https://cdn.jsdelivr.net/npm/@scalar/api-reference"></script>
        </body>
        </html>
        """
    }

    // MARK: - Postman Collection v2.1

    private func renderPostmanCollection(
        name: String,
        description: String,
        routes: [RouteDocumentationEntry]
    ) -> [String: Any] {
        let groups = routeGroups(from: routes)

        let tokenScript: [String: Any] = [
            "listen": "test",
            "script": [
                "type": "text/javascript",
                "exec": [
                    "function setRuntimeVariable(key, value) {",
                    "    if (typeof value !== 'string' || value.length === 0) return;",
                    "    try { pm.collectionVariables.set(key, value); } catch (e) {}",
                    "    try { pm.environment.set(key, value); } catch (e) {}",
                    "}",
                    "",
                    "var body = null;",
                    "try { body = pm.response.json(); } catch (e) {}",
                    "",
                    "if (pm.response.code >= 200 && pm.response.code < 300) {",
                    "    if (body && body.accessToken) setRuntimeVariable('accessToken', body.accessToken);",
                    "    if (body && body.refreshToken) setRuntimeVariable('refreshToken', body.refreshToken);",
                    "    if (body && body.mfaChallenge && body.mfaChallenge.challengeToken) setRuntimeVariable('challengeToken', body.mfaChallenge.challengeToken);",
                    "",
                    "    var otpCode = pm.response.headers.get('X-Debug-OTP-Code');",
                    "    if (otpCode) setRuntimeVariable('otpCode', otpCode);",
                    "",
                    "    var emailOtpCode = pm.response.headers.get('X-Debug-OTP-Code-Email');",
                    "    if (emailOtpCode) setRuntimeVariable('emailOtpCode', emailOtpCode);",
                    "",
                    "    var phoneOtpCode = pm.response.headers.get('X-Debug-OTP-Code-Phone');",
                    "    if (phoneOtpCode) setRuntimeVariable('phoneOtpCode', phoneOtpCode);",
                    "",
                    "    if (!otpCode && emailOtpCode && !phoneOtpCode) setRuntimeVariable('otpCode', emailOtpCode);",
                    "    if (!otpCode && phoneOtpCode && !emailOtpCode) setRuntimeVariable('otpCode', phoneOtpCode);",
                    "    if (body && body.credentialId) setRuntimeVariable('credentialId', body.credentialId);",
                    "}"
                ]
            ] as [String: Any]
        ]

        let folders: [[String: Any]] = groups.map { group in
            let sections = routeSections(from: group.routes, within: group)
            let items: [[String: Any]]

            if sections.count == 1, let section = sections.first, !section.isExplicit {
                items = section.routes.map(postmanItem(for:))
            } else {
                items = sections.map { section in
                    [
                        "name": section.title,
                        "item": section.routes.map(postmanItem(for:))
                    ]
                }
            }

            return [
                "name": group.title,
                "item": items
            ]
        }

        return [
            "info": [
                "name": name,
                "description": description,
                "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"
            ] as [String: Any],
            "variable": [
                ["key": "baseUrl", "value": "http://localhost:8080", "type": "string"],
                ["key": "accessToken", "value": "", "type": "string"],
                ["key": "refreshToken", "value": "", "type": "string"],
                ["key": "challengeToken", "value": "", "type": "string"],
                ["key": "email", "value": "test@example.com", "type": "string"],
                ["key": "password", "value": "Test1234", "type": "string"],
                ["key": "displayName", "value": "Test User", "type": "string"],
                ["key": "otpCode", "value": "123456", "type": "string"],
                ["key": "emailOtpCode", "value": "", "type": "string"],
                ["key": "phoneOtpCode", "value": "", "type": "string"],
                ["key": "idToken", "value": "", "type": "string"],
                ["key": "phoneNumber", "value": "+1234567890", "type": "string"],
                ["key": "credentialId", "value": "", "type": "string"]
            ],
            "auth": [
                "type": "bearer",
                "bearer": [["key": "token", "value": "{{accessToken}}", "type": "string"]]
            ] as [String: Any],
            "event": [tokenScript],
            "item": folders
        ]
    }

    private func postmanItem(for route: RouteDocumentationEntry) -> [String: Any] {
        let pathComponents = route.path.split(separator: "/").map(String.init)
        let name = postmanRequestName(method: route.method, path: route.path)
        let needsAuth = route.auth == "bearer"

        var request: [String: Any] = [
            "method": route.method,
            "url": [
                "raw": "{{baseUrl}}\(route.path)",
                "host": ["{{baseUrl}}"],
                "path": pathComponents
            ] as [String: Any]
        ]

        if !needsAuth {
            request["auth"] = ["type": "noauth"]
        }

        if let body = route.requestBody {
            request["header"] = [["key": "Content-Type", "value": "application/json"]]
            let sampleBody = postmanSampleBody(for: body.schema)
            if let jsonData = try? JSONSerialization.data(withJSONObject: sampleBody, options: [.prettyPrinted, .sortedKeys]),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                request["body"] = [
                    "mode": "raw",
                    "raw": jsonString
                ] as [String: Any]
            }
        }

        var item: [String: Any] = [
            "name": name,
            "request": request
        ]

        let statusCode = route.successResponse.statusCode
        item["event"] = [[
            "listen": "test",
            "script": [
                "type": "text/javascript",
                "exec": ["pm.test('Status is \(statusCode)', () => pm.response.to.have.status(\(statusCode)));"]
            ] as [String: Any]
        ]]

        return item
    }

    private func postmanRequestName(method: String, path: String) -> String {
        let segments = path
            .split(separator: "/")
            .filter { $0 != "v1" && $0 != "auth" }

        if segments.isEmpty { return "\(method) /" }

        return segments
            .map { segment in
                segment.split(separator: "-")
                    .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                    .joined(separator: " ")
            }
            .joined(separator: " > ")
    }

    private func postmanSampleBody(for schema: DocumentationSchema) -> [String: Any] {
        switch schema {
        case .object(let properties, _, _):
            var body: [String: Any] = [:]
            for property in properties {
                body[property.name] = postmanSampleValue(for: property.name, schema: property.schema)
            }
            return body
        default:
            return [:]
        }
    }

    private func postmanSampleValue(for name: String, schema: DocumentationSchema) -> Any {
        switch name {
        case "email": return "{{email}}"
        case "password": return "{{password}}"
        case "displayName": return "{{displayName}}"
        case "refreshToken": return "{{refreshToken}}"
        case "challengeToken": return "{{challengeToken}}"
        case "idToken": return "{{idToken}}"
        case "code": return "{{otpCode}}"
        case "newPassword": return "NewPass1234"
        case "phoneNumber": return "{{phoneNumber}}"
        case "credentialId": return "{{credentialId}}"
        default: break
        }

        switch schema {
        case .string(let format, _):
            switch format {
            case "uuid": return "00000000-0000-0000-0000-000000000000"
            case "uri": return "https://example.com"
            case "date-time": return "2026-01-01T00:00:00Z"
            default: return ""
            }
        case .integer: return 0
        case .number: return 0.0
        case .boolean: return false
        case .array: return [] as [Any]
        case .object(let properties, _, _):
            var nested: [String: Any] = [:]
            for property in properties {
                nested[property.name] = postmanSampleValue(for: property.name, schema: property.schema)
            }
            return nested
        default: return ""
        }
    }

    // MARK: - Route Snapshot

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
            generatedAt: Self.dateFormatter.string(from: Date()),
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
            section: metadata.section,
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
            errors.append(RouteDocumentationError(
                statusCode: Int(HTTPStatus.badRequest.code),
                code: "BAD_REQUEST",
                reason: "Request body is invalid, malformed, or missing required fields.",
                schema: errorSchema
            ))
        }

        if metadata.auth == .bearer {
            errors.append(RouteDocumentationError(
                statusCode: Int(HTTPStatus.unauthorized.code),
                code: "UNAUTHORIZED",
                reason: "Missing, invalid, or expired bearer token.",
                schema: errorSchema
            ))
        }

        if let policy = route.rateLimitPolicy, !policy.isDisabled {
            errors.append(RouteDocumentationError(
                statusCode: Int(HTTPStatus.tooManyRequests.code),
                code: "RATE_LIMIT_EXCEEDED",
                reason: "Too many requests for the configured rate-limit window.",
                schema: errorSchema
            ))
        }

        return errors.sorted { $0.statusCode < $1.statusCode }
    }

    // MARK: - Grouping Helpers

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
            groups[key].map {
                RouteGroup(prefix: key, title: displayTitle(for: key), slug: slug(for: key), routes: $0)
            }
        }
    }

    private func routeSections(from routes: [RouteDocumentationEntry], within group: RouteGroup) -> [RouteSection] {
        var buckets: [String: [RouteDocumentationEntry]] = [:]
        var metadataByKey: [String: RouteDocumentationSection] = [:]
        var explicitByKey: [String: Bool] = [:]
        var order: [String] = []

        for route in routes {
            let section = route.section ?? fallbackSection(for: route, group: group)
            if buckets[section.slug] == nil {
                order.append(section.slug)
                metadataByKey[section.slug] = section
            }
            buckets[section.slug, default: []].append(route)
            explicitByKey[section.slug] = (explicitByKey[section.slug] ?? false) || (route.section != nil)
        }

        return order.compactMap { key in
            guard let section = metadataByKey[key],
                  let sectionRoutes = buckets[key] else { return nil }
            return RouteSection(
                slug: section.slug,
                title: section.title,
                routes: sectionRoutes,
                isExplicit: explicitByKey[key] ?? false
            )
        }
    }

    private func fallbackSection(for route: RouteDocumentationEntry, group: RouteGroup) -> RouteDocumentationSection {
        let key = subgroupKey(for: route, groupPrefix: group.prefix)
        return RouteDocumentationSection(slug: key, title: key == "general" ? "General" : humanizeSegment(key))
    }

    private func subgroupKey(for route: RouteDocumentationEntry, groupPrefix: String) -> String {
        let fullSegments = route.path.split(separator: "/").map(String.init)
        let groupSegments = groupPrefix.split(separator: "/").map(String.init)
        let remainingSegments = Array(fullSegments.dropFirst(groupSegments.count))

        if let paramIndex = remainingSegments.firstIndex(where: { $0.hasPrefix(":") }) {
            let afterParam = remainingSegments.dropFirst(paramIndex + 1)
            if let firstResource = afterParam.first(where: { !$0.hasPrefix(":") }) {
                return firstResource
            }
        }

        return "general"
    }

    private func makeSchemas(from routes: [RouteDocumentationEntry]) -> [String: DocumentationSchema] {
        routes
            .flatMap(\.schemas)
            .filter { isPublicDocumentationType($0.name) && !$0.schema.isUnknown }
            .reduce(into: [String: DocumentationSchema]()) { schemas, entry in
                schemas[entry.name] = schemas[entry.name] ?? entry.schema
            }
    }

    private func sectionCollectionArtifacts(for groups: [RouteGroup]) -> [CollectionArtifact] {
        groups.flatMap { group in
            let sections = routeSections(from: group.routes, within: group)
            if sections.count == 1, let section = sections.first, !section.isExplicit {
                return [CollectionArtifact(
                    title: group.title,
                    fileName: group.postmanFileName,
                    routeCount: group.routes.count,
                    routes: group.routes,
                    groupSlug: group.slug,
                    sectionTitle: nil
                )]
            }

            return sections.map { section in
                let cardTitle = section.slug == "general" ? group.title : section.title
                return CollectionArtifact(
                    title: "\(group.title) - \(cardTitle)",
                    fileName: section.postmanFileName(in: group),
                    routeCount: section.routes.count,
                    routes: section.routes,
                    groupSlug: group.slug,
                    sectionTitle: cardTitle
                )
            }
        }
    }

    private func cleanupLegacyArtifacts(in outputDirectory: URL, groups: [RouteGroup]) throws {
        let fileManager = FileManager.default
        let existingFiles = try fileManager.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let legacyFiles = Set(["routes.md"] + groups.map { "\($0.slug).md" })

        for fileURL in existingFiles {
            let fileName = fileURL.lastPathComponent
            if legacyFiles.contains(fileName) {
                try? fileManager.removeItem(at: fileURL)
            }
        }
    }

    // MARK: - Name Helpers

    private func displayTitle(for prefix: String) -> String {
        let segments = prefix.split(separator: "/").map(String.init)
        let meaningful = segments.first.map { $0.lowercased().hasPrefix("v") } == true
            ? Array(segments.dropFirst()) : segments
        guard !meaningful.isEmpty else { return "Root" }
        return meaningful.map(humanizeSegment).joined(separator: " / ")
    }

    private func slug(for prefix: String) -> String {
        let segments = prefix.split(separator: "/").map(String.init)
        let meaningful = segments.first.map { $0.lowercased().hasPrefix("v") } == true
            ? Array(segments.dropFirst()) : segments
        guard !meaningful.isEmpty else { return "root" }
        return meaningful.map { $0.lowercased() }.joined(separator: "-")
    }

    private func humanizeSegment(_ segment: String) -> String {
        segment
            .split(separator: "-")
            .map { component in
                switch component.lowercased() {
                case "mfa": return "MFA"
                case "api": return "API"
                case "id": return "ID"
                default: return component.prefix(1).uppercased() + component.dropFirst()
                }
            }
            .joined(separator: " ")
    }

    private static func pathString(for route: Route) -> String {
        let value = route.path.map { "\($0)" }.joined(separator: "/")
        return value.isEmpty ? "/" : "/\(value)"
    }
}

// MARK: - Internal Types

private struct RouteDocumentationSnapshot {
    let service: String
    let environment: String
    let generatedAt: String
    let routeCount: Int
    let schemas: [String: DocumentationSchema]
    let routes: [RouteDocumentationEntry]
}

private struct RouteDocumentationEntry {
    let method: String
    let path: String
    let summary: String?
    let auth: String
    let section: RouteDocumentationSection?
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
        case .empty: self.summary = "\(response.statusCode) no-content"
        case .raw: self.summary = "\(response.statusCode) \(response.typeName ?? "unknown")"
        }
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
}

private struct NamedSchema {
    let name: String
    let schema: DocumentationSchema
}

private struct CollectionArtifact {
    let title: String
    let fileName: String
    let routeCount: Int
    let routes: [RouteDocumentationEntry]
    let groupSlug: String
    let sectionTitle: String?
}

private struct RouteGroup {
    let prefix: String
    let title: String
    let slug: String
    let routes: [RouteDocumentationEntry]

    var postmanFileName: String {
        "Tricount-Backend.\(documentationFileNameSegment(slug)).postman_collection.json"
    }
}

private struct RouteSection {
    let slug: String
    let title: String
    let routes: [RouteDocumentationEntry]
    let isExplicit: Bool

    func postmanFileName(in group: RouteGroup) -> String {
        let groupSuffix = documentationFileNameSegment(group.slug)
        if slug == "general" {
            return "Tricount-Backend.\(groupSuffix).postman_collection.json"
        }
        let sectionSuffix = documentationFileNameSegment(slug)
        return "Tricount-Backend.\(groupSuffix)-\(sectionSuffix).postman_collection.json"
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
        var object: [String: Any] = ["mode": mode, "summary": summary]
        if let identifier { object["identifier"] = identifier }
        if let limit { object["limit"] = limit }
        if let windowSeconds { object["windowSeconds"] = windowSeconds }
        if let keyStrategy { object["keyStrategy"] = keyStrategy }
        return object
    }
}

private func documentationFileNameSegment(_ slug: String) -> String {
    slug
        .split(separator: "-")
        .map { component in
            switch component.lowercased() {
            case "mfa": return "MFA"
            case "api": return "API"
            case "id": return "ID"
            default: return component.prefix(1).uppercased() + component.dropFirst()
            }
        }
        .joined(separator: "-")
}

private extension RouteDocumentationMetadata {
    static func fallback(from route: Route) -> RouteDocumentationMetadata {
        let typeName = prettyDocumentationTypeName(route.responseType)
        let hasStructuredType = route.responseType != Response.self
        return RouteDocumentationMetadata(
            auth: .none,
            section: nil,
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

private extension RateLimitKeyStrategy {
    var documentationName: String {
        switch self {
        case .ip: return "ip"
        case .bodyEmail: return "bodyEmail"
        }
    }
}
