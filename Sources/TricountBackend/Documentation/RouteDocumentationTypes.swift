import Foundation
import Vapor

enum RouteDocumentationAuth: String, Sendable {
    case none
    case bearer
}

enum RouteDocumentationEnvelope: String, Sendable {
    case raw
    case empty
}

struct RouteDocumentationMetadata: Sendable {
    let auth: RouteDocumentationAuth
    let section: RouteDocumentationSection?
    let requestBody: RouteDocumentationRequestBody?
    let successResponse: RouteDocumentationResponse
}

struct RouteDocumentationSection: Sendable, Hashable {
    let slug: String
    let title: String
}

extension RouteDocumentationSection {
    static let authSession = RouteDocumentationSection(slug: "session", title: "Session")
    static let authAccount = RouteDocumentationSection(slug: "account", title: "Account")
    static let authMFALogin = RouteDocumentationSection(slug: "mfa-login", title: "MFA Login")
    static let authMFASettings = RouteDocumentationSection(slug: "mfa-settings", title: "MFA Settings")
    static let authPasskeyManagement = RouteDocumentationSection(slug: "passkey-management", title: "Passkey Management")
}

struct RouteDocumentationRequestBody: Sendable {
    let contentType: String
    let typeName: String
    let schema: DocumentationSchema

    static func json<Body: Content>(_ type: Body.Type = Body.self) -> RouteDocumentationRequestBody {
        RouteDocumentationRequestBody(
            contentType: "application/json",
            typeName: prettyDocumentationTypeName(type),
            schema: DocumentationSchemaFactory.make(for: type)
        )
    }
}

struct RouteDocumentationResponse: Sendable {
    let statusCode: Int
    let contentType: String?
    let typeName: String?
    let envelope: RouteDocumentationEnvelope
    let payloadSchema: DocumentationSchema?

    var schema: DocumentationSchema? {
        switch envelope {
        case .raw:
            payloadSchema
        case .empty:
            nil
        }
    }

    static func raw<Body: Content>(
        _ type: Body.Type = Body.self,
        status: HTTPStatus = .ok
    ) -> RouteDocumentationResponse {
        RouteDocumentationResponse(
            statusCode: Int(status.code),
            contentType: "application/json",
            typeName: prettyDocumentationTypeName(type),
            envelope: .raw,
            payloadSchema: DocumentationSchemaFactory.make(for: type)
        )
    }

    static func empty(status: HTTPStatus = .noContent) -> RouteDocumentationResponse {
        RouteDocumentationResponse(
            statusCode: Int(status.code),
            contentType: nil,
            typeName: nil,
            envelope: .empty,
            payloadSchema: nil
        )
    }
}

struct RouteDocumentationError: Sendable {
    let statusCode: Int
    let code: String
    let reason: String
    let schema: DocumentationSchema
}

