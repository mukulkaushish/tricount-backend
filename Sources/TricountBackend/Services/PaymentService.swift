import Fluent
import Vapor

struct PaymentService {
    let req: Request

    private var groups: GroupService { req.services.groups }

    func create(groupID: UUID, _ input: CreatePaymentRequest, actorID: UUID) async throws -> Payment {
        try await groups.assertUserIsMember(groupID: groupID, userID: actorID)
        try await groups.assertUserIsMember(groupID: groupID, userID: input.payerId)
        try await groups.assertUserIsMember(groupID: groupID, userID: input.receiverId)

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

        try await groups.logActivity(groupID: groupID, actorID: actorID, type: "PAYMENT_CREATED", referenceId: paymentID)

        return payment
    }

    func get(paymentID: UUID) async throws -> Payment {
        try await Payment.requireFind(paymentID, on: req.db, notFoundMessage: "Payment not found")
    }

    func reverse(paymentID: UUID, actorID: UUID) async throws -> Payment {
        let payment = try await get(paymentID: paymentID)
        let groupID = payment.$group.id

        try await groups.assertUserIsMember(groupID: groupID, userID: actorID)

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

        try await groups.logActivity(groupID: groupID, actorID: actorID, type: "PAYMENT_REVERSED", referenceId: paymentID)

        return payment
    }

    func list(groupID: UUID) async throws -> [Payment] {
        try await Payment
            .query(on: req.db)
            .filter(\.$group.$id == groupID)
            .filter(\.$reversedAt == nil)
            .all()
    }
}
