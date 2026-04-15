import Vapor
import JWT

extension Application {
    func configureJWT() {
        jwt.signers.use(.hs256(key: runtimeConfiguration.auth.jwtSecret))
    }
}