indirect enum DocumentationSchema: Sendable {
    case string(format: String? = nil, nullable: Bool = false)
    case integer(nullable: Bool = false)
    case number(nullable: Bool = false)
    case boolean(nullable: Bool = false)
    case array(items: DocumentationSchema, nullable: Bool = false)
    case dictionary(values: DocumentationSchema, nullable: Bool = false)
    case object(properties: [DocumentationProperty], typeName: String? = nil, nullable: Bool = false)
    case unknown(typeName: String, nullable: Bool = false)

    func nullable() -> DocumentationSchema {
        switch self {
        case .string(let format, _):
            return .string(format: format, nullable: true)
        case .integer:
            return .integer(nullable: true)
        case .number:
            return .number(nullable: true)
        case .boolean:
            return .boolean(nullable: true)
        case .array(let items, _):
            return .array(items: items, nullable: true)
        case .dictionary(let values, _):
            return .dictionary(values: values, nullable: true)
        case .object(let properties, let typeName, _):
            return .object(properties: properties, typeName: typeName, nullable: true)
        case .unknown(let typeName, _):
            return .unknown(typeName: typeName, nullable: true)
        }
    }

    /// True when this schema carries no structural info — only a raw type name.
    var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }

    var markdownType: String {
        switch self {
        case .string(let format, let nullable):
            let base = format.map { "string(\($0))" } ?? "string"
            return nullable ? "\(base)?" : base
        case .integer(let nullable):
            return nullable ? "integer?" : "integer"
        case .number(let nullable):
            return nullable ? "number?" : "number"
        case .boolean(let nullable):
            return nullable ? "boolean?" : "boolean"
        case .array(let items, let nullable):
            let base = "array<\(items.markdownType)>"
            return nullable ? "\(base)?" : base
        case .dictionary(let values, let nullable):
            let base = "object<string, \(values.markdownType)>"
            return nullable ? "\(base)?" : base
        case .object(_, let typeName, let nullable):
            let base = typeName ?? "object"
            return nullable ? "\(base)?" : base
        case .unknown(let typeName, let nullable):
            return nullable ? "\(typeName)?" : typeName
        }
    }

    var jsonObject: Any {
        switch self {
        case .string(let format, let nullable):
            var object: [String: Any] = ["type": "string"]
            if let format {
                object["format"] = format
            }
            if nullable {
                object["nullable"] = true
            }
            return object
        case .integer(let nullable):
            return primitiveObject(type: "integer", nullable: nullable)
        case .number(let nullable):
            return primitiveObject(type: "number", nullable: nullable)
        case .boolean(let nullable):
            return primitiveObject(type: "boolean", nullable: nullable)
        case .array(let items, let nullable):
            var object: [String: Any] = [
                "type": "array",
                "items": items.jsonObject
            ]
            if nullable {
                object["nullable"] = true
            }
            return object
        case .dictionary(let values, let nullable):
            var object: [String: Any] = [
                "type": "object",
                "additionalProperties": values.jsonObject
            ]
            if nullable {
                object["nullable"] = true
            }
            return object
        case .object(let properties, _, let nullable):
            var object: [String: Any] = [
                "type": "object",
                "properties": Dictionary(uniqueKeysWithValues: properties.map { ($0.name, $0.schema.jsonObject) })
            ]

            let required = properties
                .filter(\.required)
                .map(\.name)
                .sorted()
            if !required.isEmpty {
                object["required"] = required
            }
            if nullable {
                object["nullable"] = true
            }
            return object
        case .unknown(let typeName, let nullable):
            var object: [String: Any] = [
                "type": "unknown",
                "swiftType": typeName
            ]
            if nullable {
                object["nullable"] = true
            }
            return object
        }
    }

    func flattenedFields(prefix: String = "", requiredByParent: Bool = true) -> [DocumentationFieldRow] {
        switch self {
        case .object(let properties, _, _):
            return properties.flatMap { property in
                let path = prefix.isEmpty ? property.name : "\(prefix).\(property.name)"
                var rows = [
                    DocumentationFieldRow(
                        path: path,
                        type: property.schema.markdownType,
                        required: requiredByParent && property.required
                    )
                ]
                rows.append(
                    contentsOf: property.schema.flattenedNestedFields(
                        prefix: path,
                        requiredByParent: requiredByParent && property.required
                    )
                )
                return rows
            }
        default:
            return prefix.isEmpty
                ? []
                : [DocumentationFieldRow(path: prefix, type: markdownType, required: requiredByParent)]
        }
    }

    private func flattenedNestedFields(prefix: String, requiredByParent: Bool) -> [DocumentationFieldRow] {
        switch self {
        case .object(let properties, _, _):
            return properties.flatMap { property in
                let path = "\(prefix).\(property.name)"
                var rows = [
                    DocumentationFieldRow(
                        path: path,
                        type: property.schema.markdownType,
                        required: requiredByParent && property.required
                    )
                ]
                rows.append(
                    contentsOf: property.schema.flattenedNestedFields(
                        prefix: path,
                        requiredByParent: requiredByParent && property.required
                    )
                )
                return rows
            }
        case .array(let items, _):
            let path = "\(prefix)[]"
            var rows = [
                DocumentationFieldRow(path: path, type: items.markdownType, required: requiredByParent)
            ]
            rows.append(contentsOf: items.flattenedNestedFields(prefix: path, requiredByParent: requiredByParent))
            return rows
        default:
            return []
        }
    }

    private func primitiveObject(type: String, nullable: Bool) -> [String: Any] {
        var object: [String: Any] = ["type": type]
        if nullable {
            object["nullable"] = true
        }
        return object
    }
}

