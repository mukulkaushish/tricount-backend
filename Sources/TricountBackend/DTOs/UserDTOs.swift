import Vapor

struct UserStatusResponse: Content {
    let exists: Bool
    let isVerified: Bool
    let isPlaceholder: Bool
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case exists
        case isVerified = "is_verified"
        case isPlaceholder = "is_placeholder"
        case displayName = "display_name"
    }
}
