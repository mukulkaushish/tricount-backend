import Vapor
import JWT

/// Verifies the Bearer JWT on every protected request.
/// Attaches the decoded `UserJWTPayload` so downstream handlers can read it.
struct JWTAuthMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let token = request.headers.bearerAuthorization?.token else {
            throw AuthError.missingToken
        }

        do {
            _ = try request.jwt.verify(token, as: UserJWTPayload.self)
        } catch {
            throw AuthError.invalidToken
        }

        return try await next.respond(to: request)
    }
}

// MARK: - Auth-domain errors → standard JSON shape

enum AuthError: AbortError {
    case missingToken
    case invalidToken
    case invalidCredentials
    case emailAlreadyExists
    case googleTokenInvalid
    case appleTokenInvalid
    case verificationEmailMismatch
    case appleEmailMissing
    case socialAccountAlreadyLinked
    case verificationOTPInvalid
    case refreshTokenInvalid
    case passwordResetCodeInvalid
    case mfaChallengeInvalid
    case mfaCodeInvalid
    case mfaConfigurationInvalid
    case mfaRequiresVerifiedEmail
    case phoneVerificationCodeInvalid
    case authenticatorAppSetupInvalid
    case passkeyChallengeInvalid
    case passkeyRegistrationInvalid
    case passkeyAuthenticationInvalid
    case passkeyCredentialAlreadyExists
    case passkeyCredentialNotFound
    case emailNotVerified

    var status: HTTPStatus {
        switch self {
        case .missingToken, .invalidToken, .invalidCredentials,
             .googleTokenInvalid, .appleTokenInvalid, .verificationOTPInvalid,
             .refreshTokenInvalid, .passwordResetCodeInvalid,
             .mfaChallengeInvalid, .mfaCodeInvalid, .phoneVerificationCodeInvalid,
             .authenticatorAppSetupInvalid, .passkeyChallengeInvalid,
             .passkeyRegistrationInvalid, .passkeyAuthenticationInvalid,
             .passkeyCredentialNotFound:
            return .unauthorized
        case .emailAlreadyExists, .verificationEmailMismatch,
             .socialAccountAlreadyLinked, .passkeyCredentialAlreadyExists,
             .mfaConfigurationInvalid:
            return .conflict
        case .appleEmailMissing, .mfaRequiresVerifiedEmail:
            return .unprocessableEntity
        case .emailNotVerified:
            return .forbidden
        }
    }

    var reason: String {
        switch self {
        case .missingToken:           return "Missing authorization token"
        case .invalidToken:           return "Invalid or expired token"
        case .invalidCredentials:     return "Invalid email or password"
        case .emailAlreadyExists:     return "Email already registered"
        case .googleTokenInvalid:     return "Invalid or expired Google token"
        case .appleTokenInvalid:      return "Invalid or expired Apple token"
        case .verificationEmailMismatch:
            return "SSO account email must match the profile email"
        case .appleEmailMissing:
            return "Apple account does not expose an email for verification. Use email OTP instead."
        case .socialAccountAlreadyLinked:
            return "SSO account is already linked to another profile"
        case .verificationOTPInvalid:
            return "Verification code invalid or expired"
        case .refreshTokenInvalid:    return "Refresh token invalid or expired"
        case .passwordResetCodeInvalid:
            return "Password reset code invalid or expired"
        case .mfaChallengeInvalid:
            return "MFA challenge invalid or expired"
        case .mfaCodeInvalid:
            return "MFA code invalid or expired"
        case .mfaConfigurationInvalid:
            return "MFA is enabled but no primary MFA method is currently configured"
        case .mfaRequiresVerifiedEmail:
            return "MFA requires a verified email address"
        case .phoneVerificationCodeInvalid:
            return "Phone verification code invalid or expired"
        case .authenticatorAppSetupInvalid:
            return "Authenticator app setup is invalid or expired"
        case .passkeyChallengeInvalid:
            return "Passkey challenge invalid or expired"
        case .passkeyRegistrationInvalid:
            return "Passkey registration payload is invalid"
        case .passkeyAuthenticationInvalid:
            return "Passkey authentication payload is invalid"
        case .passkeyCredentialAlreadyExists:
            return "Passkey is already linked to an account"
        case .passkeyCredentialNotFound:
            return "Passkey credential not found"
        case .emailNotVerified:
            return "Email verification required before performing this action"
        }
    }

    var errorCode: String {
        switch self {
        case .missingToken:           return "MISSING_TOKEN"
        case .invalidToken:           return "INVALID_TOKEN"
        case .invalidCredentials:     return "INVALID_CREDENTIALS"
        case .emailAlreadyExists:     return "EMAIL_ALREADY_EXISTS"
        case .googleTokenInvalid:     return "GOOGLE_TOKEN_INVALID"
        case .appleTokenInvalid:      return "APPLE_TOKEN_INVALID"
        case .verificationEmailMismatch:
            return "VERIFICATION_EMAIL_MISMATCH"
        case .appleEmailMissing:      return "APPLE_EMAIL_MISSING"
        case .socialAccountAlreadyLinked:
            return "SOCIAL_ACCOUNT_ALREADY_LINKED"
        case .verificationOTPInvalid: return "VERIFICATION_OTP_INVALID"
        case .refreshTokenInvalid:    return "REFRESH_TOKEN_INVALID"
        case .passwordResetCodeInvalid: return "PASSWORD_RESET_CODE_INVALID"
        case .mfaChallengeInvalid: return "MFA_CHALLENGE_INVALID"
        case .mfaCodeInvalid: return "MFA_CODE_INVALID"
        case .mfaConfigurationInvalid: return "MFA_CONFIGURATION_INVALID"
        case .mfaRequiresVerifiedEmail: return "MFA_REQUIRES_VERIFIED_EMAIL"
        case .phoneVerificationCodeInvalid: return "PHONE_VERIFICATION_CODE_INVALID"
        case .authenticatorAppSetupInvalid: return "AUTHENTICATOR_APP_SETUP_INVALID"
        case .passkeyChallengeInvalid: return "PASSKEY_CHALLENGE_INVALID"
        case .passkeyRegistrationInvalid: return "PASSKEY_REGISTRATION_INVALID"
        case .passkeyAuthenticationInvalid: return "PASSKEY_AUTHENTICATION_INVALID"
        case .passkeyCredentialAlreadyExists: return "PASSKEY_CREDENTIAL_ALREADY_EXISTS"
        case .passkeyCredentialNotFound: return "PASSKEY_CREDENTIAL_NOT_FOUND"
        case .emailNotVerified: return "EMAIL_NOT_VERIFIED"
        }
    }
}
