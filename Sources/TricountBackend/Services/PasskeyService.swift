import Crypto
import Fluent
import Foundation
import Vapor

struct PasskeyService {
    let req: Request

    func beginRegistration(for user: User) async throws -> PasskeyRegistrationOptionsResponse {
        let config = try configuration()
        let userId = try requireUserID(from: user)

        try await expireActiveChallenges(for: userId, flow: .registration)

        let challenge = generateChallenge()
        let challengeRecord = PasskeyChallenge(
            userId: userId,
            flow: .registration,
            challenge: challenge,
            rpId: config.rpId,
            expiresAt: Date().addingTimeInterval(config.challengeLifetime)
        )
        try await challengeRecord.save(on: req.db)

        let existingCredentials = try await PasskeyCredential.query(on: req.db)
            .filter(\.$user.$id == userId)
            .all()

        return PasskeyRegistrationOptionsResponse(
            challenge: challenge,
            rp: PasskeyRelyingPartyDTO(id: config.rpId, name: config.rpName),
            user: PasskeyUserIdentityDTO(
                id: Base64URL.encode(userId.rawBytes),
                name: user.email,
                displayName: user.displayName
            ),
            pubKeyCredParams: [
                PasskeyCredentialParameterDTO(type: "public-key", alg: -7)
            ],
            timeout: config.timeoutMilliseconds,
            attestation: "none",
            authenticatorSelection: PasskeyAuthenticatorSelectionDTO(
                residentKey: "required",
                userVerification: "required"
            ),
            excludeCredentials: existingCredentials.map {
                PasskeyCredentialDescriptorDTO(
                    type: "public-key",
                    id: $0.credentialId,
                    transports: $0.transports
                )
            }
        )
    }

    func finishRegistration(
        _ registration: PasskeyRegistrationVerificationRequest,
        for user: User
    ) async throws -> PasskeyCredential {
        guard registration.type == "public-key" else {
            throw Abort(.badRequest, reason: "Passkey registration type must be public-key")
        }

        let config = try configuration()
        let userId = try requireUserID(from: user)
        let clientData = try parseClientData(
            registration.response.clientDataJSON,
            expectedType: "webauthn.create",
            config: config
        )

        guard let challenge = try await activeChallenge(
            challenge: clientData.challenge,
            flow: .registration
        ) else {
            throw AuthError.passkeyChallengeInvalid
        }

        guard challenge.$user.id == userId else {
            throw AuthError.passkeyChallengeInvalid
        }

        let attestationObject = try Base64URL.decode(
            registration.response.attestationObject,
            fieldName: "attestationObject"
        )
        var attestationDecoder = try PasskeyCBORDecoder(data: attestationObject)
        let attestation = try attestationDecoder.decode()

        guard case .map(let topLevel) = attestation,
              let authDataValue = topLevel["authData"],
              case .byteString(let authData) = authDataValue else {
            throw AuthError.passkeyRegistrationInvalid
        }

        let attestedCredential = try parseAttestedCredential(authData, rpId: config.rpId)
        try validateCredentialIdentifiers(
            id: registration.id,
            rawId: registration.rawId,
            expectedCredentialID: attestedCredential.credentialId
        )

        try await ensureCredentialIsAvailable(attestedCredential.credentialId)

        challenge.usedAt = Date()
        try await challenge.save(on: req.db)

        let credential = PasskeyCredential(
            userId: userId,
            credentialId: attestedCredential.credentialId,
            publicKey: attestedCredential.publicKey,
            signCount: attestedCredential.signCount,
            aaguid: attestedCredential.aaguid,
            transports: registration.response.transports ?? []
        )
        try await credential.save(on: req.db)

        return credential
    }

    func beginAuthentication(
        emailHint: String?
    ) async throws -> PasskeyAuthenticationOptionsResponse {
        let config = try configuration()

        let normalizedEmail: String?
        if let emailHint {
            let trimmed = emailHint.trimmingCharacters(in: .whitespacesAndNewlines)
            normalizedEmail = trimmed.isEmpty ? nil : AuthValidation.normalizeEmail(trimmed)
        } else {
            normalizedEmail = nil
        }

        let hintedUser = try await findUser(for: normalizedEmail)
        let allowCredentials: [PasskeyCredentialDescriptorDTO]
        if let userId = hintedUser?.id {
            allowCredentials = try await PasskeyCredential.query(on: req.db)
                .filter(\.$user.$id == userId)
                .all()
                .map {
                    PasskeyCredentialDescriptorDTO(
                        type: "public-key",
                        id: $0.credentialId,
                        transports: $0.transports
                    )
                }
        } else {
            allowCredentials = []
        }

        let challenge = generateChallenge()
        let challengeRecord = PasskeyChallenge(
            userId: hintedUser?.id,
            flow: .authentication,
            challenge: challenge,
            rpId: config.rpId,
            expiresAt: Date().addingTimeInterval(config.challengeLifetime)
        )
        try await challengeRecord.save(on: req.db)

        return PasskeyAuthenticationOptionsResponse(
            challenge: challenge,
            rpId: config.rpId,
            timeout: config.timeoutMilliseconds,
            userVerification: "required",
            allowCredentials: allowCredentials
        )
    }

