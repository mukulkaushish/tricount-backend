import Fluent
import Vapor

struct PaymentIdentityService {
    let req: Request

    func setOrUpdate(userID: UUID, _ input: UpdatePaymentIdentityRequest) async throws -> UserPaymentIdentity {
        let identity: UserPaymentIdentity

        if let existing = try await UserPaymentIdentity.find(userID, on: req.db) {
            identity = existing
        } else {
            identity = UserPaymentIdentity(userID: userID)
        }

        if let upiId = input.upiId {
            identity.upiId = upiId
        }
        if let qrUrl = input.qrUrl {
            identity.qrUrl = qrUrl
        }

        try await identity.save(on: req.db)
        return identity
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
