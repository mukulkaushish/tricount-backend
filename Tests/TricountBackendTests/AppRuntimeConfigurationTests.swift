@testable import TricountBackend
import Testing
import Vapor

@Suite("Runtime Configuration")
struct AppRuntimeConfigurationTests {
    @Test("Production rejects the default JWT secret")
    func productionRejectsDefaultJWTSecret() {
        do {
            _ = try AppRuntimeConfiguration.load(
                environment: .production,
                environmentValues: [:]
            )
            Issue.record("Expected production config loading to fail for the default JWT secret.")
        } catch let error as AppRuntimeConfigurationError {
            #expect(error == .insecureJWTSecretInProduction)
        } catch {
            Issue.record("Expected AppRuntimeConfigurationError, got \(error).")
        }
    }

    @Test("Runtime configuration centralizes environment-driven settings")
    func runtimeConfigurationParsesStructuredSettings() throws {
        let configuration = try AppRuntimeConfiguration.load(
            environment: .development,
            environmentValues: [
                "JWT_SECRET": "0123456789abcdef0123456789abcdef",
                "LOG_LEVEL": "debug",
                "ACCESS_LOG_INCLUDE_BODIES": "false",
                "APP_GENERATE_ROUTE_DOCS": "false",
                "APP_AUTO_MIGRATE": "false",
                "MYSQL_TLS_MODE": "insecure",
                "MYSQL_MAX_CONNECTIONS_PER_EVENT_LOOP": "8",
                "GOOGLE_CLIENT_ID": "google-client-id",
                "APPLE_APPLICATION_IDENTIFIER": "com.example.tricount",
                "PASSKEY_RP_ID": "api.example.com",
                "PASSKEY_RP_NAME": "Tricount API",
                "PASSKEY_ALLOWED_ORIGINS": "https://app.example.com, https://admin.example.com",
                "PASSKEY_TIMEOUT_MS": "90000",
                "PASSKEY_CHALLENGE_TTL_SECONDS": "300",
                "ARGON2_OPS_LIMIT": "4",
                "ARGON2_MEM_LIMIT": "65536",
                "ROUTE_DOCS_OUTPUT_DIR": "GeneratedDocs"
            ]
        )

        #expect(configuration.observability.logLevel == .debug)
        #expect(configuration.observability.includeRequestBodiesInAccessLogs == false)
        #expect(configuration.database.tlsMode == .insecure)
        #expect(configuration.database.maxConnectionsPerEventLoop == 8)
        #expect(configuration.oauth.googleClientId == "google-client-id")
        #expect(configuration.oauth.appleApplicationIdentifier == "com.example.tricount")
        #expect(configuration.passkeys.rpId == "api.example.com")
        #expect(configuration.passkeys.rpName == "Tricount API")
        #expect(configuration.passkeys.timeoutMilliseconds == 90_000)
        #expect(configuration.passkeys.challengeLifetime == 300)
        #expect(configuration.passkeys.allowedOrigins == Set([
            "https://app.example.com",
            "https://admin.example.com",
        ]))
        #expect(configuration.auth.totpIssuer == "Tricount API")
        #expect(configuration.passwordHashing.opsLimitOverride == 4)
        #expect(configuration.passwordHashing.memLimitOverride == 65_536)
        #expect(configuration.routeDocumentation.customOutputDirectory == "GeneratedDocs")
        #expect(configuration.startup.generateRouteDocumentationOnBoot == false)
        #expect(configuration.startup.autoMigrateOnBoot == false)
    }

    @Test("Production defaults disable expensive boot-time helpers")
    func productionDefaultsFavorLeanStartup() throws {
        let configuration = try AppRuntimeConfiguration.load(
            environment: .production,
            environmentValues: [
                "JWT_SECRET": "0123456789abcdef0123456789abcdef"
            ]
        )

        #expect(configuration.observability.includeRequestBodiesInAccessLogs == false)
        #expect(configuration.startup.generateRouteDocumentationOnBoot == false)
        #expect(configuration.startup.autoMigrateOnBoot == false)
    }
}
