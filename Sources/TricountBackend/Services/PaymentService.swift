import Fluent
import Vapor

struct PaymentService: Content {
    static func createPayment(_ req: Request, groupID: UUID, _ input: CreatePaymentRequest, actorID: UUID) async throws -> Payment {
        try await GroupService.assertUserIsMember(req, groupID: groupID, userID: actorID)
        try await GroupService.assertUserIsMember(req, groupID: groupID, userID: input.payerId)
        try await GroupService.assertUserIsMember(req, groupID: groupID, userID: input.receiverId)

        let payment = Payment(
            groupID: groupID,
            payerID: input.payerId,
            receiverID: input.receiverId,
            amount: input.amount
        )
        try await payment.save(on: req.db)

        let paymentID = try payment.requireID()

        let payerLedger = LedgerEntry(
            groupID: groupID,
            userID: input.payerId,
            amount: input.amount,
            referenceType: "PAYMENT",
            referenceId: paymentID
        )
        try await payerLedger.save(on: req.db)

        let receiverLedger = LedgerEntry(
            groupID: groupID,
            userID: input.receiverId,
            amount: -input.amount,
            referenceType: "PAYMENT",
            referenceId: paymentID
        )
        try await receiverLedger.save(on: req.db)

        try await GroupService.logActivity(req, groupID: groupID, actorID: actorID, type: "PAYMENT_CREATED", referenceId: paymentID)

        return payment
    }

    static func getPayment(_ req: Request, paymentID: UUID) async throws -> Payment {
        guard let payment = try await Payment.find(paymentID, on: req.db) else {
            throw Abort(.notFound, reason: "Payment not found")
        }
        return payment
    }

    static func reversePayment(_ req: Request, paymentID: UUID, actorID: UUID) async throws -> Payment {
        let payment = try await getPayment(req, paymentID: paymentID)
        let groupID = payment.$group.id

        try await GroupService.assertUserIsMember(req, groupID: groupID, userID: actorID)

        guard payment.reversedAt == nil else {
            throw Abort(.badRequest, reason: "Payment already reversed")
        }

        payment.reversedAt = Date()
        try await payment.update(on: req.db)

        try await LedgerEntry
            .query(on: req.db)
            .filter(\.$referenceType == "PAYMENT")
            .filter(\.$referenceId == paymentID)
            .delete()

        try await GroupService.logActivity(req, groupID: groupID, actorID: actorID, type: "PAYMENT_REVERSED", referenceId: paymentID)

        return payment
    }

    static func listPayments(_ req: Request, groupID: UUID) async throws -> [Payment] {
        return try await Payment
            .query(on: req.db)
            .filter(\.$group.$id == groupID)
            .filter(\.$reversedAt == nil)
            .all()
    }
}