struct DocumentationProperty: Sendable {
    let name: String
    let schema: DocumentationSchema
    let required: Bool
}

struct DocumentationFieldRow: Sendable {
    let path: String
    let type: String
    let required: Bool
}

enum DocumentationSchemaFactory {
    static func make<T: Decodable>(for type: T.Type) -> DocumentationSchema {
        DocumentationSchemaRegistry().schema(for: type)
    }
}

func prettyDocumentationTypeName(_ type: Any.Type) -> String {
    var name = String(reflecting: type)
    // Strip known module prefixes so names like "NIOHTTP1.HTTPResponseStatus"
    // or "TricountBackend.LoginRequest" become just "HTTPResponseStatus" / "LoginRequest".
    for prefix in ["TricountBackend.", "Swift.", "Vapor.", "NIOHTTP1.", "NIOCore.", "NIO.", "NIOSSL.", "AsyncHTTPClient."] {
        name = name.replacingOccurrences(of: prefix, with: "")
    }
    return name
}

/// Returns true if the type name looks like a public, user-facing DTO name
/// (no remaining dots means all module prefixes were stripped successfully).
func isPublicDocumentationType(_ name: String) -> Bool {
    !name.contains(".")
}

final class DocumentationSchemaRegistry {
    private var cache: [ObjectIdentifier: DocumentationSchema] = [:]
    private var inProgress: Set<ObjectIdentifier> = []

    func schema<T: Decodable>(for type: T.Type) -> DocumentationSchema {
        let identifier = ObjectIdentifier(type)
        if let cached = cache[identifier] {
            return cached
        }

        let schema: DocumentationSchema
        switch type {
        case is String.Type, is Substring.Type:
            schema = .string()
        case is UUID.Type:
            schema = .string(format: "uuid")
        case is URL.Type:
            schema = .string(format: "uri")
        case is Date.Type:
            schema = .string(format: "date-time")
        case is Int.Type, is Int8.Type, is Int16.Type, is Int32.Type, is Int64.Type,
             is UInt.Type, is UInt8.Type, is UInt16.Type, is UInt32.Type, is UInt64.Type:
            schema = .integer()
        case is Double.Type, is Float.Type, is Decimal.Type:
            schema = .number()
        case is Bool.Type:
            schema = .boolean()
        default:
            if let optionalType = type as? any AnyOptionalDocumentationType.Type {
                schema = optionalType.wrappedSchema(using: self).nullable()
            } else if let arrayType = type as? any AnyArrayDocumentationType.Type {
                schema = .array(items: arrayType.elementSchema(using: self))
            } else if let dictionaryType = type as? any AnyStringDictionaryDocumentationType.Type {
                schema = .dictionary(values: dictionaryType.valueSchema(using: self))
            } else if inProgress.contains(identifier) {
                schema = .unknown(typeName: prettyDocumentationTypeName(type))
            } else {
                inProgress.insert(identifier)
                defer { inProgress.remove(identifier) }

                do {
                    let decoder = DocumentationSchemaDecoder(registry: self)
                    let instance = try T(from: decoder)
                    let optionalFieldNames = Set<String>(
                        Mirror(reflecting: instance).children.compactMap { child in
                            guard let label = child.label else {
                                return nil
                            }

                            let childType = Swift.type(of: child.value)
                            return childType is any AnyOptionalDocumentationType.Type ? label : nil
                        }
                    )
                    let properties = decoder.properties.map { property in
                        guard optionalFieldNames.contains(property.name) else {
                            return property
                        }

                        return DocumentationProperty(
                            name: property.name,
                            schema: property.schema.nullable(),
                            required: false
                        )
                    }
                    schema = .object(properties: properties.sorted { $0.name < $1.name }, typeName: prettyDocumentationTypeName(T.self))
                } catch {
                    schema = .unknown(typeName: prettyDocumentationTypeName(type))
                }
            }
        }

        cache[identifier] = schema
        return schema
    }

