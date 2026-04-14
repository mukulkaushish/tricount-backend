import Logging
import NIOSSL
import Vapor

private let defaultJWTSecret = "change-me-in-production-use-env-var"

private struct RuntimeConfigurationKey: StorageKey {
    typealias Value = AppRuntimeConfiguration
}

enum AppRuntimeConfigurationError: Error, LocalizedError, Equatable {
    case invalidLogLevel(String)
    case invalidInteger(key: String, value: String)
    case invalidBoolean(key: String, value: String)
    case invalidDatabaseTLSMode(String)
    case insecureJWTSecretInProduction
    case insecureDatabaseTLSInProduction

    var errorDescription: String? {
        switch self {
        case .invalidLogLevel(let value):
            return "Invalid LOG_LEVEL '\(value)'. Use one of: trace, debug, info, notice, warning, error, critical."
        case .invalidInteger(let key, let value):
            return "Invalid integer value '\(value)' for \(key)."
        case .invalidBoolean(let key, let value):
            return "Invalid boolean value '\(value)' for \(key). Use true/false, yes/no, on/off, or 1/0."
        case .invalidDatabaseTLSMode(let value):
            return "Invalid MYSQL_TLS_MODE '\(value)'. Use one of: disabled, required, insecure."
        case .insecureJWTSecretInProduction:
            return "JWT_SECRET must be set to a non-default value in production."
        case .insecureDatabaseTLSInProduction:
            return "MYSQL_TLS_MODE=insecure is not allowed in production."
        }
    }
}

struct AppRuntimeConfiguration: Sendable {
    struct Observability: Sendable {
        let logLevel: Logger.Level
        let includeRequestBodiesInAccessLogs: Bool
    }

    struct Auth: Sendable {
        let jwtSecret: String
        let totpIssuer: String
    }

    struct OAuth: Sendable {
        let googleClientId: String?
        let appleApplicationIdentifier: String?
    }

    struct PasswordHashing: Sendable {
        let opsLimitOverride: Int?
        let memLimitOverride: Int?
    }

    struct RouteDocumentation: Sendable {
        let customOutputDirectory: String?
    }

    struct Startup: Sendable {
        let generateRouteDocumentationOnBoot: Bool
        let autoMigrateOnBoot: Bool
    }

    struct Passkeys: Sendable {
        let rpId: String
        let rpName: String
        let timeoutMilliseconds: Int
        let challengeLifetime: Double
        let allowedOrigins: Set<String>
    }

    struct Database: Sendable {
        enum TLSMode: String, Sendable {
            case disabled
            case required
            case insecure

            init(parsing rawValue: String?) throws {
                let normalized = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
                switch normalized {
                case "", "disabled":
                    self = .disabled
                case "required":
                    self = .required
                case "insecure":
                    self = .insecure
                default:
                    throw AppRuntimeConfigurationError.invalidDatabaseTLSMode(normalized)
                }
            }
        }

        let hostname: String
        let port: Int
        let username: String
        let password: String
        let database: String
        let tlsMode: TLSMode
        let maxConnectionsPerEventLoop: Int

        func tlsConfiguration() -> TLSConfiguration? {
            switch tlsMode {
            case .disabled:
                return nil
            case .required:
                return TLSConfiguration.makeClientConfiguration()
            case .insecure:
                var config = TLSConfiguration.makeClientConfiguration()
                config.certificateVerification = .none
                return config
            }
        }
    }

    let observability: Observability
    let auth: Auth
    let oauth: OAuth
    let passwordHashing: PasswordHashing
    let routeDocumentation: RouteDocumentation
    let startup: Startup
    let passkeys: Passkeys
    let database: Database

