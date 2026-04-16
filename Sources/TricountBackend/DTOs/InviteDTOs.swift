import Vapor

// MARK: - Create Invite
struct CreateInviteRequest: Content {
    let inviteeContact: String

    enum CodingKeys: String, CodingKey {
        case inviteeContact = "invitee_contact"
    }
}

struct CreateInviteResponse: Content {
    let id: UUID
    let groupId: UUID
    let inviteeContact: String
    let inviteToken: String
    let status: String
    let expiresAt: Date
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case groupId = "group_id"
        case inviteeContact = "invitee_contact"
        case inviteToken = "invite_token"
        case status
        case expiresAt = "expires_at"
        case createdAt = "created_at"
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

// MARK: - List Invites
struct InviteListResponse: Content {
    let id: UUID
    let group: GroupBasicInfo
    let invitedBy: UserBasicInfo
    let inviteeContact: String
    let status: String
    let expiresAt: Date
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, group
        case invitedBy = "invited_by"
        case inviteeContact = "invitee_contact"
        case status
        case expiresAt = "expires_at"
        case createdAt = "created_at"
    }
}

struct ListInvitesResponse: Content {
    let invites: [InviteListResponse]
    let total: Int
}

// MARK: - Group Basic Info
struct GroupBasicInfo: Content {
    let id: UUID
    let name: String
    let iconUrl: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case iconUrl = "icon_url"
    }
}
