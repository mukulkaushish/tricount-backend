import Vapor

// MARK: - Requests

struct LoginRequest: Content {
    let email: String
    let password: String
}

struct RegisterRequest: Content {
    let email: String
    let password: String
    let displayName: String
}

struct GoogleLoginRequest: Content {
    let idToken: String
}

struct AppleLoginRequest: Content {
    let idToken: String
}

struct VerifyProfileRequest: Content {
    let idToken: String
}

struct VerifyEmailOTPRequest: Content {
    let code: String
}

struct RefreshTokenRequest: Content {
    let refreshToken: String
}

struct ForgotPasswordRequest: Content {
    let email: String
}

struct ResetPasswordRequest: Content {
    let email: String
    let code: String
    let newPassword: String
}

struct MFALoginVerifyRequest: Content {
    let challengeToken: String
    let code: String
}

struct ConfirmEmailMFAEnableRequest: Content {
    let code: String
}

struct SetupPhoneVerificationRequest: Content {
    let phoneNumber: String
}

struct ConfirmPhoneVerificationRequest: Content {
    let code: String
}

struct AuthenticatorAppMFASetupResponse: Content {
    let secret: String
    let issuer: String
    let accountName: String
    let otpauthURL: String
    let digits: Int
    let period: Int
}

// MARK: - Responses

struct UserDTO: Content {
    // ISO8601DateFormatter is thread-safe for formatting; suppress Sendable warning.
    nonisolated(unsafe) private static let dateFormatter: ISO8601DateFormatter = ISO8601DateFormatter()

    let id: String
    let displayName: String
    let email: String
    let avatarUrl: String?
    let isEmailVerified: Bool
    let verifiedAt: String?
    let isMFAEnabled: Bool
    let mfaMethod: String?
    let phoneNumber: String?
    let isPhoneVerified: Bool
    let phoneVerifiedAt: String?
    let createdAt: String

    init(from user: User) {
        self.id = user.id?.uuidString ?? ""
        self.displayName = user.displayName
        self.email = user.email
        self.avatarUrl = user.avatarUrl
        self.isEmailVerified = user.isEmailVerified
        self.verifiedAt = user.verifiedAt.map(Self.dateFormatter.string(from:))
        self.isMFAEnabled = user.isMFAEnabled
        self.mfaMethod = user.mfaMethod
        self.phoneNumber = user.phoneNumber
        self.isPhoneVerified = user.isPhoneVerified
        self.phoneVerifiedAt = user.phoneVerifiedAt.map(Self.dateFormatter.string(from:))
        self.createdAt = Self.dateFormatter.string(from: user.createdAt ?? Date())
    }
}

struct MFAChallengeResponse: Content {
    let method: String
    let challengeToken: String?
    let expiresIn: Int?
}

struct AuthenticationResultResponse: Content {
    let requiresMFA: Bool
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Int?
    let user: UserDTO?
    let mfaChallenge: MFAChallengeResponse?

    static func authenticated(from response: AuthResponse) -> AuthenticationResultResponse {
        AuthenticationResultResponse(
            requiresMFA: false,
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expiresIn: response.expiresIn,
            user: response.user,
            mfaChallenge: nil
        )
    }

    static func requiresMFA(challenge: MFAChallengeResponse) -> AuthenticationResultResponse {
        AuthenticationResultResponse(
            requiresMFA: true,
            accessToken: nil,
            refreshToken: nil,
            expiresIn: nil,
            user: nil,
            mfaChallenge: challenge
        )
    }
}

struct AuthResponse: Content {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let user: UserDTO
}

struct TokenRefreshResponse: Content {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
}

struct MessageResponse: Content {
    let message: String
}

struct HealthCheckResponse: Content {
    let status: String
    let service: String
}

// MARK: - Error Response

struct ErrorResponse: Content {
    let error: String
    let message: String
    let statusCode: Int
}

