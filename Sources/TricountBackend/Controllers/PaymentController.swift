import Vapor
import Fluent

struct PaymentController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let groups = routes.grouped("groups", ":id", "payments")

        groups.post(use: createPayment)
        groups.get(use: listPayments)
        groups.get(":paymentId", use: getPayment)
        groups.post(":paymentId", "reverse", use: reversePayment)
    }

    func createPayment(req: Request) async throws -> Response {
        let payload = try req.auth.require(UserJWTPayload.self)
        guard let groupID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid group ID")
        }

        let input = try req.content.decode(CreatePaymentRequest.self)
        let payment = try await PaymentService.createPayment(req, groupID: groupID, input, actorID: UUID(uuidString: payload.userId)!)

        guard let payer = try await User.find(try payment.$payer.id, on: req.db),
              let receiver = try await User.find(try payment.$receiver.id, on: req.db) else {
            throw Abort(.notFound, reason: "User not found")
        }

        let response = CreatePaymentResponse(
                id: try payment.requireID(),
            groupId: groupID,
                payer: UserBasicInfo(id: try payer.requireID(), displayName: payer.displayName, email: payer.email, avatarUrl: nil),
                receiver: UserBasicInfo(id: try receiver.requireID(), displayName: receiver.displayName, email: receiver.email, avatarUrl: nil),
            amount: payment.amount,
            createdAt: payment.createdAt ?? Date()
        )

        var httpResponse = Response(status: .created)
        try httpResponse.content.encode(response)
        return httpResponse
    }

    func listPayments(req: Request) async throws -> ListPaymentsResponse {
        let payload = try req.auth.require(UserJWTPayload.self)
        guard let groupID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid group ID")
        }

        try await GroupService.assertUserIsMember(req, groupID: groupID, userID: UUID(uuidString: payload.userId)!)

        let payments = try await PaymentService.listPayments(req, groupID: groupID)
        var responses: [PaymentListResponse] = []

        for payment in payments {
            guard let payer = try await User.find(try payment.$payer.id, on: req.db),
                  let receiver = try await User.find(try payment.$receiver.id, on: req.db) else {
                throw Abort(.notFound, reason: "User not found")
            }

            responses.append(PaymentListResponse(
                id: try payment.requireID(),
                payer: UserBasicInfo(id: try payer.requireID(), displayName: payer.displayName, email: payer.email, avatarUrl: nil),
                receiver: UserBasicInfo(id: try receiver.requireID(), displayName: receiver.displayName, email: receiver.email, avatarUrl: nil),
                amount: payment.amount,
                createdAt: payment.createdAt ?? Date()
            ))
        }

        return ListPaymentsResponse(payments: responses, total: responses.count)
    }

    func getPayment(req: Request) async throws -> PaymentDetailsResponse {
        let payload = try req.auth.require(UserJWTPayload.self)
        guard let groupID = req.parameters.get("id", as: UUID.self),
              let paymentID = req.parameters.get("paymentId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid parameters")
        }

        try await GroupService.assertUserIsMember(req, groupID: groupID, userID: UUID(uuidString: payload.userId)!)

        let payment = try await PaymentService.getPayment(req, paymentID: paymentID)

        guard let payer = try await User.find(try payment.$payer.id, on: req.db),
              let receiver = try await User.find(try payment.$receiver.id, on: req.db) else {
            throw Abort(.notFound, reason: "User not found")
        }

        return PaymentDetailsResponse(
                id: try payment.requireID(),
            groupId: groupID,
                payer: UserBasicInfo(id: try payer.requireID(), displayName: payer.displayName, email: payer.email, avatarUrl: nil),
                receiver: UserBasicInfo(id: try receiver.requireID(), displayName: receiver.displayName, email: receiver.email, avatarUrl: nil),
            amount: payment.amount,
            createdAt: payment.createdAt ?? Date(),
            reversedAt: payment.reversedAt
        )
    }

    func reversePayment(req: Request) async throws -> PaymentDetailsResponse {
        let payload = try req.auth.require(UserJWTPayload.self)
        guard let groupID = req.parameters.get("id", as: UUID.self),
              let paymentID = req.parameters.get("paymentId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid parameters")
        }

        try await GroupService.assertUserIsMember(req, groupID: groupID, userID: UUID(uuidString: payload.userId)!)

        let payment = try await PaymentService.reversePayment(req, paymentID: paymentID, actorID: UUID(uuidString: payload.userId)!)

        guard let payer = try await User.find(try payment.$payer.id, on: req.db),
              let receiver = try await User.find(try payment.$receiver.id, on: req.db) else {
            throw Abort(.notFound, reason: "User not found")
        }

        return PaymentDetailsResponse(
                id: try payment.requireID(),
            groupId: groupID,
                payer: UserBasicInfo(id: try payer.requireID(), displayName: payer.displayName, email: payer.email, avatarUrl: nil),
                receiver: UserBasicInfo(id: try receiver.requireID(), displayName: receiver.displayName, email: receiver.email, avatarUrl: nil),
            amount: payment.amount,
            createdAt: payment.createdAt ?? Date(),
            reversedAt: payment.reversedAt
        )
    }
}