    func finishAuthentication(
        _ authentication: PasskeyAuthenticationVerificationRequest
    ) async throws -> User {
        guard authentication.type == "public-key" else {
            throw Abort(.badRequest, reason: "Passkey authentication type must be public-key")
        }

        let config = try configuration()
        let clientData = try parseClientData(
            authentication.response.clientDataJSON,
            expectedType: "webauthn.get",
            config: config
        )

        guard let challenge = try await activeChallenge(
            challenge: clientData.challenge,
            flow: .authentication
        ) else {
            throw AuthError.passkeyChallengeInvalid
        }

        let credentialId = try resolveCredentialIdentifier(
            id: authentication.id,
            rawId: authentication.rawId
        )

        guard let credential = try await PasskeyCredential.query(on: req.db)
            .filter(\.$credentialId == credentialId)
            .with(\.$user)
            .first() else {
            throw AuthError.passkeyCredentialNotFound
        }

        if let expectedUserId = challenge.$user.id, credential.$user.id != expectedUserId {
            throw AuthError.passkeyCredentialNotFound
        }

        let authenticatorData = try Base64URL.decode(
            authentication.response.authenticatorData,
            fieldName: "authenticatorData"
        )
        let signature = try Base64URL.decode(
            authentication.response.signature,
            fieldName: "signature"
        )

        let assertion = try parseAssertion(authenticatorData, rpId: config.rpId)
        try verifyUserHandle(authentication.response.userHandle, for: credential.$user.id)
        try verifyAssertionSignature(
            clientDataJSONBase64URL: authentication.response.clientDataJSON,
            authenticatorData: authenticatorData,
            signature: signature,
            publicKey: credential.publicKey
        )

        if credential.signCount > 0 && assertion.signCount > 0 && assertion.signCount <= credential.signCount {
            throw AuthError.passkeyAuthenticationInvalid
        }

        credential.signCount = max(credential.signCount, assertion.signCount)
        credential.lastUsedAt = Date()
        try await credential.save(on: req.db)

        challenge.usedAt = Date()
        try await challenge.save(on: req.db)

        return credential.user
    }

    private func configuration() throws -> PasskeyConfiguration {
        let runtimeConfig = req.application.runtimeConfiguration.passkeys

        return PasskeyConfiguration(
            rpId: runtimeConfig.rpId,
            rpName: runtimeConfig.rpName,
            allowedOrigins: runtimeConfig.allowedOrigins,
            timeoutMilliseconds: runtimeConfig.timeoutMilliseconds,
            challengeLifetime: runtimeConfig.challengeLifetime
        )
    }

    private func findUser(for normalizedEmail: String?) async throws -> User? {
        guard let normalizedEmail else {
            return nil
        }

        return try await User.query(on: req.db)
            .filter(\.$email == normalizedEmail)
            .first()
    }

    private func parseClientData(
        _ clientDataJSONBase64URL: String,
        expectedType: String,
        config: PasskeyConfiguration
    ) throws -> PasskeyClientData {
        let clientDataJSON = try Base64URL.decode(clientDataJSONBase64URL, fieldName: "clientDataJSON")
        let clientData = try JSONDecoder().decode(PasskeyClientData.self, from: clientDataJSON)

        guard clientData.type == expectedType else {
            throw AuthError.passkeyChallengeInvalid
        }

        guard !clientData.challenge.isEmpty else {
            throw AuthError.passkeyChallengeInvalid
        }

        try validateOrigin(clientData.origin, config: config)
        return clientData
    }

