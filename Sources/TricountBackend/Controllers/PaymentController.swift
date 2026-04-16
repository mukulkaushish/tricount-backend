import Vapor
import Fluent

struct PaymentController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let payments = routes
            .grouped("groups", ":id")
            .grouped(JWTAuthMiddleware())
            .grouped(GroupMemberMiddleware())
            .grouped("payments")

        payments.post(use: createPayment)
        payments.get(use: listPayments)
        payments.get(":paymentId", use: getPayment)
        payments.post(":paymentId", "reverse", use: reversePayment)
    }

    func createPayment(req: Request) async throws -> Response {
        let ctx = try req.groupContext

        let input = try req.content.decode(CreatePaymentRequest.self)
        let payment = try await req.services.payments.create(groupID: ctx.groupID, input, actorID: ctx.userID)

        let payer = try await User.requireFind(payment.$payer.id, on: req.db)
        let receiver = try await User.requireFind(payment.$receiver.id, on: req.db)

        let response = CreatePaymentResponse(
            id: try payment.requireID(),
            groupId: ctx.groupID,
            payer: try payer.toBasicInfo(),
            receiver: try receiver.toBasicInfo(),
            amount: payment.amount,
            createdAt: payment.createdAt ?? Date()
        )

        var httpResponse = Response(status: .created)
        try httpResponse.content.encode(response)
        return httpResponse
    }

    func listPayments(req: Request) async throws -> ListPaymentsResponse {
        let ctx = try req.groupContext

        let payments = try await req.services.payments.list(groupID: ctx.groupID)
        var responses: [PaymentListResponse] = []

        for payment in payments {
            let payer = try await User.requireFind(payment.$payer.id, on: req.db)
            let receiver = try await User.requireFind(payment.$receiver.id, on: req.db)

            responses.append(PaymentListResponse(
                id: try payment.requireID(),
                payer: try payer.toBasicInfo(),
                receiver: try receiver.toBasicInfo(),
                amount: payment.amount,
                createdAt: payment.createdAt ?? Date()
            ))
        }

        return ListPaymentsResponse(payments: responses, total: responses.count)
    }

    func getPayment(req: Request) async throws -> PaymentDetailsResponse {
        let ctx = try req.groupContext
        let paymentID = try req.requireUUIDParameter("paymentId")
        let payment = try await req.services.payments.get(paymentID: paymentID)
        return try await buildDetailsResponse(req, payment: payment, groupID: ctx.groupID)
    }

    func reversePayment(req: Request) async throws -> PaymentDetailsResponse {
        let ctx = try req.groupContext
        let paymentID = try req.requireUUIDParameter("paymentId")
        let payment = try await req.services.payments.reverse(paymentID: paymentID, actorID: ctx.userID)
        return try await buildDetailsResponse(req, payment: payment, groupID: ctx.groupID)
    }

    // MARK: - Private Helpers

    private func buildDetailsResponse(_ req: Request, payment: Payment, groupID: UUID) async throws -> PaymentDetailsResponse {
        let payer = try await User.requireFind(payment.$payer.id, on: req.db)
        let receiver = try await User.requireFind(payment.$receiver.id, on: req.db)

        return PaymentDetailsResponse(
            id: try payment.requireID(),
            groupId: groupID,
            payer: try payer.toBasicInfo(),
            receiver: try receiver.toBasicInfo(),
            amount: payment.amount,
            createdAt: payment.createdAt ?? Date(),
            reversedAt: payment.reversedAt
        )
    }
}
