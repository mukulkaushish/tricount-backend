import Vapor
import Fluent

struct PaymentIdentityController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let identity = routes.grouped("payment-identity")

        identity.post(use: setPaymentIdentity)
        identity.get(use: getPaymentIdentity)
        identity.delete(use: deletePaymentIdentity)
    }

    func setPaymentIdentity(req: Request) async throws -> PaymentIdentityResponse {
        let payload = try req.auth.require(UserJWTPayload.self)
        let input = try req.content.decode(UpdatePaymentIdentityRequest.self)

        let identity = try await PaymentIdentityService.setOrUpdatePaymentIdentity(req, userID: UUID(uuidString: payload.userId)!, input)

        return PaymentIdentityResponse(
            userId: try identity.requireID(),
            upiId: identity.upiId,
            qrUrl: identity.qrUrl,
            updatedAt: identity.updatedAt ?? Date()
        )
    }

    func getPaymentIdentity(req: Request) async throws -> PaymentIdentityResponse {
        let payload = try req.auth.require(UserJWTPayload.self)

        let identity = try await PaymentIdentityService.getPaymentIdentity(req, userID: UUID(uuidString: payload.userId)!)

        return PaymentIdentityResponse(
            userId: try identity.requireID(),
            upiId: identity.upiId,
            qrUrl: identity.qrUrl,
            updatedAt: identity.updatedAt ?? Date()
        )
    }

    func deletePaymentIdentity(req: Request) async throws -> HTTPStatus {
        let payload = try req.auth.require(UserJWTPayload.self)

        try await PaymentIdentityService.deletePaymentIdentity(req, userID: UUID(uuidString: payload.userId)!)
        return .ok
    }
}