    private func validateOrigin(_ origin: String, config: PasskeyConfiguration) throws {
        if !config.allowedOrigins.isEmpty {
            guard config.allowedOrigins.contains(origin) else {
                throw AuthError.passkeyChallengeInvalid
            }
            return
        }

        guard let url = URL(string: origin),
              let host = url.host else {
            if req.isProductionEnvironment {
                throw AuthError.passkeyChallengeInvalid
            }
            return
        }

        let normalizedHost = host.lowercased()
        let normalizedRpId = config.rpId.lowercased()
        guard normalizedHost == normalizedRpId || normalizedHost.hasSuffix(".\(normalizedRpId)") else {
            throw AuthError.passkeyChallengeInvalid
        }
    }

    private func activeChallenge(
        challenge: String,
        flow: PasskeyChallenge.Flow
    ) async throws -> PasskeyChallenge? {
        guard let record = try await PasskeyChallenge.query(on: req.db)
            .filter(\.$challenge == challenge)
            .filter(\.$flowRawValue == flow.rawValue)
            .sort(\.$createdAt, .descending)
            .first(),
              record.isValid
        else {
            return nil
        }

        return record
    }

    private func expireActiveChallenges(for userId: UUID, flow: PasskeyChallenge.Flow) async throws {
        try await PasskeyChallenge.query(on: req.db)
            .filter(\.$user.$id == userId)
            .filter(\.$flowRawValue == flow.rawValue)
            .filter(\.$usedAt == nil)
            .set(\.$usedAt, to: Date())
            .update()
    }

    private func parseAttestedCredential(_ authData: Data, rpId: String) throws -> PasskeyAttestedCredential {
        var reader = ByteReader(data: authData)
        let rpIdHash = try reader.readData(count: 32)
        let flags = PasskeyFlags(rawValue: try reader.readUInt8())
        let signCount = Int(try reader.readUInt32())

        guard rpIdHash == expectedRpIdHash(for: rpId) else {
            throw AuthError.passkeyRegistrationInvalid
        }

        guard flags.contains(.userPresent),
              flags.contains(.userVerified),
              flags.contains(.attestedCredentialData) else {
            throw AuthError.passkeyRegistrationInvalid
        }

        let aaguidData = try reader.readData(count: 16)
        let credentialIdLength = Int(try reader.readUInt16())
        let credentialId = try reader.readData(count: credentialIdLength)
        let credentialPublicKeyData = try reader.readRemainingCBORObject()
        let credentialPublicKey = try parsePublicKey(from: credentialPublicKeyData)

        return PasskeyAttestedCredential(
            credentialId: Base64URL.encode(credentialId),
            publicKey: credentialPublicKey,
            signCount: signCount,
            aaguid: formatAAGUID(aaguidData)
        )
    }

    private func parseAssertion(_ authenticatorData: Data, rpId: String) throws -> PasskeyAssertion {
        var reader = ByteReader(data: authenticatorData)
        let rpIdHash = try reader.readData(count: 32)
        let flags = PasskeyFlags(rawValue: try reader.readUInt8())
        let signCount = Int(try reader.readUInt32())

        guard rpIdHash == expectedRpIdHash(for: rpId),
              flags.contains(.userPresent),
              flags.contains(.userVerified) else {
            throw AuthError.passkeyAuthenticationInvalid
        }

        return PasskeyAssertion(signCount: signCount)
    }

    private func parsePublicKey(from credentialPublicKeyData: Data) throws -> String {
        var decoder = try PasskeyCBORDecoder(data: credentialPublicKeyData)
        let cbor = try decoder.decode()
        guard case .map(let map) = cbor,
              map.intValue(for: 1) == 2,
              map.intValue(for: 3) == -7,
              map.intValue(for: -1) == 1,
              let x = map.byteString(for: -2),
              let y = map.byteString(for: -3),
              x.count == 32,
              y.count == 32 else {
            throw AuthError.passkeyRegistrationInvalid
        }

        var x963 = Data([0x04])
        x963.append(x)
        x963.append(y)
        return Base64URL.encode(x963)
    }

    private func validateCredentialIdentifiers(
        id: String,
        rawId: String,
        expectedCredentialID: String
    ) throws {
        let resolved = try resolveCredentialIdentifier(id: id, rawId: rawId)
        guard resolved == expectedCredentialID else {
            throw AuthError.passkeyRegistrationInvalid
        }
    }

    private func resolveCredentialIdentifier(id: String, rawId: String) throws -> String {
        let resolved = rawId.isEmpty ? id : rawId
        guard !resolved.isEmpty else {
            throw Abort(.badRequest, reason: "Passkey credential identifier is required")
        }

        let normalized = Base64URL.encode(try Base64URL.decode(resolved, fieldName: "rawId"))
        if !id.isEmpty {
            let normalizedID = Base64URL.encode(try Base64URL.decode(id, fieldName: "id"))
            guard normalizedID == normalized else {
                throw AuthError.passkeyChallengeInvalid
            }
        }

        return normalized
    }

