import Vapor

// MARK: - Create Group
struct CreateGroupRequest: Content {
    let name: String
    let iconUrl: String?

    enum CodingKeys: String, CodingKey {
        case name
        case iconUrl = "icon_url"
    }
}

struct CreateGroupResponse: Content {
    let id: UUID
    let name: String
    let iconUrl: String?
    let createdBy: UUID
    let simplifyDebtsEnabled: Bool
    let allowMemberEdit: Bool
    let allowMemberDelete: Bool
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name
        case iconUrl = "icon_url"
        case createdBy = "created_by"
        case simplifyDebtsEnabled = "simplify_debts_enabled"
        case allowMemberEdit = "allow_member_edit"
        case allowMemberDelete = "allow_member_delete"
        case createdAt = "created_at"
    }
}

// MARK: - Get Group
struct GroupDetailsResponse: Content {
    let id: UUID
    let name: String
    let iconUrl: String?
    let createdBy: UserBasicInfo
    let simplifyDebtsEnabled: Bool
    let allowMemberEdit: Bool
    let allowMemberDelete: Bool
    let memberCount: Int
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name
        case iconUrl = "icon_url"
        case createdBy = "created_by"
        case simplifyDebtsEnabled = "simplify_debts_enabled"
        case allowMemberEdit = "allow_member_edit"
        case allowMemberDelete = "allow_member_delete"
        case memberCount = "member_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - Update Group
struct UpdateGroupRequest: Content {
    let name: String?
    let iconUrl: String?
    let simplifyDebtsEnabled: Bool?
    let allowMemberEdit: Bool?
    let allowMemberDelete: Bool?

    enum CodingKeys: String, CodingKey {
        case name
        case iconUrl = "icon_url"
        case simplifyDebtsEnabled = "simplify_debts_enabled"
        case allowMemberEdit = "allow_member_edit"
        case allowMemberDelete = "allow_member_delete"
    }
}

// MARK: - List Groups
struct GroupListResponse: Content {
    let id: UUID
    let name: String
    let iconUrl: String?
    let memberCount: Int
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name
        case iconUrl = "icon_url"
        case memberCount = "member_count"
        case createdAt = "created_at"
    }
}

struct ListGroupsResponse: Content {
    let groups: [GroupListResponse]
    let total: Int
}

// MARK: - Member Management
struct AddMemberRequest: Content {
    let userId: UUID
    let role: String?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case role
    }
}

struct GroupMemberResponse: Content {
    let id: UUID
    let user: UserBasicInfo
    let role: String
    let status: String
    let joinedAt: Date
    let leftAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, user, role, status
        case joinedAt = "joined_at"
        case leftAt = "left_at"
    }
}

struct ListMembersResponse: Content {
    let members: [GroupMemberResponse]
    let total: Int
}

struct UpdateMemberRequest: Content {
    let role: String?
}

// MARK: - User Basic Info
struct UserBasicInfo: Content {
    let id: UUID
    let displayName: String
    let email: String
    let avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case email
        case avatarUrl = "avatar_url"
    }
}
