import Fluent
import Vapor
import JWT
import Crypto
import Foundation

enum SocialAuthProvider: String, Sendable {
    case google
    case apple
}

struct SocialIdentityProfile: Sendable {
    let provider: SocialAuthProvider
    let subject: String
    let email: String?
    let displayName: String
    let avatarUrl: String?

    var normalizedEmail: String? {
        email.map(AuthValidation.normalizeEmail)
    }

    var canRefreshPrimaryProfile: Bool {
        provider == .google || normalizedEmail != nil
    }
}

struct AuthService {
    let req: Request
    static let backupCodeCount = 10
}

extension AuthService {
    // MARK: - Shared dependencies

    var passkeyService: PasskeyService {
        PasskeyService(req: req)
    }

    func currentUser() async throws -> User {
        guard let user = try await User.find(req.authenticatedUserID, on: req.db)
        else {
            throw AuthError.invalidToken
        }
        return user
    }

    func requireUserID(from user: User) throws -> UUID {
        guard let userId = user.id else {
            throw Abort(.internalServerError)
        }

        return userId
    }

    func configuredTOTPIssuer() -> String {
        req.application.runtimeConfiguration.auth.totpIssuer
    }

    // MARK: - Shared security helpers

    func generateSecureToken() -> String {
        let key = SymmetricKey(size: .bits256)
        return key.withUnsafeBytes { Base64URL.encode(Data(Array($0))) }
    }

    func generateOTPCode() -> String {
        let value = Int.random(in: 0...999_999)
        return String(format: "%06d", value)
    }

    func generateBackupCode() -> String {
        let key = SymmetricKey(size: .bits256)
        let hex = key.withUnsafeBytes { bytes in
            Data(bytes.prefix(4)).map { String(format: "%02X", $0) }.joined()
        }
        let prefix = hex.prefix(4)
        let suffix = hex.suffix(4)
        return "\(prefix)-\(suffix)"
    }

    func sha256(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }

    func normalizeSixDigitCode(_ code: String, reason: String) throws -> String {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count == 6, normalized.allSatisfy(\.isNumber) else {
            throw Abort(.badRequest, reason: reason)
        }

        return normalized
    }

    func normalizeBackupCode(_ code: String) throws -> String {
        let normalized = code
            .uppercased()
            .filter { $0.isLetter || $0.isNumber }

        guard normalized.count == 8 else {
            throw Abort(.badRequest, reason: "Backup code must be 8 characters")
        }

        return normalized
    }

    // MARK: - Shared formatting helpers

    func maskedEmail(_ email: String) -> String {
        let parts = email.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return email }

        let local = parts[0]
        let prefix = local.prefix(1)
        return "\(prefix)***@\(parts[1])"
    }

    func maskedPhoneNumber(_ phoneNumber: String) -> String {
        let visiblePrefix = phoneNumber.prefix(2)
        let visibleSuffix = phoneNumber.suffix(2)
        let maskedCount = max(0, phoneNumber.count - 4)
        return "\(visiblePrefix)\(String(repeating: "*", count: maskedCount))\(visibleSuffix)"
    }

    // MARK: - Validation

    func validatePassword(_ password: String) throws {
        guard password.count >= PasswordPolicy.minLength else {
            throw Abort(.badRequest, reason: "Password must be at least \(PasswordPolicy.minLength) characters")
        }
        guard password.count <= PasswordPolicy.maxLength else {
            throw Abort(.badRequest, reason: "Password must not exceed \(PasswordPolicy.maxLength) characters")
        }
        guard password.contains(where: { $0.isUppercase }) else {
            throw Abort(.badRequest, reason: "Password must contain at least one uppercase letter")
        }
        guard password.contains(where: { $0.isLowercase }) else {
            throw Abort(.badRequest, reason: "Password must contain at least one lowercase letter")
        }
        guard password.contains(where: { $0.isNumber }) else {
            throw Abort(.badRequest, reason: "Password must contain at least one digit")
        }
    }

    func validateDisplayName(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= DisplayNamePolicy.minLength && trimmed.count <= DisplayNamePolicy.maxLength else {
            throw Abort(.badRequest, reason: "Display name must be \(DisplayNamePolicy.minLength)–\(DisplayNamePolicy.maxLength) characters")
        }
    }
}