    private func ensureCredentialIsAvailable(_ credentialId: String) async throws {
        let existing = try await PasskeyCredential.query(on: req.db)
            .filter(\.$credentialId == credentialId)
            .count()
        guard existing == 0 else {
            throw AuthError.passkeyCredentialAlreadyExists
        }
    }

    private func verifyUserHandle(_ userHandle: String?, for userId: UUID) throws {
        guard let userHandle, !userHandle.isEmpty else {
            return
        }

        let expected = Base64URL.encode(userId.rawBytes)
        let normalized = Base64URL.encode(try Base64URL.decode(userHandle, fieldName: "userHandle"))
        guard normalized == expected else {
            throw AuthError.passkeyAuthenticationInvalid
        }
    }

    private func verifyAssertionSignature(
        clientDataJSONBase64URL: String,
        authenticatorData: Data,
        signature: Data,
        publicKey: String
    ) throws {
        let clientDataJSON = try Base64URL.decode(clientDataJSONBase64URL, fieldName: "clientDataJSON")
        let clientDataHash = Data(SHA256.hash(data: clientDataJSON))
        var signedData = Data()
        signedData.append(authenticatorData)
        signedData.append(clientDataHash)

        let publicKeyData = try Base64URL.decode(publicKey, fieldName: "publicKey")
        let ecdsaSignature = try P256.Signing.ECDSASignature(derRepresentation: signature)
        let key = try P256.Signing.PublicKey(x963Representation: publicKeyData)

        guard key.isValidSignature(ecdsaSignature, for: signedData) else {
            throw AuthError.passkeyAuthenticationInvalid
        }
    }

    private func expectedRpIdHash(for rpId: String) -> Data {
        Data(SHA256.hash(data: Data(rpId.utf8)))
    }

    private func generateChallenge() -> String {
        let key = SymmetricKey(size: .bits256)
        return key.withUnsafeBytes { bytes in
            Base64URL.encode(Data(bytes))
        }
    }

    private func requireUserID(from user: User) throws -> UUID {
        guard let userId = user.id else {
            throw Abort(.internalServerError)
        }

        return userId
    }

    private func formatAAGUID(_ data: Data) -> String? {
        guard data.count == 16 else {
            return nil
        }

        let tuple = (
            data[0], data[1], data[2], data[3],
            data[4], data[5],
            data[6], data[7],
            data[8], data[9],
            data[10], data[11], data[12], data[13], data[14], data[15]
        )
        return UUID(uuid: tuple).uuidString.lowercased()
    }
}

private struct PasskeyConfiguration: Sendable {
    let rpId: String
    let rpName: String
    let allowedOrigins: Set<String>
    let timeoutMilliseconds: Int
    let challengeLifetime: TimeInterval
}

private struct PasskeyClientData: Decodable {
    let type: String
    let challenge: String
    let origin: String
}

private struct PasskeyAttestedCredential {
    let credentialId: String
    let publicKey: String
    let signCount: Int
    let aaguid: String?
}

private struct PasskeyAssertion {
    let signCount: Int
}

private struct ByteReader {
    private let data: Data
    private var offset = 0

    init(data: Data) {
        self.data = data
    }

    mutating func readUInt8() throws -> UInt8 {
        guard offset < data.count else {
            throw AuthError.passkeyChallengeInvalid
        }

        defer { offset += 1 }
        return data[offset]
    }

    mutating func readUInt16() throws -> UInt16 {
        let bytes = try readData(count: 2)
        return bytes.reduce(UInt16.zero) { ($0 << 8) | UInt16($1) }
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readData(count: 4)
        return bytes.reduce(UInt32.zero) { ($0 << 8) | UInt32($1) }
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else {
            throw AuthError.passkeyChallengeInvalid
        }

        let slice = data[offset ..< offset + count]
        offset += count
        return Data(slice)
    }

    mutating func readRemainingCBORObject() throws -> Data {
        let remaining = Data(data[offset...])
        var decoder = try PasskeyCBORDecoder(data: remaining)
        _ = try decoder.decode()
        let consumed = decoder.bytesConsumed
        guard consumed > 0, consumed <= remaining.count else {
            throw AuthError.passkeyRegistrationInvalid
        }

        offset += consumed
        return remaining.prefix(consumed)
    }
}

private struct PasskeyFlags: OptionSet {
    let rawValue: UInt8

