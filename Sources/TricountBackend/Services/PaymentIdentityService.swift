import Fluent
import Vapor

struct PaymentIdentityService {
    let req: Request

    func setOrUpdate(userID: UUID, _ input: UpdatePaymentIdentityRequest) async throws -> UserPaymentIdentity {
        let upi = Self.sanitize(input.upiId)
        let qr = Self.sanitize(input.qrUrl)

        guard upi != nil || qr != nil else {
            throw Abort(.badRequest, reason: "At least one of upi_id or qr_url is required")
        }

        let identity: UserPaymentIdentity
        if let existing = try await UserPaymentIdentity.find(userID, on: req.db) {
            identity = existing
        } else {
            identity = UserPaymentIdentity(userID: userID)
        }

        if let upi { identity.upiId = upi }
        if let qr { identity.qrUrl = qr }

        try await identity.save(on: req.db)
        return identity
    }

    private static func sanitize(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func get(userID: UUID) async throws -> UserPaymentIdentity {
        guard let identity = try await UserPaymentIdentity.find(userID, on: req.db) else {
            throw Abort(.notFound, reason: "Payment identity not found")
        }
        return identity
    }

    func delete(userID: UUID) async throws {
        let identity = try await get(userID: userID)
        try await identity.delete(on: req.db)
    }
}