    func placeholder<T: Decodable>(for type: T.Type) throws -> T {
        switch type {
        case is String.Type:
            return "" as! T
        case is Substring.Type:
            return ""[...] as! T
        case is UUID.Type:
            return UUID() as! T
        case is URL.Type:
            return URL(string: "https://example.com")! as! T
        case is Date.Type:
            return Date(timeIntervalSince1970: 0) as! T
        case is Int.Type:
            return 0 as! T
        case is Int8.Type:
            return Int8.zero as! T
        case is Int16.Type:
            return Int16.zero as! T
        case is Int32.Type:
            return Int32.zero as! T
        case is Int64.Type:
            return Int64.zero as! T
        case is UInt.Type:
            return UInt.zero as! T
        case is UInt8.Type:
            return UInt8.zero as! T
        case is UInt16.Type:
            return UInt16.zero as! T
        case is UInt32.Type:
            return UInt32.zero as! T
        case is UInt64.Type:
            return UInt64.zero as! T
        case is Double.Type:
            return Double.zero as! T
        case is Float.Type:
            return Float.zero as! T
        case is Decimal.Type:
            return Decimal.zero as! T
        case is Bool.Type:
            return false as! T
        default:
            if let optionalType = type as? any AnyOptionalDocumentationType.Type {
                return optionalType.placeholderValue() as! T
            }
            if let arrayType = type as? any AnyArrayDocumentationType.Type {
                return arrayType.placeholderArrayValue() as! T
            }
            if let dictionaryType = type as? any AnyStringDictionaryDocumentationType.Type {
                return dictionaryType.placeholderDictionaryValue() as! T
            }
            return try T(from: DocumentationSchemaDecoder(registry: self))
        }
    }
}

final class DocumentationSchemaDecoder: Decoder {
    let registry: DocumentationSchemaRegistry
    var properties: [DocumentationProperty] = []

    init(registry: DocumentationSchemaRegistry) {
        self.registry = registry
    }

    var codingPath: [any CodingKey] { [] }
    var userInfo: [CodingUserInfoKey : Any] { [:] }

    func container<Key>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> where Key: CodingKey {
        let container = DocumentationKeyedDecodingContainer<Key>(decoder: self, registry: registry)
        return KeyedDecodingContainer(container)
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        DocumentationUnkeyedDecodingContainer(registry: registry)
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        DocumentationSingleValueDecodingContainer(registry: registry)
    }
}

struct DocumentationKeyedDecodingContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let decoder: DocumentationSchemaDecoder
    let registry: DocumentationSchemaRegistry

    var codingPath: [any CodingKey] { [] }
    var allKeys: [Key] { [] }

    func contains(_ key: Key) -> Bool { true }
    func decodeNil(forKey key: Key) throws -> Bool { false }

    func decode<T>(_ type: T.Type, forKey key: Key) throws -> T where T: Decodable {
        let isOptional = type is any AnyOptionalDocumentationType.Type
        decoder.properties.append(
            DocumentationProperty(
                name: key.stringValue,
                schema: registry.schema(for: type),
                required: !isOptional
            )
        )
        return try registry.placeholder(for: type)
    }

    func decodeIfPresent<T>(_ type: T.Type, forKey key: Key) throws -> T? where T: Decodable {
        decoder.properties.append(
            DocumentationProperty(name: key.stringValue, schema: registry.schema(for: type).nullable(), required: false)
        )
        return nil
    }

    func nestedContainer<NestedKey>(
        keyedBy type: NestedKey.Type,
        forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> where NestedKey: CodingKey {
        let nested = DocumentationSchemaDecoder(registry: registry)
        let container = DocumentationKeyedDecodingContainer<NestedKey>(decoder: nested, registry: registry)
        decoder.properties.append(
            DocumentationProperty(
                name: key.stringValue,
                schema: .object(properties: nested.properties, typeName: nil),
                required: true
            )
        )
        return KeyedDecodingContainer(container)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        decoder.properties.append(
            DocumentationProperty(
                name: key.stringValue,
                schema: .array(items: .unknown(typeName: "Any")),
                required: true
            )
        )
        return DocumentationUnkeyedDecodingContainer(registry: registry)
    }

    func superDecoder() throws -> any Decoder {
        DocumentationSchemaDecoder(registry: registry)
    }

    func superDecoder(forKey key: Key) throws -> any Decoder {
        DocumentationSchemaDecoder(registry: registry)
    }
}

