import JWT
import Vapor

struct UserJWTPayload: JWTPayload, Authenticatable {
    enum CodingKeys: String, CodingKey {
        case subject = "sub"
        case expiration = "exp"
        case issuedAt = "iat"
        case userId = "uid"
    }

    /// Subject — mirrors the user UUID
    var subject: SubjectClaim

    /// Token expiry (1 hour from issuance)
    var expiration: ExpirationClaim

    var issuedAt: IssuedAtClaim

    /// User UUID string — redundant with `sub` but explicit for clarity
    var userId: String

    func verify(using signer: JWTSigner) throws {
        try expiration.verifyNotExpired()
    }
}

extension Request {
    /// Convenience: decoded JWT payload after `JWTAuthMiddleware` runs.
    var jwtPayload: UserJWTPayload {
        get throws { try self.jwt.verify(as: UserJWTPayload.self) }
    }
}