    static let userPresent = PasskeyFlags(rawValue: 1 << 0)
    static let userVerified = PasskeyFlags(rawValue: 1 << 2)
    static let attestedCredentialData = PasskeyFlags(rawValue: 1 << 6)
}

enum PasskeyCBORValue: Equatable {
    case unsigned(UInt64)
    case negative(Int64)
    case byteString(Data)
    case textString(String)
    case array([PasskeyCBORValue])
    case map(PasskeyCBORMap)
    case boolean(Bool)
    case null
}

struct PasskeyCBORMap: Equatable {
    fileprivate var stringValues: [String: PasskeyCBORValue] = [:]
    fileprivate var intValues: [Int64: PasskeyCBORValue] = [:]

    subscript(_ key: String) -> PasskeyCBORValue? {
        stringValues[key]
    }

    func intValue(for key: Int64) -> Int64? {
        switch intValues[key] {
        case .unsigned(let value):
            return Int64(value)
        case .negative(let value):
            return value
        default:
            return nil
        }
    }

    func byteString(for key: Int64) -> Data? {
        guard case .byteString(let data) = intValues[key] else {
            return nil
        }

        return data
    }
}

struct PasskeyCBORDecoder {
    private let data: Data
    private var offset = 0

    init(data: Data) throws {
        self.data = data
    }

    var bytesConsumed: Int { offset }

    mutating func decode() throws -> PasskeyCBORValue {
        try decodeValue()
    }

    private mutating func decodeValue() throws -> PasskeyCBORValue {
        let initialByte = try readByte()
        let majorType = initialByte >> 5
        let additionalInfo = initialByte & 0x1f

        switch majorType {
        case 0:
            return .unsigned(try readLength(additionalInfo))
        case 1:
            return .negative(-1 - Int64(try readLength(additionalInfo)))
        case 2:
            return .byteString(try readData(length: Int(try readLength(additionalInfo))))
        case 3:
            let stringData = try readData(length: Int(try readLength(additionalInfo)))
            guard let string = String(data: stringData, encoding: .utf8) else {
                throw AuthError.passkeyRegistrationInvalid
            }
            return .textString(string)
        case 4:
            let count = Int(try readLength(additionalInfo))
            return .array(try (0..<count).map { _ in try decodeValue() })
        case 5:
            let count = Int(try readLength(additionalInfo))
            var map = PasskeyCBORMap()
            for _ in 0..<count {
                let key = try decodeValue()
                let value = try decodeValue()
                switch key {
                case .textString(let string):
                    map.stringValues[string] = value
                case .unsigned(let integer):
                    map.intValues[Int64(integer)] = value
                case .negative(let integer):
                    map.intValues[integer] = value
                default:
                    throw AuthError.passkeyRegistrationInvalid
                }
            }
            return .map(map)
        case 7:
            switch additionalInfo {
            case 20: return .boolean(false)
            case 21: return .boolean(true)
            case 22: return .null
            default:
                throw AuthError.passkeyRegistrationInvalid
            }
        default:
            throw AuthError.passkeyRegistrationInvalid
        }
    }

    private mutating func readLength(_ additionalInfo: UInt8) throws -> UInt64 {
        switch additionalInfo {
        case 0...23:
            return UInt64(additionalInfo)
        case 24:
            return UInt64(try readByte())
        case 25:
            return UInt64(try readUInt16())
        case 26:
            return UInt64(try readUInt32())
        case 27:
            return try readUInt64()
        default:
            throw AuthError.passkeyRegistrationInvalid
        }
    }

    private mutating func readByte() throws -> UInt8 {
        guard offset < data.count else {
            throw AuthError.passkeyRegistrationInvalid
        }

        defer { offset += 1 }
        return data[offset]
    }

    private mutating func readUInt16() throws -> UInt16 {
        let bytes = try readData(length: 2)
        return bytes.reduce(UInt16.zero) { ($0 << 8) | UInt16($1) }
    }

    private mutating func readUInt32() throws -> UInt32 {
        let bytes = try readData(length: 4)
        return bytes.reduce(UInt32.zero) { ($0 << 8) | UInt32($1) }
    }

    private mutating func readUInt64() throws -> UInt64 {
        let bytes = try readData(length: 8)
        return bytes.reduce(UInt64.zero) { ($0 << 8) | UInt64($1) }
    }

    private mutating func readData(length: Int) throws -> Data {
        guard length >= 0, offset + length <= data.count else {
            throw AuthError.passkeyRegistrationInvalid
        }

        let slice = data[offset ..< offset + length]
        offset += length
        return Data(slice)
    }
}
