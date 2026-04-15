import Vapor
import JWT
import Foundation

protocol AppleTokenVerifying: Sendable {
    func verifyToken(_ idToken: String) async throws -> AppleUserProfile
}

struct AppleUserProfile: Sendable {
    let appleId: String
    let email: String?
    let displayName: String
    let isPrivateEmail: Bool
}

struct AppleAuthService: Sendable {
    private let req: Request

    init(req: Request) {
        self.req = req
    }

    func verifyToken(_ idToken: String) async throws -> AppleUserProfile {
        do {
            let applicationIdentifier = req.application.runtimeConfiguration.oauth.appleApplicationIdentifier
            let token = try await req.jwt.apple.verify(idToken, applicationIdentifier: applicationIdentifier)
            let normalizedEmail = token.email.map(AuthValidation.normalizeEmail)
            let displayName = normalizedEmail?.components(separatedBy: "@").first ?? "Apple User"

            return AppleUserProfile(
                appleId: token.subject.value,
                email: normalizedEmail,
                displayName: displayName,
                isPrivateEmail: token.isPrivateEmail?.value ?? false
            )
        } catch {
            throw AuthError.appleTokenInvalid
        }
    }
}

extension AppleAuthService: AppleTokenVerifying {}

extension Application {
    private struct AppleTokenVerifierFactoryKey: StorageKey {
        typealias Value = @Sendable (Request) -> any AppleTokenVerifying
    }

    var appleTokenVerifierFactory: @Sendable (Request) -> any AppleTokenVerifying {
        get {
            self.storage[AppleTokenVerifierFactoryKey.self] ?? { request in
                AppleAuthService(req: request)
            }
        }
        set {
            self.storage[AppleTokenVerifierFactoryKey.self] = newValue
        }
    }
}

extension Request {
    var appleTokenVerifier: any AppleTokenVerifying {
        self.application.appleTokenVerifierFactory(self)
    }
}
