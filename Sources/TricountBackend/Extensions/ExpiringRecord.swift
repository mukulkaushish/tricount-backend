import Fluent
import Foundation

/// Shared protocol for models with `expiresAt` and `isUsed` fields.
/// Each conforming model declares its own `lifetime` — the single source of truth
/// for how long that record type stays valid.
protocol ExpiringRecord: Model {
    var expiresAt: Date { get set }
    var isUsed: Bool { get set }

    /// How long this record is valid from creation. Defined per model.
    static var lifetime: OTPLifetime { get }
}

extension ExpiringRecord {
    var isExpired: Bool { expiresAt < Date() }
    var isValid: Bool { !isUsed && !isExpired }

    /// Convenience: expiration date from now using the model's declared lifetime.
    static var expirationFromNow: Date {
        Date().addingTimeInterval(lifetime.interval)
    }
}
