@testable import TricountBackend
import Crypto
import Foundation
import VaporTesting
import Testing

@Suite("App Tests with DB", .serialized)
struct TricountBackendTests {
    private enum AuthEmailCodePurpose {
        case verification
        case passwordReset
        case mfaLogin
        case mfaEnable
    }

    private struct MockGoogleTokenVerifier: GoogleTokenVerifying {
        let profiles: [String: GoogleUserProfile]

        func verifyToken(_ idToken: String) async throws -> GoogleUserProfile {
            guard let profile = profiles[idToken] else {
                throw AuthError.googleTokenInvalid
            }

            return profile
        }
    }

    private struct MockAppleTokenVerifier: AppleTokenVerifying {
        let profiles: [String: AppleUserProfile]

        func verifyToken(_ idToken: String) async throws -> AppleUserProfile {
            guard let profile = profiles[idToken] else {
                throw AuthError.appleTokenInvalid
            }

            return profile
        }
    }

    private actor AuthEmailDeliveryBox {
        private var codes: [AuthEmailCodePurpose: String] = [:]

        func record(_ code: String, for purpose: AuthEmailCodePurpose) {
            self.codes[purpose] = code
        }

        func currentCode(for purpose: AuthEmailCodePurpose) -> String? {
            codes[purpose]
        }
    }

    private actor AuthSMSDeliveryBox {
        private var phoneVerificationCode: String?

        func recordPhoneVerificationCode(_ code: String) {
            self.phoneVerificationCode = code
        }

        func currentPhoneVerificationCode() -> String? {
            phoneVerificationCode
        }
    }

    private struct MockAuthEmailDispatcher: AuthEmailDispatching {
        let box: AuthEmailDeliveryBox

        func sendVerificationOTP(to email: String, code: String, displayName: String) async throws {
            await box.record(code, for: .verification)
        }

        func sendPasswordResetOTP(to email: String, code: String, displayName: String) async throws {
            await box.record(code, for: .passwordReset)
        }

        func sendMFALoginOTP(to email: String, code: String, displayName: String) async throws {
            await box.record(code, for: .mfaLogin)
        }

        func sendMFAEnableOTP(to email: String, code: String, displayName: String) async throws {
            await box.record(code, for: .mfaEnable)
        }
    }

    private struct MockAuthSMSDispatcher: AuthSMSDispatching {
        let box: AuthSMSDeliveryBox

        func sendPhoneVerificationOTP(to phoneNumber: String, code: String) async throws {
            await box.recordPhoneVerificationCode(code)
        }
    }

    private struct TestPasskeyCredential {
        let privateKey: P256.Signing.PrivateKey
        let credentialId: Data
        let aaguid: Data

        init() {
            self.privateKey = P256.Signing.PrivateKey()
            self.credentialId = UUID().rawBytes + UUID().rawBytes
            self.aaguid = UUID().rawBytes
        }

        var credentialIdBase64URL: String {
            Base64URL.encode(credentialId)
        }

        private static func bigEndianBytes<T: FixedWidthInteger>(_ value: T) -> Data {
            var bigEndian = value.bigEndian
            return withUnsafeBytes(of: &bigEndian) { Data($0) }
        }

        func makeRegistrationRequest(
            challenge: String,
            rpId: String,
            origin: String
        ) throws -> PasskeyRegistrationVerificationRequest {
            let x963 = privateKey.publicKey.x963Representation
            let x = Data(x963[1..<33])
            let y = Data(x963[33..<65])

            let coseKey = try TestPasskeyCBOR.map([
                .int(1): .unsigned(2),
                .int(3): .negative(-7),
                .int(-1): .unsigned(1),
                .int(-2): .byteString(x),
                .int(-3): .byteString(y),
            ]).encoded()

            var authData = Data(SHA256.hash(data: Data(rpId.utf8)))
            authData.append(0x45)
            authData.append(Self.bigEndianBytes(UInt32.zero))
            authData.append(aaguid)
            authData.append(Self.bigEndianBytes(UInt16(credentialId.count)))
            authData.append(credentialId)
            authData.append(coseKey)

            let attestationObject = try TestPasskeyCBOR.map([
                .string("fmt"): .textString("none"),
                .string("attStmt"): .map([:]),
                .string("authData"): .byteString(authData),
            ]).encoded()

            let clientDataJSON = try JSONEncoder().encode(
                TestCollectedClientData(type: "webauthn.create", challenge: challenge, origin: origin)
            )

            return PasskeyRegistrationVerificationRequest(
                id: credentialIdBase64URL,
                rawId: credentialIdBase64URL,
                type: "public-key",
                response: PasskeyRegistrationCredentialResponseDTO(
                    clientDataJSON: Base64URL.encode(clientDataJSON),
                    attestationObject: Base64URL.encode(attestationObject),
                    transports: ["internal"]
                )
            )
        }

        func makeAuthenticationRequest(
            challenge: String,
            rpId: String,
            origin: String,
            userHandle: String,
            signCount: UInt32 = 1
        ) throws -> PasskeyAuthenticationVerificationRequest {
            let clientDataJSON = try JSONEncoder().encode(
                TestCollectedClientData(type: "webauthn.get", challenge: challenge, origin: origin)
            )

            var authenticatorData = Data(SHA256.hash(data: Data(rpId.utf8)))
            authenticatorData.append(0x05)
            authenticatorData.append(Self.bigEndianBytes(signCount))

            let signedBytes = authenticatorData + Data(SHA256.hash(data: clientDataJSON))
            let signature = try privateKey.signature(for: signedBytes).derRepresentation

            return PasskeyAuthenticationVerificationRequest(
                id: credentialIdBase64URL,
                rawId: credentialIdBase64URL,
                type: "public-key",
                response: PasskeyAuthenticationCredentialResponseDTO(
                    clientDataJSON: Base64URL.encode(clientDataJSON),
                    authenticatorData: Base64URL.encode(authenticatorData),
                    signature: Base64URL.encode(signature),
                    userHandle: userHandle
                )
            )
        }
    }

    private struct TestCollectedClientData: Encodable {
        let type: String
        let challenge: String
        let origin: String
    }

    private enum TestPasskeyCBOR {
        case unsigned(UInt64)
        case negative(Int64)
        case byteString(Data)
        case textString(String)
        case map([TestPasskeyCBORKey: TestPasskeyCBOR])

        func encoded() throws -> Data {
            switch self {
            case .unsigned(let value):
                return encodeInteger(majorType: 0, value: UInt64(value))
            case .negative(let value):
                return encodeInteger(majorType: 1, value: UInt64((-1) - value))
            case .byteString(let data):
                return encodeLength(majorType: 2, length: UInt64(data.count)) + data
            case .textString(let string):
                let data = Data(string.utf8)
                return encodeLength(majorType: 3, length: UInt64(data.count)) + data
            case .map(let values):
                var encoded = encodeLength(majorType: 5, length: UInt64(values.count))
                for key in values.keys.sorted(by: { $0.sortKey < $1.sortKey }) {
                    guard let value = values[key] else { continue }
                    encoded.append(try key.encoded())
                    encoded.append(try value.encoded())
                }
                return encoded
            }
        }

