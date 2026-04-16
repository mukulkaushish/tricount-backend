import Vapor
import Fluent

struct PaymentIdentityController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let identity = routes
            .grouped("payment-identity")
            .grouped(JWTAuthMiddleware())
            .grouped(VerifiedUserMiddleware())
            .grouped(IdempotencyMiddleware())

        identity.post(use: setPaymentIdentity)
            .documented(auth: .bearer, response: .raw(PaymentIdentityResponse.self), requestBody: .json(UpdatePaymentIdentityRequest.self))
        identity.get(use: getPaymentIdentity)
            .documented(auth: .bearer, response: .raw(PaymentIdentityResponse.self))
        identity.delete(use: deletePaymentIdentity)
            .documented(auth: .bearer, response: .empty())
    }

    func setPaymentIdentity(req: Request) async throws -> PaymentIdentityResponse {
        let userID = try req.authenticatedUserID
        let input = try req.content.decode(UpdatePaymentIdentityRequest.self)
        let identity = try await req.services.paymentIdentity.setOrUpdate(userID: userID, input)
        return try identity.toResponse()
    }

    func getPaymentIdentity(req: Request) async throws -> PaymentIdentityResponse {
        let userID = try req.authenticatedUserID
        let identity = try await req.services.paymentIdentity.get(userID: userID)
        return try identity.toResponse()
    }

    func deletePaymentIdentity(req: Request) async throws -> HTTPStatus {
        let userID = try req.authenticatedUserID
        try await req.services.paymentIdentity.delete(userID: userID)
        return .ok
    }
}
