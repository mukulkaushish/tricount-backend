import Vapor
import JWT

extension Application {
    func configureJWT() {
        let jwtSecret = Environment.get("JWT_SECRET") ?? "change-me-in-production-use-env-var"
        jwt.signers.use(.hs256(key: jwtSecret))
    }
}
