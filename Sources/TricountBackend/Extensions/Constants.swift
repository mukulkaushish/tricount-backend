import Foundation

/// Centralized token lifetime constants.
enum TokenLifetime {
    static let accessToken: TimeInterval = 3600              // 1 hour
    static let refreshToken: TimeInterval = 30 * 24 * 3600   // 30 days
}

/// Preset durations for OTPs and challenges.
/// Each `ExpiringRecord` model declares which preset it uses via `static var lifetime`.
enum OTPLifetime: TimeInterval, Sendable {
    case fiveMinutes    = 300
    case tenMinutes     = 600
    case fifteenMinutes = 900
    case thirtyMinutes  = 1800
    case oneHour        = 3600

    var interval: TimeInterval { rawValue }
}

enum PasswordPolicy {
    static let minLength = 8
    static let maxLength = 128
}

enum DisplayNamePolicy {
    static let minLength = 2
    static let maxLength = 64
}