        private func encodeInteger(majorType: UInt8, value: UInt64) -> Data {
            encodeLength(majorType: majorType, length: value)
        }

        private func encodeLength(majorType: UInt8, length: UInt64) -> Data {
            let prefix = majorType << 5
            switch length {
            case 0...23:
                return Data([prefix | UInt8(length)])
            case 24...0xff:
                return Data([prefix | 24, UInt8(length)])
            case 0x100...0xffff:
                return Data([prefix | 25]) + Self.bigEndianBytes(UInt16(length))
            case 0x1_0000...0xffff_ffff:
                return Data([prefix | 26]) + Self.bigEndianBytes(UInt32(length))
            default:
                return Data([prefix | 27]) + Self.bigEndianBytes(length)
            }
        }

        private static func bigEndianBytes<T: FixedWidthInteger>(_ value: T) -> Data {
            var bigEndian = value.bigEndian
            return withUnsafeBytes(of: &bigEndian) { Data($0) }
        }
    }

    private enum TestPasskeyCBORKey: Hashable {
        case int(Int64)
        case string(String)

        var sortKey: String {
            switch self {
            case .int(let value):
                return "0:\(value)"
            case .string(let value):
                return "1:\(value)"
            }
        }

        func encoded() throws -> Data {
            switch self {
            case .int(let value):
                if value >= 0 {
                    return try TestPasskeyCBOR.unsigned(UInt64(value)).encoded()
                }
                return try TestPasskeyCBOR.negative(value).encoded()
            case .string(let value):
                return try TestPasskeyCBOR.textString(value).encoded()
            }
        }
    }

