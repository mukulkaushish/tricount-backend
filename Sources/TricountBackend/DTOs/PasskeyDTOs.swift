import Foundation
import Vapor

struct PasskeyAuthenticationOptionsRequest: Content {
    let email: String?
}

struct PasskeyRegistrationOptionsResponse: Content {
    let challenge: String
    let rp: PasskeyRelyingPartyDTO
    let user: PasskeyUserIdentityDTO
    let pubKeyCredParams: [PasskeyCredentialParameterDTO]
    let timeout: Int
    let attestation: String
    let authenticatorSelection: PasskeyAuthenticatorSelectionDTO
    let excludeCredentials: [PasskeyCredentialDescriptorDTO]
}

struct PasskeyAuthenticationOptionsResponse: Content {
    let challenge: String
    let rpId: String
    let timeout: Int
    let userVerification: String
    let allowCredentials: [PasskeyCredentialDescriptorDTO]
}

struct PasskeyRegistrationVerificationRequest: Content {
    let id: String
    let rawId: String
    let type: String
    let response: PasskeyRegistrationCredentialResponseDTO
}

struct PasskeyAuthenticationVerificationRequest: Content {
    let id: String
    let rawId: String
    let type: String
    let response: PasskeyAuthenticationCredentialResponseDTO
}

struct RemovePasskeyRequest: Content {
    let credentialId: String
}

struct PasskeyCredentialDTO: Content {
    let id: String
    let credentialId: String
    let transports: [String]
    let createdAt: String
    let lastUsedAt: String?

    init(from credential: PasskeyCredential) {
        let formatter = ISO8601DateFormatter()
        self.id = credential.id?.uuidString ?? ""
        self.credentialId = credential.credentialId
        self.transports = credential.transports
        self.createdAt = formatter.string(from: credential.createdAt ?? Date())
        self.lastUsedAt = credential.lastUsedAt.map(formatter.string(from:))
    }
}

struct PasskeyRelyingPartyDTO: Content {
    let id: String
    let name: String
}

struct PasskeyUserIdentityDTO: Content {
    let id: String
    let name: String
    let displayName: String
}

struct PasskeyCredentialParameterDTO: Content {
    let type: String
    let alg: Int
}

struct PasskeyAuthenticatorSelectionDTO: Content {
    let residentKey: String
    let userVerification: String
}

struct PasskeyCredentialDescriptorDTO: Content {
    let type: String
    let id: String
    let transports: [String]
}

struct PasskeyRegistrationCredentialResponseDTO: Content {
    let clientDataJSON: String
    let attestationObject: String
    let transports: [String]?
}

struct PasskeyAuthenticationCredentialResponseDTO: Content {
    let clientDataJSON: String
    let authenticatorData: String
    let signature: String
    let userHandle: String?
}
