import Vapor
import Sodium

/// Argon2id password hasher via libsodium.
///
/// - All new passwords are hashed with Argon2id.
/// - CPU-intensive work is offloaded to NIO's blocking thread pool.
/// - No bcrypt support — this is a clean Argon2id-only implementation.
struct PasswordHasher: Sendable {

    private let app: Application

    init(app: Application) {
        self.app = app
    }

    // MARK: - Hash

    /// Hashes a password with Argon2id. Returns a PHC-format string.
    func hash(_ password: String, on eventLoop: any EventLoop) async throws -> String {
        try await app.threadPool.runIfActive(eventLoop: eventLoop) {
            let sodium = Sodium()
            let params = Self.params(for: self.app.environment)
            guard let hash = sodium.pwHash.str(
                passwd: Array(password.utf8),
                opsLimit: params.opsLimit,
                memLimit: params.memLimit
            ) else {
                throw Abort(.internalServerError, reason: "Password hashing failed")
            }
            return hash
        }.get()
    }

    // MARK: - Verify

    /// Verifies a password against a stored Argon2id hash.
    func verify(password: String, against storedHash: String, on eventLoop: any EventLoop) async throws -> Bool {
        try await app.threadPool.runIfActive(eventLoop: eventLoop) {
            let sodium = Sodium()
            return sodium.pwHash.strVerify(hash: storedHash, passwd: Array(password.utf8))
        }.get()
    }

    // MARK: - Configuration

    struct Params: Sendable {
        let opsLimit: Int
        let memLimit: Int
    }

    /// OWASP-recommended Argon2id parameters, tuned per environment.
    ///
    /// | Environment | opsLimit | memLimit | ~Time  |
    /// |-------------|----------|----------|--------|
    /// | Production  | 3 (Moderate)    | 256 MB (Moderate)    | ~50ms  |
    /// | Development | 2 (Interactive) | 64 MB (Interactive)  | ~30ms  |
    /// | Testing     | 1               | 8 KB                 | ~1ms   |
    ///
    /// Override with `ARGON2_OPS_LIMIT` and `ARGON2_MEM_LIMIT` env vars.
    /// Overrides must meet or exceed the environment's baseline.
    static func params(for environment: Environment) -> Params {
        let baseline = baselineParams(for: environment)

        if let ops = Environment.get("ARGON2_OPS_LIMIT").flatMap(Int.init),
           let mem = Environment.get("ARGON2_MEM_LIMIT").flatMap(Int.init),
           ops >= baseline.opsLimit, mem >= baseline.memLimit {
            return Params(opsLimit: ops, memLimit: mem)
        }

        return baseline
    }

    private static func baselineParams(for environment: Environment) -> Params {
        let sodium = Sodium()
        switch environment {
        case .testing:
            return Params(opsLimit: 1, memLimit: 8192)
        case .development:
            return Params(
                opsLimit: sodium.pwHash.OpsLimitInteractive,
                memLimit: sodium.pwHash.MemLimitInteractive
            )
        default:
            return Params(
                opsLimit: sodium.pwHash.OpsLimitModerate,
                memLimit: sodium.pwHash.MemLimitModerate
            )
        }
    }
}

// MARK: - Convenience extensions

extension Application {
    var passwordHasher: PasswordHasher {
        PasswordHasher(app: self)
    }
}

extension Request {
    var passwordHasher: PasswordHasher {
        PasswordHasher(app: application)
    }
}