    static func load(
        environment: Environment,
        environmentValues: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> AppRuntimeConfiguration {
        let logLevel = try Logger.Level(parsing: environmentValues.string(for: "LOG_LEVEL") ?? "info")

        let jwtSecret = environmentValues.string(for: "JWT_SECRET") ?? defaultJWTSecret
        if environment == .production, jwtSecret == defaultJWTSecret {
            throw AppRuntimeConfigurationError.insecureJWTSecretInProduction
        }

        let passkeyRPName = environmentValues.string(for: "PASSKEY_RP_NAME") ?? "Tricount"
        let passkeyAllowedOrigins = Set(environmentValues.csv(for: "PASSKEY_ALLOWED_ORIGINS"))

        let databaseTLSMode = try Database.TLSMode(
            parsing: environmentValues.string(for: "MYSQL_TLS_MODE")
                ?? (environment == .production ? "required" : "disabled")
        )
        if environment == .production, databaseTLSMode == .insecure {
            throw AppRuntimeConfigurationError.insecureDatabaseTLSInProduction
        }

        return AppRuntimeConfiguration(
            observability: Observability(
                logLevel: logLevel,
                includeRequestBodiesInAccessLogs: try environmentValues.bool(
                    for: "ACCESS_LOG_INCLUDE_BODIES"
                ) ?? (environment == .development)
            ),
            auth: Auth(
                jwtSecret: jwtSecret,
                totpIssuer: environmentValues.string(for: "TOTP_ISSUER") ?? passkeyRPName
            ),
            oauth: OAuth(
                googleClientId: environmentValues.string(for: "GOOGLE_CLIENT_ID"),
                appleApplicationIdentifier: environmentValues.string(for: "APPLE_APPLICATION_IDENTIFIER")
                    ?? environmentValues.string(for: "APPLE_BUNDLE_ID")
            ),
            passwordHashing: PasswordHashing(
                opsLimitOverride: try environmentValues.int(for: "ARGON2_OPS_LIMIT"),
                memLimitOverride: try environmentValues.int(for: "ARGON2_MEM_LIMIT")
            ),
            routeDocumentation: RouteDocumentation(
                customOutputDirectory: environmentValues.string(for: "ROUTE_DOCS_OUTPUT_DIR")
            ),
            startup: Startup(
                generateRouteDocumentationOnBoot: try environmentValues.bool(
                    for: "APP_GENERATE_ROUTE_DOCS"
                ) ?? (environment != .production),
                autoMigrateOnBoot: try environmentValues.bool(
                    for: "APP_AUTO_MIGRATE"
                ) ?? (environment != .production)
            ),
            passkeys: Passkeys(
                rpId: environmentValues.string(for: "PASSKEY_RP_ID") ?? "localhost",
                rpName: passkeyRPName,
                timeoutMilliseconds: try environmentValues.int(for: "PASSKEY_TIMEOUT_MS") ?? 60_000,
                challengeLifetime: try environmentValues.double(for: "PASSKEY_CHALLENGE_TTL_SECONDS") ?? 600,
                allowedOrigins: passkeyAllowedOrigins
            ),
            database: Database(
                hostname: environmentValues.string(for: "MYSQL_HOST") ?? "127.0.0.1",
                port: try environmentValues.int(for: "MYSQL_PORT") ?? 3306,
                username: environmentValues.string(for: "MYSQL_USERNAME") ?? "tricount",
                password: environmentValues.string(for: "MYSQL_PASSWORD") ?? "tricount",
                database: environmentValues.string(for: "MYSQL_DATABASE") ?? "tricount",
                tlsMode: databaseTLSMode,
                maxConnectionsPerEventLoop: try environmentValues.int(for: "MYSQL_MAX_CONNECTIONS_PER_EVENT_LOOP") ?? 4
            )
        )
    }
}

extension Application {
    var runtimeConfigurationIfLoaded: AppRuntimeConfiguration? {
        storage[RuntimeConfigurationKey.self]
    }

    var runtimeConfiguration: AppRuntimeConfiguration {
        get {
            guard let configuration = storage[RuntimeConfigurationKey.self] else {
                fatalError("Runtime configuration accessed before loadRuntimeConfiguration() was called.")
            }
            return configuration
        }
        set {
            storage[RuntimeConfigurationKey.self] = newValue
        }
    }

    func loadRuntimeConfiguration() throws {
        runtimeConfiguration = try AppRuntimeConfiguration.load(
            environment: environment,
            environmentValues: ProcessInfo.processInfo.environment
        )
    }
}

private extension Logger.Level {
    init(parsing rawValue: String) throws {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "trace":
            self = .trace
        case "debug":
            self = .debug
        case "info":
            self = .info
        case "notice":
            self = .notice
        case "warning":
            self = .warning
        case "error":
            self = .error
        case "critical":
            self = .critical
        default:
            throw AppRuntimeConfigurationError.invalidLogLevel(rawValue)
        }
    }
}

private extension [String: String] {
    func string(for key: String) -> String? {
        guard let value = self[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    func csv(for key: String) -> [String] {
        guard let value = string(for: key) else {
            return []
        }

        return value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func int(for key: String) throws -> Int? {
        guard let value = string(for: key) else {
            return nil
        }
        guard let parsed = Int(value) else {
            throw AppRuntimeConfigurationError.invalidInteger(key: key, value: value)
        }
        return parsed
    }

    func bool(for key: String) throws -> Bool? {
        guard let value = string(for: key)?.lowercased() else {
            return nil
        }

        switch value {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            throw AppRuntimeConfigurationError.invalidBoolean(key: key, value: value)
        }
    }

    func double(for key: String) throws -> Double? {
        guard let value = string(for: key) else {
            return nil
        }
        guard let parsed = Double(value) else {
            throw AppRuntimeConfigurationError.invalidInteger(key: key, value: value)
        }
        return parsed
    }
}