struct DocumentationUnkeyedDecodingContainer: UnkeyedDecodingContainer {
    let registry: DocumentationSchemaRegistry

    var codingPath: [any CodingKey] { [] }
    var count: Int? { 0 }
    var isAtEnd: Bool { true }
    var currentIndex: Int { 0 }

    mutating func decodeNil() throws -> Bool { true }

    mutating func decode<T>(_ type: T.Type) throws -> T where T: Decodable {
        try registry.placeholder(for: type)
    }

    mutating func decodeIfPresent<T>(_ type: T.Type) throws -> T? where T: Decodable {
        nil
    }

    mutating func nestedContainer<NestedKey>(
        keyedBy type: NestedKey.Type
    ) throws -> KeyedDecodingContainer<NestedKey> where NestedKey: CodingKey {
        let nested = DocumentationSchemaDecoder(registry: registry)
        let container = DocumentationKeyedDecodingContainer<NestedKey>(decoder: nested, registry: registry)
        return KeyedDecodingContainer(container)
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        DocumentationUnkeyedDecodingContainer(registry: registry)
    }

    mutating func superDecoder() throws -> any Decoder {
        DocumentationSchemaDecoder(registry: registry)
    }
}

struct DocumentationSingleValueDecodingContainer: SingleValueDecodingContainer {
    let registry: DocumentationSchemaRegistry

    var codingPath: [any CodingKey] { [] }

    func decodeNil() -> Bool { false }

    func decode(_ type: String.Type) throws -> String { "" }
    func decode(_ type: Bool.Type) throws -> Bool { false }
    func decode(_ type: Double.Type) throws -> Double { .zero }
    func decode(_ type: Float.Type) throws -> Float { .zero }
    func decode(_ type: Int.Type) throws -> Int { .zero }
    func decode(_ type: Int8.Type) throws -> Int8 { .zero }
    func decode(_ type: Int16.Type) throws -> Int16 { .zero }
    func decode(_ type: Int32.Type) throws -> Int32 { .zero }
    func decode(_ type: Int64.Type) throws -> Int64 { .zero }
    func decode(_ type: UInt.Type) throws -> UInt { .zero }
    func decode(_ type: UInt8.Type) throws -> UInt8 { .zero }
    func decode(_ type: UInt16.Type) throws -> UInt16 { .zero }
    func decode(_ type: UInt32.Type) throws -> UInt32 { .zero }
    func decode(_ type: UInt64.Type) throws -> UInt64 { .zero }

    func decode<T>(_ type: T.Type) throws -> T where T: Decodable {
        try registry.placeholder(for: type)
    }
}

protocol AnyOptionalDocumentationType {
    static func wrappedSchema(using registry: DocumentationSchemaRegistry) -> DocumentationSchema
    static func placeholderValue() -> Any
}

extension Optional: AnyOptionalDocumentationType where Wrapped: Decodable {
    static func wrappedSchema(using registry: DocumentationSchemaRegistry) -> DocumentationSchema {
        registry.schema(for: Wrapped.self)
    }

    static func placeholderValue() -> Any {
        Self.none as Any
    }
}

protocol AnyArrayDocumentationType {
    static func elementSchema(using registry: DocumentationSchemaRegistry) -> DocumentationSchema
    static func placeholderArrayValue() -> Any
}

extension Array: AnyArrayDocumentationType where Element: Decodable {
    static func elementSchema(using registry: DocumentationSchemaRegistry) -> DocumentationSchema {
        registry.schema(for: Element.self)
    }

    static func placeholderArrayValue() -> Any {
        Self() as Any
    }
}

protocol AnyStringDictionaryDocumentationType {
    static func valueSchema(using registry: DocumentationSchemaRegistry) -> DocumentationSchema
    static func placeholderDictionaryValue() -> Any
}

extension Dictionary: AnyStringDictionaryDocumentationType where Key == String, Value: Decodable {
    static func valueSchema(using registry: DocumentationSchemaRegistry) -> DocumentationSchema {
        registry.schema(for: Value.self)
    }

    static func placeholderDictionaryValue() -> Any {
        Self() as Any
    }
}
