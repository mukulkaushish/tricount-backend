import Vapor
import Foundation

protocol GoogleTokenVerifying: Sendable {
    func verifyToken(_ idToken: String) async throws -> GoogleUserProfile
}

/// Validates a Google ID token by calling Google's tokeninfo endpoint.
/// Returns the extracted user profile on success.
struct GoogleUserProfile: Sendable {
    let googleId: String
    let email: String
    let displayName: String
    let avatarUrl: String?
}

struct GoogleAuthService: Sendable {
    private let client: any Client

    init(client: any Client) {
        self.client = client
    }

    func verifyToken(_ idToken: String) async throws -> GoogleUserProfile {
        let encodedToken = idToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? idToken
        let uri = URI(string: "https://www.googleapis.com/oauth2/v3/tokeninfo?id_token=\(encodedToken)")
        let response = try await client.get(uri)

        guard response.status == .ok else {
            throw AuthError.googleTokenInvalid
        }

        let payload = try response.content.decode(GoogleTokenInfoResponse.self)

        guard payload.issuer == "accounts.google.com"
            || payload.issuer == "https://accounts.google.com"
        else {
            throw AuthError.googleTokenInvalid
        }

        if let expectedAudience = Environment.get("GOOGLE_CLIENT_ID") {
            guard payload.audience == expectedAudience else {
                throw AuthError.googleTokenInvalid
            }
        }

        guard payload.emailVerified == "true" || payload.emailVerified == "1" else {
            throw AuthError.googleTokenInvalid
        }

        guard let sub = payload.sub, let email = payload.email else {
            throw AuthError.googleTokenInvalid
        }

        let displayName = payload.name ?? email.components(separatedBy: "@").first ?? "User"

        return GoogleUserProfile(
            googleId: sub,
            email: email,
            displayName: displayName,
            avatarUrl: payload.picture
        )
    }
}

extension GoogleAuthService: GoogleTokenVerifying {}

extension Application {
    private struct GoogleTokenVerifierFactoryKey: StorageKey {
        typealias Value = @Sendable (Request) -> any GoogleTokenVerifying
    }

    var googleTokenVerifierFactory: @Sendable (Request) -> any GoogleTokenVerifying {
        get {
            self.storage[GoogleTokenVerifierFactoryKey.self] ?? { request in
                GoogleAuthService(client: request.client)
            }
        }
        set {
            self.storage[GoogleTokenVerifierFactoryKey.self] = newValue
        }
    }
}

extension Request {
    var googleTokenVerifier: any GoogleTokenVerifying {
        self.application.googleTokenVerifierFactory(self)
    }
}

// MARK: - Google tokeninfo response shape

private struct GoogleTokenInfoResponse: Content {
    let sub: String?
    let email: String?
    let audience: String?
    let emailVerified: String?
    let issuer: String?
    let name: String?
    let picture: String?

    enum CodingKeys: String, CodingKey {
        case sub
        case email
        case audience = "aud"
        case emailVerified = "email_verified"
        case issuer = "iss"
        case name
        case picture
    }
}