    private func withApp(_ test: (Application) async throws -> ()) async throws {
        await RateLimitStore.shared.reset()
        let app = try await Application.make(.testing)
        try? FileManager.default.removeItem(at: app.routeDocumentationOutputDirectory)
        do {
            try await configure(app)
            try await test(app)
            try await app.autoRevert()
        } catch {
            try? await app.autoRevert()
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
        await RateLimitStore.shared.reset()
    }

    private func route(
        _ app: Application,
        method: HTTPMethod,
        suffix: String
    ) -> Route? {
        app.routes.all.first { route in
            route.method == method && route.description.hasSuffix(suffix)
        }
    }

    @Test("Health check returns service metadata")
    func healthCheck() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "", afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.decodeBody([String: String].self)
                #expect(payload["status"] == "ok")
                #expect(payload["service"] == "tricount-backend")
                #expect(res.headers.first(name: "X-RateLimit-Limit") == nil)
                #expect(!(res.headers.first(name: "X-Request-ID") ?? "").isEmpty)
                #expect((res.headers.first(name: "Server-Timing") ?? "").contains("app;dur="))
            })
        }
    }

    @Test("Route docs are generated automatically at startup")
    func routeDocsAreGeneratedAtStartup() async throws {
        try await withApp { app in
            let outputDirectory = app.routeDocumentationOutputDirectory
            let jsonURL = outputDirectory.appendingPathComponent("routes.json")
            let markdownURL = outputDirectory.appendingPathComponent("routes.md")

            #expect(FileManager.default.fileExists(atPath: jsonURL.path))
            #expect(FileManager.default.fileExists(atPath: markdownURL.path))

            let jsonData = try Data(contentsOf: jsonURL)
            let jsonObject = try JSONSerialization.jsonObject(with: jsonData)
            let root = try #require(jsonObject as? [String: Any])
            let routeCount = try #require(root["routeCount"] as? Int)
            let schemaCount = try #require(root["schemaCount"] as? Int)
            let schemas = try #require(root["schemas"] as? [String: Any])
            let routes = try #require(root["routes"] as? [[String: Any]])

            #expect(routeCount >= 1)
            #expect(schemaCount >= 1)
            #expect(routes.contains { ($0["path"] as? String) == "/v1/auth/login" && ($0["method"] as? String) == "POST" })
            #expect(routes.contains { ($0["path"] as? String) == "/v1/auth/reset-password" && ($0["method"] as? String) == "POST" })
            #expect(routes.contains { ($0["path"] as? String) == "/v1/auth/mfa/email/verify" && ($0["method"] as? String) == "POST" })
            #expect(routes.contains { ($0["path"] as? String) == "/v1/auth/mfa/email/enable" && ($0["method"] as? String) == "POST" })
            #expect(routes.contains { ($0["path"] as? String) == "/v1/auth/mfa/authenticator-app/setup" && ($0["method"] as? String) == "POST" })
            #expect(routes.contains { ($0["path"] as? String) == "/v1/auth/mfa/authenticator-app/verify" && ($0["method"] as? String) == "POST" })
            #expect(routes.contains { ($0["path"] as? String) == "/v1/auth/phone/request-verification" && ($0["method"] as? String) == "POST" })
            #expect(routes.contains { ($0["path"] as? String) == "/v1/auth/passkeys" && ($0["method"] as? String) == "GET" })
            #expect(routes.contains { ($0["path"] as? String) == "/v1/auth/passkeys/remove" && ($0["method"] as? String) == "POST" })
            #expect(routes.contains { ($0["path"] as? String) == "/v1/auth/passkeys/reset" && ($0["method"] as? String) == "POST" })
            #expect(routes.contains { ($0["path"] as? String) == "/v1/todos" && ($0["method"] as? String) == "GET" })
            #expect(routes.contains { ($0["path"] as? String) == "/v1/auth/passkeys/register/options" && ($0["method"] as? String) == "POST" })
            #expect(routes.contains { ($0["path"] as? String) == "/v1/auth/passkeys/authenticate/verify" && ($0["method"] as? String) == "POST" })

            let loginRequestSchema = try #require(schemas["LoginRequest"] as? [String: Any])
            let loginRequiredFields = try #require(loginRequestSchema["required"] as? [String])
            #expect(Set(loginRequiredFields) == ["email", "password"])

            let userSchema = try #require(schemas["UserDTO"] as? [String: Any])
            let userProperties = try #require(userSchema["properties"] as? [String: Any])
            let avatarURL = try #require(userProperties["avatarUrl"] as? [String: Any])
            #expect((avatarURL["nullable"] as? Bool) == true)
            let mfaMethod = try #require(userProperties["mfaMethod"] as? [String: Any])
            #expect((mfaMethod["nullable"] as? Bool) == true)
            let phoneNumber = try #require(userProperties["phoneNumber"] as? [String: Any])
            #expect((phoneNumber["nullable"] as? Bool) == true)
            let phoneVerifiedAt = try #require(userProperties["phoneVerifiedAt"] as? [String: Any])
            #expect((phoneVerifiedAt["nullable"] as? Bool) == true)

            let authenticationResultSchema = try #require(schemas["AuthenticationResultResponse"] as? [String: Any])
            let authenticationResultProperties = try #require(authenticationResultSchema["properties"] as? [String: Any])
            let mfaChallengeSchema = try #require(authenticationResultProperties["mfaChallenge"] as? [String: Any])
            #expect((mfaChallengeSchema["nullable"] as? Bool) == true)
            let mfaChallengeProperties = try #require(mfaChallengeSchema["properties"] as? [String: Any])
            let challengeToken = try #require(mfaChallengeProperties["challengeToken"] as? [String: Any])
            #expect((challengeToken["nullable"] as? Bool) == true)
            let expiresIn = try #require(mfaChallengeProperties["expiresIn"] as? [String: Any])
            #expect((expiresIn["nullable"] as? Bool) == true)

            let loginRoute = try #require(routes.first {
                ($0["path"] as? String) == "/v1/auth/login" && ($0["method"] as? String) == "POST"
            })
            let loginRequestBody = try #require(loginRoute["requestBody"] as? [String: Any])
            #expect(loginRequestBody["typeName"] as? String == "LoginRequest")

            let loginSuccess = try #require(loginRoute["successResponse"] as? [String: Any])
            #expect(loginSuccess["envelope"] as? String == "data")
            #expect(loginSuccess["typeName"] as? String == "AuthenticationResultResponse")

            let passkeyVerifyRoute = try #require(routes.first {
                ($0["path"] as? String) == "/v1/auth/passkeys/authenticate/verify" && ($0["method"] as? String) == "POST"
            })
            let passkeyVerifyRequestBody = try #require(passkeyVerifyRoute["requestBody"] as? [String: Any])
            #expect(passkeyVerifyRequestBody["typeName"] as? String == "PasskeyAuthenticationVerificationRequest")

            let todoIndexRoute = try #require(routes.first {
                ($0["path"] as? String) == "/v1/todos" && ($0["method"] as? String) == "GET"
            })
            let todoSuccess = try #require(todoIndexRoute["successResponse"] as? [String: Any])
            #expect(todoSuccess["envelope"] as? String == "raw")
            #expect(todoSuccess["typeName"] as? String == "Array<TodoResponse>")

            let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
            #expect(markdown.contains("| POST | /v1/auth/login | none | 200 data<AuthenticationResultResponse> |"))
            #expect(markdown.contains("## POST /v1/auth/login"))
            #expect(markdown.contains("## POST /v1/auth/reset-password"))
            #expect(markdown.contains("## POST /v1/auth/mfa/email/verify"))
            #expect(markdown.contains("## POST /v1/auth/mfa/authenticator-app/setup"))
            #expect(markdown.contains("## POST /v1/auth/mfa/authenticator-app/verify"))
            #expect(markdown.contains("## POST /v1/auth/phone/request-verification"))
            #expect(markdown.contains("## GET /v1/auth/passkeys"))
            #expect(markdown.contains("## POST /v1/auth/passkeys/remove"))
            #expect(markdown.contains("## POST /v1/auth/passkeys/reset"))
            #expect(markdown.contains("| email | string | yes |"))
            #expect(markdown.contains("| data.user.avatarUrl | string? | no |"))
            #expect(markdown.contains("| data.user.phoneNumber | string? | no |"))
            #expect(markdown.contains("| data.user.phoneVerifiedAt | string? | no |"))
            #expect(markdown.contains("## GET /v1/todos"))
            #expect(markdown.contains("## POST /v1/auth/passkeys/register/options"))
            #expect(markdown.contains("## POST /v1/auth/passkeys/authenticate/verify"))
            #expect(markdown.contains("| item.id | string(uuid) | yes |"))
            #expect(markdown.contains("| item.title | string | yes |"))
            #expect(!markdown.contains("| [] | object | yes |"))
        }
    }

    @Test("Docs route redirects to generated HTML documentation")
    func docsRouteRedirects() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "docs", afterResponse: { res async throws in
                #expect(res.status == .seeOther)
                #expect(res.headers.first(name: "Location") == "/docs/index.html")
            })
        }
    }

    @Test("Todo routes are registered under v1 without a route-specific rate limit")
    func todoRoutesAreRegistered() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "v1/todos", afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.decodeBody([TodoResponse].self)
                #expect(payload.isEmpty)
                #expect(res.headers.first(name: "X-RateLimit-Limit") == nil)
            })
        }
    }

    @Test("Only forgot-password has an explicit custom rate-limit policy")
    func routePoliciesAreConfigured() async throws {
        try await withApp { app in
            let todosRoute = route(app, method: .GET, suffix: "/v1/todos")
            #expect(todosRoute?.rateLimitPolicy == nil)

            let googleRoute = route(app, method: .POST, suffix: "/v1/auth/google")
            #expect(googleRoute?.rateLimitPolicy == nil)

            let appleRoute = route(app, method: .POST, suffix: "/v1/auth/apple")
            #expect(appleRoute?.rateLimitPolicy == nil)

            let otpRoute = route(app, method: .POST, suffix: "/v1/auth/verify-profile/email/request-otp")
            #expect(otpRoute?.rateLimitPolicy?.identifier == "auth.verify-email-otp")
            #expect(otpRoute?.rateLimitPolicy?.limit == 5)
            #expect(otpRoute?.rateLimitPolicy?.windowSeconds == 3600)

            let forgotPasswordRoute = route(app, method: .POST, suffix: "/v1/auth/forgot-password")
            #expect(forgotPasswordRoute?.rateLimitPolicy?.identifier == "auth.forgot-password")
            #expect(forgotPasswordRoute?.rateLimitPolicy?.limit == 3)
        }
    }

    @Test("Register returns tokens and current user")
    func registerAndFetchCurrentUser() async throws {
        let email = "alice+\(UUID().uuidString.lowercased())@example.com"
        let password = "Password1"
        let displayName = "Alice"

        try await withApp { app in
            var accessToken = ""

            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(RegisterRequest(email: email, password: password, displayName: displayName))
            }, afterResponse: { res async throws in
                #expect(res.status == .created)

                let payload = try res.decodeData(AuthResponse.self)
                #expect(!payload.accessToken.isEmpty)
                #expect(!payload.refreshToken.isEmpty)
                #expect(payload.user.email == email)
                #expect(payload.user.displayName == displayName)
                #expect(payload.user.isEmailVerified == false)
                #expect(payload.user.verifiedAt == nil)
                accessToken = payload.accessToken
            })

            try await app.testing().test(.GET, "v1/auth/me", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let payload = try res.decodeData(UserDTO.self)
                #expect(payload.email == email)
                #expect(payload.displayName == displayName)
                #expect(payload.isEmailVerified == false)
                #expect(payload.verifiedAt == nil)
            })
        }
    }

    @Test("Passkey registration and authentication work end-to-end")
    func passkeyRegistrationAndAuthentication() async throws {
        let email = "passkey+\(UUID().uuidString.lowercased())@example.com"
        let password = "Password1"
        let displayName = "Passkey User"
        let origin = "http://localhost"
        let passkey = TestPasskeyCredential()

        try await withApp { app in
            var accessToken = ""
            var userId = ""
            var registrationOptions: PasskeyRegistrationOptionsResponse?

            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(RegisterRequest(email: email, password: password, displayName: displayName))
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                let payload = try res.decodeData(AuthResponse.self)
                accessToken = payload.accessToken
                userId = payload.user.id
            })

            try await app.testing().test(.POST, "v1/auth/passkeys/register/options", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.decodeData(PasskeyRegistrationOptionsResponse.self)
                #expect(payload.rp.id == "localhost")
                #expect(payload.user.name == email)
                #expect(payload.excludeCredentials.isEmpty)
                registrationOptions = payload
            })

            let options = try #require(registrationOptions)
            let registrationRequest = try passkey.makeRegistrationRequest(
                challenge: options.challenge,
                rpId: options.rp.id,
                origin: origin
            )

            try await app.testing().test(.POST, "v1/auth/passkeys/register/verify", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(registrationRequest)
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                let payload = try res.decodeData(PasskeyCredentialDTO.self)
                #expect(payload.credentialId == passkey.credentialIdBase64URL)
                #expect(payload.transports == ["internal"])
            })

            try await app.testing().test(.POST, "v1/auth/passkeys/authenticate/options", beforeRequest: { req in
                try req.content.encode(PasskeyAuthenticationOptionsRequest(email: email))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.decodeData(PasskeyAuthenticationOptionsResponse.self)
                #expect(payload.rpId == "localhost")
                #expect(payload.allowCredentials.map(\.id).contains(passkey.credentialIdBase64URL))

                let authenticationRequest = try passkey.makeAuthenticationRequest(
                    challenge: payload.challenge,
                    rpId: payload.rpId,
                    origin: origin,
                    userHandle: options.user.id
                )

            try await app.testing().test(.POST, "v1/auth/passkeys/authenticate/verify", beforeRequest: { req in
                    try req.content.encode(authenticationRequest)
                }, afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let authPayload = try res.decodeData(AuthenticationResultResponse.self)
                    #expect(authPayload.requiresMFA == false)
                    let user = try #require(authPayload.user)
                    #expect(user.id == userId)
                    #expect(user.email == email)
                    #expect(user.displayName == displayName)
                    #expect(!(authPayload.accessToken ?? "").isEmpty)
                    #expect(!(authPayload.refreshToken ?? "").isEmpty)
                })
            })
        }
    }

    @Test("Google verify-profile marks a matching email as verified")
    func googleVerifyProfileMarksMatchingEmailAsVerified() async throws {
        let email = "verify-google+\(UUID().uuidString.lowercased())@example.com"
        let password = "Password1"
        let idToken = "google-verify-token"

        try await withApp { app in
            app.googleTokenVerifierFactory = { _ in
                MockGoogleTokenVerifier(profiles: [
                    idToken: GoogleUserProfile(
                        googleId: "google-\(UUID().uuidString)",
                        email: email.uppercased(),
                        displayName: "Verified Alice",
                        avatarUrl: "https://example.com/avatar.png"
                    )
                ])
            }

            var accessToken = ""

            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(RegisterRequest(email: email, password: password, displayName: "Alice"))
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                accessToken = try res.decodeData(AuthResponse.self).accessToken
            })

            try await app.testing().test(.POST, "v1/auth/verify-profile/google", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(VerifyProfileRequest(idToken: idToken))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let payload = try res.decodeData(UserDTO.self)
                #expect(payload.email == email)
                #expect(payload.isEmailVerified == true)
                #expect(payload.verifiedAt != nil)
            })
        }
    }

    @Test("Apple verify-profile marks a matching email as verified")
    func appleVerifyProfileMarksMatchingEmailAsVerified() async throws {
        let email = "verify-apple+\(UUID().uuidString.lowercased())@example.com"
        let password = "Password1"
        let idToken = "apple-verify-token"

        try await withApp { app in
            app.appleTokenVerifierFactory = { _ in
                MockAppleTokenVerifier(profiles: [
                    idToken: AppleUserProfile(
                        appleId: "apple-\(UUID().uuidString)",
                        email: email.uppercased(),
                        displayName: "Apple User",
                        isPrivateEmail: false
                    )
                ])
            }

            var accessToken = ""

            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(RegisterRequest(email: email, password: password, displayName: "Alice"))
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                accessToken = try res.decodeData(AuthResponse.self).accessToken
            })

            try await app.testing().test(.POST, "v1/auth/verify-profile/apple", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(VerifyProfileRequest(idToken: idToken))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let payload = try res.decodeData(UserDTO.self)
                #expect(payload.email == email)
                #expect(payload.isEmailVerified == true)
                #expect(payload.verifiedAt != nil)
            })
        }
    }

    @Test("Email OTP verification marks the profile as verified")
    func emailOTPVerificationMarksProfileVerified() async throws {
        let email = "verify-otp+\(UUID().uuidString.lowercased())@example.com"
        let password = "Password1"
        let box = AuthEmailDeliveryBox()

        try await withApp { app in
            app.authEmailDispatcherFactory = { _ in
                MockAuthEmailDispatcher(box: box)
            }

            var accessToken = ""

            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(RegisterRequest(email: email, password: password, displayName: "Alice"))
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                accessToken = try res.decodeData(AuthResponse.self).accessToken
            })

            try await app.testing().test(.POST, "v1/auth/verify-profile/email/request-otp", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.decodeData(MessageResponse.self)
                #expect(payload.message.contains("Verification code sent"))
                #expect(res.headers.first(name: "X-RateLimit-Limit") == "5")
            })

            let code = await box.currentCode(for: .verification)
            #expect(code != nil)

            try await app.testing().test(.POST, "v1/auth/verify-profile/email/confirm", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(VerifyEmailOTPRequest(code: code ?? "000000"))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let payload = try res.decodeData(UserDTO.self)
                #expect(payload.isEmailVerified == true)
                #expect(payload.verifiedAt != nil)
                #expect(res.headers.first(name: "X-RateLimit-Limit") == nil)
            })
        }
    }

    @Test("Verify profile rejects an SSO email that does not match the profile")
    func verifyProfileRejectsDifferentSSOEmail() async throws {
        let email = "mismatch+\(UUID().uuidString.lowercased())@example.com"
        let password = "Password1"
        let idToken = "mismatch-token"

        try await withApp { app in
            app.googleTokenVerifierFactory = { _ in
                MockGoogleTokenVerifier(profiles: [
                    idToken: GoogleUserProfile(
                        googleId: "google-\(UUID().uuidString)",
                        email: "other+\(UUID().uuidString.lowercased())@example.com",
                        displayName: "Other User",
                        avatarUrl: nil
                    )
                ])
            }

            var accessToken = ""

            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(RegisterRequest(email: email, password: password, displayName: "Mismatch"))
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                accessToken = try res.decodeData(AuthResponse.self).accessToken
            })

            try await app.testing().test(.POST, "v1/auth/verify-profile/google", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(VerifyProfileRequest(idToken: idToken))
            }, afterResponse: { res async throws in
                #expect(res.status == .conflict)

                let payload = try res.decodeData(ErrorResponse.self)
                #expect(payload.error == "VERIFICATION_EMAIL_MISMATCH")
            })
        }
    }

    @Test("Google sign-in links an existing email account")
    func googleSignInLinksExistingEmailAccount() async throws {
        let email = "google-link+\(UUID().uuidString.lowercased())@example.com"
        let password = "Password1"
        let idToken = "google-link-token"

        try await withApp { app in
            app.googleTokenVerifierFactory = { _ in
                MockGoogleTokenVerifier(profiles: [
                    idToken: GoogleUserProfile(
                        googleId: "google-\(UUID().uuidString)",
                        email: email.uppercased(),
                        displayName: "Linked User",
                        avatarUrl: "https://example.com/linked.png"
                    )
                ])
            }

            var registeredUserID = ""

            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(RegisterRequest(email: email, password: password, displayName: "Linked User"))
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                registeredUserID = try res.decodeData(AuthResponse.self).user.id
            })

            try await app.testing().test(.POST, "v1/auth/google", beforeRequest: { req in
                try req.content.encode(GoogleLoginRequest(idToken: idToken))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let payload = try res.decodeData(AuthenticationResultResponse.self)
                #expect(payload.requiresMFA == false)
                let user = try #require(payload.user)
                #expect(user.id == registeredUserID)
                #expect(user.email == email)
                #expect(user.isEmailVerified == true)
                #expect(user.verifiedAt != nil)
            })
        }
    }

    @Test("Apple sign-in links an existing email account")
    func appleSignInLinksExistingEmailAccount() async throws {
        let email = "apple-link+\(UUID().uuidString.lowercased())@example.com"
        let password = "Password1"
        let idToken = "apple-link-token"

        try await withApp { app in
            app.appleTokenVerifierFactory = { _ in
                MockAppleTokenVerifier(profiles: [
                    idToken: AppleUserProfile(
                        appleId: "apple-\(UUID().uuidString)",
                        email: email.uppercased(),
                        displayName: "Apple User",
                        isPrivateEmail: false
                    )
                ])
            }

            var registeredUserID = ""

            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(RegisterRequest(email: email, password: password, displayName: "Linked User"))
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                registeredUserID = try res.decodeData(AuthResponse.self).user.id
            })

            try await app.testing().test(.POST, "v1/auth/apple", beforeRequest: { req in
                try req.content.encode(AppleLoginRequest(idToken: idToken))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let payload = try res.decodeData(AuthenticationResultResponse.self)
                #expect(payload.requiresMFA == false)
                let user = try #require(payload.user)
                #expect(user.id == registeredUserID)
                #expect(user.email == email)
                #expect(user.isEmailVerified == true)
                #expect(user.verifiedAt != nil)
            })
        }
    }

    @Test("Login normalizes email before lookup")
    func loginNormalizesEmail() async throws {
        let email = "bob+\(UUID().uuidString.lowercased())@example.com"
        let password = "Password1"

        try await withApp { app in
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(RegisterRequest(email: email, password: password, displayName: "Bob"))
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
            })

            try await app.testing().test(.POST, "v1/auth/login", beforeRequest: { req in
                try req.content.encode(LoginRequest(email: "  \(email.uppercased())  ", password: password))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let payload = try res.decodeData(AuthenticationResultResponse.self)
                #expect(payload.requiresMFA == false)
                let user = try #require(payload.user)
                #expect(user.email == email)
            })
        }
    }

    @Test("Password reset changes the password and revokes existing password login")
    func passwordResetChangesPassword() async throws {
        let email = "reset+\(UUID().uuidString.lowercased())@example.com"
        let password = "Password1"
        let newPassword = "ResetPass2"
        let box = AuthEmailDeliveryBox()

        try await withApp { app in
            app.authEmailDispatcherFactory = { _ in
                MockAuthEmailDispatcher(box: box)
            }

            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(RegisterRequest(email: email, password: password, displayName: "Reset User"))
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
            })

            try await app.testing().test(.POST, "v1/auth/forgot-password", beforeRequest: { req in
                try req.content.encode(ForgotPasswordRequest(email: email))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })

            let code = try #require(await box.currentCode(for: .passwordReset))

            try await app.testing().test(.POST, "v1/auth/reset-password", beforeRequest: { req in
                try req.content.encode(ResetPasswordRequest(email: email, code: code, newPassword: newPassword))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.decodeData(MessageResponse.self)
                #expect(payload.message == "Password has been reset.")
            })

            try await app.testing().test(.POST, "v1/auth/login", beforeRequest: { req in
                try req.content.encode(LoginRequest(email: email, password: password))
            }, afterResponse: { res async throws in
                #expect(res.status == .unauthorized)
                let payload = try res.decodeData(ErrorResponse.self)
                #expect(payload.error == "INVALID_CREDENTIALS")
            })

            try await app.testing().test(.POST, "v1/auth/login", beforeRequest: { req in
                try req.content.encode(LoginRequest(email: email, password: newPassword))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.decodeData(AuthenticationResultResponse.self)
                #expect(payload.requiresMFA == false)
                let user = try #require(payload.user)
                #expect(user.email == email)
            })
        }
    }

    @Test("Email MFA can be enabled and then required on login")
    func emailMFAEnableAndLoginFlow() async throws {
        let email = "mfa+\(UUID().uuidString.lowercased())@example.com"
        let password = "Password1"
        let box = AuthEmailDeliveryBox()

        try await withApp { app in
            app.authEmailDispatcherFactory = { _ in
                MockAuthEmailDispatcher(box: box)
            }

            var bootstrapToken = ""

            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(RegisterRequest(email: email, password: password, displayName: "MFA User"))
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                bootstrapToken = try res.decodeData(AuthResponse.self).accessToken
            })

            try await app.testing().test(.POST, "v1/auth/verify-profile/email/request-otp", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: bootstrapToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })

            let verificationCode = try #require(await box.currentCode(for: .verification))

            try await app.testing().test(.POST, "v1/auth/verify-profile/email/confirm", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: bootstrapToken)
                try req.content.encode(VerifyEmailOTPRequest(code: verificationCode))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.decodeData(UserDTO.self)
                #expect(payload.isEmailVerified == true)
            })

            try await app.testing().test(.POST, "v1/auth/mfa/email/enable", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: bootstrapToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.decodeData(MessageResponse.self)
                #expect(payload.message.contains("MFA enable code sent"))
            })

            let mfaEnableCode = try #require(await box.currentCode(for: .mfaEnable))

            try await app.testing().test(.POST, "v1/auth/mfa/email/confirm-enable", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: bootstrapToken)
                try req.content.encode(ConfirmEmailMFAEnableRequest(code: mfaEnableCode))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.decodeData(UserDTO.self)
                #expect(payload.isMFAEnabled == true)
                #expect(payload.mfaMethod == "email")
            })

            var finalAccessToken = ""

            try await app.testing().test(.POST, "v1/auth/login", beforeRequest: { req in
                try req.content.encode(LoginRequest(email: email, password: password))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.decodeData(AuthenticationResultResponse.self)
                #expect(payload.requiresMFA == true)
                #expect(payload.accessToken == nil)
                #expect(payload.refreshToken == nil)
                let challenge = try #require(payload.mfaChallenge)
                #expect(challenge.method == "email")
                let challengeToken = try #require(challenge.challengeToken)

                let mfaLoginCode = try #require(await box.currentCode(for: .mfaLogin))

                try await app.testing().test(.POST, "v1/auth/mfa/email/verify", beforeRequest: { req in
                    try req.content.encode(MFALoginVerifyRequest(challengeToken: challengeToken, code: mfaLoginCode))
                }, afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let authPayload = try res.decodeData(AuthResponse.self)
                    #expect(authPayload.user.email == email)
                    #expect(authPayload.user.isMFAEnabled == true)
                    finalAccessToken = authPayload.accessToken
                })
            })

            try await app.testing().test(.POST, "v1/auth/mfa/email/disable", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: finalAccessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.decodeData(UserDTO.self)
                #expect(payload.isMFAEnabled == false)
                #expect(payload.mfaMethod == nil)
            })

            try await app.testing().test(.POST, "v1/auth/login", beforeRequest: { req in
                try req.content.encode(LoginRequest(email: email, password: password))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.decodeData(AuthenticationResultResponse.self)
                #expect(payload.requiresMFA == false)
                let user = try #require(payload.user)
                #expect(user.email == email)
            })
        }
    }

    @Test("Authenticator app MFA can be enabled and then required on login")
    func authenticatorAppMFAEnableAndLoginFlow() async throws {
        let email = "totp+\(UUID().uuidString.lowercased())@example.com"
        let password = "Password1"

        try await withApp { app in
            var bootstrapToken = ""
            var setupResponse: AuthenticatorAppMFASetupResponse?

            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(RegisterRequest(email: email, password: password, displayName: "TOTP User"))
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                bootstrapToken = try res.decodeData(AuthResponse.self).accessToken
            })

            try await app.testing().test(.POST, "v1/auth/mfa/authenticator-app/setup", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: bootstrapToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.decodeData(AuthenticatorAppMFASetupResponse.self)
                #expect(!payload.secret.isEmpty)
                #expect(payload.issuer == "Tricount")
                #expect(payload.accountName == email)
                #expect(payload.otpauthURL.contains("otpauth://totp/"))
                setupResponse = payload
            })

            let setup = try #require(setupResponse)
            let enableCode = try TOTPService.generateCode(secret: setup.secret)

            try await app.testing().test(.POST, "v1/auth/mfa/authenticator-app/confirm-enable", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: bootstrapToken)
                try req.content.encode(ConfirmEmailMFAEnableRequest(code: enableCode))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.decodeData(UserDTO.self)
                #expect(payload.isMFAEnabled == true)
                #expect(payload.mfaMethod == "authenticator_app")
            })

            var finalAccessToken = ""

            try await app.testing().test(.POST, "v1/auth/login", beforeRequest: { req in
                try req.content.encode(LoginRequest(email: email, password: password))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.decodeData(AuthenticationResultResponse.self)
                #expect(payload.requiresMFA == true)
                let challenge = try #require(payload.mfaChallenge)
                #expect(challenge.method == "authenticator_app")
                let challengeToken = try #require(challenge.challengeToken)
                let loginCode = try TOTPService.generateCode(secret: setup.secret)

                try await app.testing().test(.POST, "v1/auth/mfa/authenticator-app/verify", beforeRequest: { req in
                    try req.content.encode(MFALoginVerifyRequest(challengeToken: challengeToken, code: loginCode))
                }, afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let authPayload = try res.decodeData(AuthResponse.self)
                    #expect(authPayload.user.email == email)
                    #expect(authPayload.user.isMFAEnabled == true)
                    #expect(authPayload.user.mfaMethod == "authenticator_app")
                    finalAccessToken = authPayload.accessToken
                })
            })

            try await app.testing().test(.POST, "v1/auth/mfa/authenticator-app/disable", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: finalAccessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.decodeData(UserDTO.self)
                #expect(payload.isMFAEnabled == false)
                #expect(payload.mfaMethod == nil)
            })
        }
    }

    @Test("Phone number can be verified and removed")
    func phoneVerificationAndRemovalFlow() async throws {
        let email = "phone+\(UUID().uuidString.lowercased())@example.com"
        let password = "Password1"
        let phoneNumber = "+919876543210"
        let smsBox = AuthSMSDeliveryBox()

        try await withApp { app in
            app.authSMSDispatcherFactory = { _ in
                MockAuthSMSDispatcher(box: smsBox)
            }

            var accessToken = ""

            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(RegisterRequest(email: email, password: password, displayName: "Phone User"))
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                accessToken = try res.decodeData(AuthResponse.self).accessToken
            })

            try await app.testing().test(.POST, "v1/auth/phone/request-verification", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(SetupPhoneVerificationRequest(phoneNumber: phoneNumber))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.decodeData(MessageResponse.self)
                #expect(payload.message.contains(phoneNumber))
            })

            let verificationCode = try #require(await smsBox.currentPhoneVerificationCode())

            try await app.testing().test(.POST, "v1/auth/phone/confirm-verification", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(ConfirmPhoneVerificationRequest(code: verificationCode))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.decodeData(UserDTO.self)
                #expect(payload.phoneNumber == phoneNumber)
                #expect(payload.isPhoneVerified == true)
                #expect(payload.phoneVerifiedAt != nil)
            })

            try await app.testing().test(.POST, "v1/auth/phone/remove", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.decodeData(UserDTO.self)
                #expect(payload.phoneNumber == nil)
                #expect(payload.isPhoneVerified == false)
                #expect(payload.phoneVerifiedAt == nil)
            })
        }
    }

    @Test("Passkeys can be listed, removed individually, and reset")
    func passkeyManagementFlow() async throws {
        let email = "passkey-manage+\(UUID().uuidString.lowercased())@example.com"
        let password = "Password1"
        let displayName = "Manage Passkeys"
        let origin = "http://localhost"
        let firstPasskey = TestPasskeyCredential()
        let secondPasskey = TestPasskeyCredential()

        try await withApp { app in
            var accessToken = ""

            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(RegisterRequest(email: email, password: password, displayName: displayName))
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                accessToken = try res.decodeData(AuthResponse.self).accessToken
            })

            func registerPasskey(_ credential: TestPasskeyCredential) async throws {
                var registrationOptions: PasskeyRegistrationOptionsResponse?

                try await app.testing().test(.POST, "v1/auth/passkeys/register/options", beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: accessToken)
                }, afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    registrationOptions = try res.decodeData(PasskeyRegistrationOptionsResponse.self)
                })

                let options = try #require(registrationOptions)
                let registrationRequest = try credential.makeRegistrationRequest(
                    challenge: options.challenge,
                    rpId: options.rp.id,
                    origin: origin
                )

                try await app.testing().test(.POST, "v1/auth/passkeys/register/verify", beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: accessToken)
                    try req.content.encode(registrationRequest)
                }, afterResponse: { res async throws in
                    #expect(res.status == .created)
                    let payload = try res.decodeData(PasskeyCredentialDTO.self)
                    #expect(payload.credentialId == credential.credentialIdBase64URL)
                })
            }

            try await registerPasskey(firstPasskey)
            try await registerPasskey(secondPasskey)

            try await app.testing().test(.GET, "v1/auth/passkeys", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.decodeBody([PasskeyCredentialDTO].self)
                #expect(payload.count == 2)
                #expect(payload.map(\.credentialId).contains(firstPasskey.credentialIdBase64URL))
                #expect(payload.map(\.credentialId).contains(secondPasskey.credentialIdBase64URL))
            })

            try await app.testing().test(.POST, "v1/auth/passkeys/remove", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(RemovePasskeyRequest(credentialId: firstPasskey.credentialIdBase64URL))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.decodeData(MessageResponse.self)
                #expect(payload.message == "Passkey removed.")
            })

            try await app.testing().test(.GET, "v1/auth/passkeys", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.decodeBody([PasskeyCredentialDTO].self)
                #expect(payload.count == 1)
                #expect(payload.first?.credentialId == secondPasskey.credentialIdBase64URL)
            })

            try await app.testing().test(.POST, "v1/auth/passkeys/reset", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.decodeData(MessageResponse.self)
                #expect(payload.message == "All passkeys removed.")
            })

            try await app.testing().test(.GET, "v1/auth/passkeys", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.decodeBody([PasskeyCredentialDTO].self)
                #expect(payload.isEmpty)
            })
        }
    }

    @Test("Protected route rejects missing bearer token")
    func meRequiresAuthentication() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "v1/auth/me", afterResponse: { res async throws in
                #expect(res.status == .unauthorized)

                let payload = try res.decodeData(ErrorResponse.self)
                #expect(payload.error == "MISSING_TOKEN")
                #expect(res.headers.first(name: "X-RateLimit-Limit") == nil)
                #expect(!(res.headers.first(name: "X-Request-ID") ?? "").isEmpty)
                #expect((res.headers.first(name: "Server-Timing") ?? "").contains("app;dur="))
            })
        }
    }

    @Test("Forgot password keeps its explicit rate-limit override")
    func forgotPasswordUsesCustomRateLimit() async throws {
        try await withApp { app in
            try await app.testing().test(.POST, "v1/auth/forgot-password", beforeRequest: { req in
                try req.content.encode(ForgotPasswordRequest(email: "reset@example.com"))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: "X-RateLimit-Limit") == "3")
            })
        }
    }

    // MARK: - Registration Validation Tests

    @Test("Duplicate registration returns 409 EMAIL_ALREADY_EXISTS")
    func duplicateRegistrationReturnsConflict() async throws {
        let email = "dup+\(UUID().uuidString.lowercased())@example.com"
        let password = "Password1"

        try await withApp { app in
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(RegisterRequest(email: email, password: password, displayName: "First"))
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
            })

            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(RegisterRequest(email: email, password: password, displayName: "Second"))
            }, afterResponse: { res async throws in
                #expect(res.status == .conflict)
                let payload = try res.decodeData(ErrorResponse.self)
                #expect(payload.error == "EMAIL_ALREADY_EXISTS")
            })
        }
    }

    @Test("Register with weak password returns 400")
    func registerWeakPasswordReturns400() async throws {
        try await withApp { app in
            // Too short
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(RegisterRequest(email: "weak1@example.com", password: "Ab1", displayName: "Test"))
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
            })

            // No uppercase
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(RegisterRequest(email: "weak2@example.com", password: "password1", displayName: "Test"))
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
            })

            // No lowercase
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(RegisterRequest(email: "weak3@example.com", password: "PASSWORD1", displayName: "Test"))
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
            })

            // No digit
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(RegisterRequest(email: "weak4@example.com", password: "PasswordNoDigit", displayName: "Test"))
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
            })
        }
    }

    // MARK: - Login Validation Tests

    @Test("Login with wrong password returns 401 INVALID_CREDENTIALS")
    func loginWrongPasswordReturns401() async throws {
        let email = "wrongpw+\(UUID().uuidString.lowercased())@example.com"

        try await withApp { app in
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(RegisterRequest(email: email, password: "Password1", displayName: "Test"))
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
            })

            try await app.testing().test(.POST, "v1/auth/login", beforeRequest: { req in
                try req.content.encode(LoginRequest(email: email, password: "WrongPass1"))
            }, afterResponse: { res async throws in
                #expect(res.status == .unauthorized)
                let payload = try res.decodeData(ErrorResponse.self)
                #expect(payload.error == "INVALID_CREDENTIALS")
            })
        }
    }

    @Test("Login with empty email or password returns 400")
    func loginEmptyFieldsReturns400() async throws {
        try await withApp { app in
            try await app.testing().test(.POST, "v1/auth/login", beforeRequest: { req in
                try req.content.encode(LoginRequest(email: "", password: "Password1"))
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
            })

            try await app.testing().test(.POST, "v1/auth/login", beforeRequest: { req in
                try req.content.encode(LoginRequest(email: "test@example.com", password: ""))
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("Login with nonexistent email returns 401")
    func loginNonexistentEmailReturns401() async throws {
        try await withApp { app in
            try await app.testing().test(.POST, "v1/auth/login", beforeRequest: { req in
                try req.content.encode(LoginRequest(email: "noexist+\(UUID().uuidString)@example.com", password: "Password1"))
            }, afterResponse: { res async throws in
                #expect(res.status == .unauthorized)
                let payload = try res.decodeData(ErrorResponse.self)
                #expect(payload.error == "INVALID_CREDENTIALS")
            })
        }
    }

    // MARK: - JWT Validation Tests

    @Test("Invalid JWT token returns 401 INVALID_TOKEN")
    func invalidJWTReturnsUnauthorized() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "v1/auth/me", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: "invalid.jwt.token")
            }, afterResponse: { res async throws in
                #expect(res.status == .unauthorized)
                let payload = try res.decodeData(ErrorResponse.self)
                #expect(payload.error == "INVALID_TOKEN")
            })
        }
    }

    // MARK: - Token Refresh Tests

    @Test("Token refresh rotates tokens and old refresh token is invalidated")
    func tokenRefreshRotatesTokens() async throws {
        let email = "refresh+\(UUID().uuidString.lowercased())@example.com"

        try await withApp { app in
            var refreshToken = ""

            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(RegisterRequest(email: email, password: "Password1", displayName: "Refresh User"))
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                let payload = try res.decodeData(AuthResponse.self)
                refreshToken = payload.refreshToken
            })

            var newRefreshToken = ""

            // Refresh once — should succeed
            try await app.testing().test(.POST, "v1/auth/refresh", beforeRequest: { req in
                try req.content.encode(RefreshTokenRequest(refreshToken: refreshToken))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.decodeData(TokenRefreshResponse.self)
                #expect(!payload.accessToken.isEmpty)
                #expect(!payload.refreshToken.isEmpty)
                #expect(payload.refreshToken != refreshToken)
                newRefreshToken = payload.refreshToken
            })

            // Old refresh token should now be revoked
            try await app.testing().test(.POST, "v1/auth/refresh", beforeRequest: { req in
                try req.content.encode(RefreshTokenRequest(refreshToken: refreshToken))
            }, afterResponse: { res async throws in
                #expect(res.status == .unauthorized)
                let payload = try res.decodeData(ErrorResponse.self)
                #expect(payload.error == "REFRESH_TOKEN_INVALID")
            })

            // New refresh token should still work
            try await app.testing().test(.POST, "v1/auth/refresh", beforeRequest: { req in
                try req.content.encode(RefreshTokenRequest(refreshToken: newRefreshToken))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })
        }
    }

    @Test("Invalid refresh token returns 401")
    func invalidRefreshTokenReturns401() async throws {
        try await withApp { app in
            try await app.testing().test(.POST, "v1/auth/refresh", beforeRequest: { req in
                try req.content.encode(RefreshTokenRequest(refreshToken: "completely-bogus-token"))
            }, afterResponse: { res async throws in
                #expect(res.status == .unauthorized)
                let payload = try res.decodeData(ErrorResponse.self)
                #expect(payload.error == "REFRESH_TOKEN_INVALID")
            })
        }
    }

    // MARK: - Logout Tests

    @Test("Logout revokes all refresh tokens for the user")
    func logoutRevokesRefreshTokens() async throws {
        let email = "logout+\(UUID().uuidString.lowercased())@example.com"

        try await withApp { app in
            var accessToken = ""
            var refreshToken = ""

            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(RegisterRequest(email: email, password: "Password1", displayName: "Logout User"))
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                let payload = try res.decodeData(AuthResponse.self)
                accessToken = payload.accessToken
                refreshToken = payload.refreshToken
            })

            // Logout
            try await app.testing().test(.POST, "v1/auth/logout", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .noContent)
            })

            // Refresh token should now be revoked
            try await app.testing().test(.POST, "v1/auth/refresh", beforeRequest: { req in
                try req.content.encode(RefreshTokenRequest(refreshToken: refreshToken))
            }, afterResponse: { res async throws in
                #expect(res.status == .unauthorized)
                let payload = try res.decodeData(ErrorResponse.self)
                #expect(payload.error == "REFRESH_TOKEN_INVALID")
            })
        }
    }

    // MARK: - Rate Limiting Tests

    @Test("Rate limiter enforces forgot-password limit and returns 429")
    func rateLimiterEnforcesLimitAndReturns429() async throws {
        let email = "ratelimit+\(UUID().uuidString.lowercased())@example.com"

        try await withApp { app in
            // Exhaust the 3 requests/hour limit
            for i in 1...3 {
                try await app.testing().test(.POST, "v1/auth/forgot-password", beforeRequest: { req in
                    try req.content.encode(ForgotPasswordRequest(email: email))
                }, afterResponse: { res async throws in
                    #expect(res.status == .ok, "Request \(i) should succeed")
                })
            }

            // 4th request should be rate-limited
            try await app.testing().test(.POST, "v1/auth/forgot-password", beforeRequest: { req in
                try req.content.encode(ForgotPasswordRequest(email: email))
            }, afterResponse: { res async throws in
                #expect(res.status == .tooManyRequests)
                let payload = try res.decodeData(ErrorResponse.self)
                #expect(payload.error == "RATE_LIMIT_EXCEEDED")
                #expect(payload.statusCode == 429)
                let retryAfter = res.headers.first(name: "Retry-After")
                #expect(retryAfter != nil)
            })
        }
    }

    // MARK: - Todo CRUD Tests

    @Test("Todo can be created and listed")
    func todoCRUDCreateAndList() async throws {
        try await withApp { app in
            // List is initially empty
            try await app.testing().test(.GET, "v1/todos", afterResponse: { res async throws in
                #expect(res.status == .ok)
                let todos = try res.decodeBody([TodoResponse].self)
                #expect(todos.isEmpty)
            })

            // Create a todo
            try await app.testing().test(.POST, "v1/todos", beforeRequest: { req in
                try req.content.encode(CreateTodoRequest(title: "Buy groceries"))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })

            // List should now have one item
            try await app.testing().test(.GET, "v1/todos", afterResponse: { res async throws in
                #expect(res.status == .ok)
                let todos = try res.decodeBody([TodoResponse].self)
                #expect(todos.count == 1)
                #expect(todos.first?.title == "Buy groceries")
            })
        }
    }

    @Test("Todo can be deleted")
    func todoCRUDDelete() async throws {
        try await withApp { app in
            // Create a todo
            var todoId: UUID?

            try await app.testing().test(.POST, "v1/todos", beforeRequest: { req in
                try req.content.encode(CreateTodoRequest(title: "Delete me"))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })

            try await app.testing().test(.GET, "v1/todos", afterResponse: { res async throws in
                let todos = try res.decodeBody([TodoResponse].self)
                todoId = todos.first?.id
            })

            let id = try #require(todoId)

            // Delete the todo
            try await app.testing().test(.DELETE, "v1/todos/\(id)", afterResponse: { res async throws in
                #expect(res.status == .noContent)
            })

            // List should now be empty
            try await app.testing().test(.GET, "v1/todos", afterResponse: { res async throws in
                let todos = try res.decodeBody([TodoResponse].self)
                #expect(todos.isEmpty)
            })
        }
    }

    @Test("Deleting a nonexistent todo returns 404")
    func deleteNonexistentTodoReturns404() async throws {
        try await withApp { app in
            try await app.testing().test(.DELETE, "v1/todos/\(UUID())", afterResponse: { res async throws in
                #expect(res.status == .notFound)
            })
        }
    }

    // MARK: - Password Reset Edge Cases

    @Test("Reset password with invalid code returns 401")
    func resetPasswordInvalidCodeReturns401() async throws {
        let email = "resetfail+\(UUID().uuidString.lowercased())@example.com"
        let box = AuthEmailDeliveryBox()

        try await withApp { app in
            app.authEmailDispatcherFactory = { _ in
                MockAuthEmailDispatcher(box: box)
            }

            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(RegisterRequest(email: email, password: "Password1", displayName: "Test"))
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
            })

            try await app.testing().test(.POST, "v1/auth/forgot-password", beforeRequest: { req in
                try req.content.encode(ForgotPasswordRequest(email: email))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })

            // Use an invalid code
            try await app.testing().test(.POST, "v1/auth/reset-password", beforeRequest: { req in
                try req.content.encode(ResetPasswordRequest(email: email, code: "000000", newPassword: "NewPass1"))
            }, afterResponse: { res async throws in
                #expect(res.status == .unauthorized)
                let payload = try res.decodeData(ErrorResponse.self)
                #expect(payload.error == "PASSWORD_RESET_CODE_INVALID")
            })
        }
    }

    // MARK: - Display Name Validation

    @Test("Register with short display name returns 400")
    func registerShortDisplayNameReturns400() async throws {
        try await withApp { app in
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(RegisterRequest(email: "short+\(UUID().uuidString)@example.com", password: "Password1", displayName: "A"))
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
            })
        }
    }
}
