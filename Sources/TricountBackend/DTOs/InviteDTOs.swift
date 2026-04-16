import Vapor

// MARK: - Singleton Group Invite (admin-facing)
struct GroupInviteResponse: Content {
    let id: UUID
    let groupId: UUID
    let inviteToken: String
    let invitedBy: UUID
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case groupId = "group_id"
        case inviteToken = "invite_token"
        case invitedBy = "invited_by"
        case createdAt = "created_at"
    }
}

// MARK: - Public Invite Preview (by token)
struct InvitePreviewResponse: Content {
    let inviteToken: String
    let group: GroupBasicInfo
    let invitedBy: UserBasicInfo

    enum CodingKeys: String, CodingKey {
        case inviteToken = "invite_token"
        case group
        case invitedBy = "invited_by"
    }
}

// MARK: - Accept Invite
struct AcceptInviteRequest: Content {
    let inviteToken: String

    enum CodingKeys: String, CodingKey {
        case inviteToken = "invite_token"
    }
}

struct AcceptInviteResponse: Content {
    let groupId: UUID
    let status: String
    let message: String

    enum CodingKeys: String, CodingKey {
        case groupId = "group_id"
        case status, message
    }
}

// MARK: - Group Basic Info (shared)
struct GroupBasicInfo: Content {
    let id: UUID
    let name: String
    let iconUrl: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case iconUrl = "icon_url"
    }
}
