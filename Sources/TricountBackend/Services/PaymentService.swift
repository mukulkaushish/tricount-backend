import Fluent
import Vapor

struct PaymentService {
    let req: Request

    private var groups: GroupService { req.services.groups }

    private static let maxAmount: Int64 = 1_000_000_000_00

    func create(groupID: UUID, _ input: CreatePaymentRequest, actorID: UUID) async throws -> Payment {
        try await groups.assertUserIsMember(groupID: groupID, userID: actorID)

        guard input.payerId != input.receiverId else {
            throw Abort(.badRequest, reason: "Payer and receiver must be different users")
        }
        try Self.validateAmount(input.amount)

        try await groups.assertUserIsMember(groupID: groupID, userID: input.payerId)
        try await groups.assertUserIsMember(groupID: groupID, userID: input.receiverId)

        let payment = Payment(
            groupID: groupID,
            payerID: input.payerId,
            receiverID: input.receiverId,
            amount: input.amount
        )

        try await req.db.transaction { db in
            try await payment.save(on: db)
            let paymentID = try payment.requireID()

            let payerLedger = LedgerEntry(
                groupID: groupID,
                userID: input.payerId,
                amount: input.amount,
                referenceType: "PAYMENT",
                referenceId: paymentID
            )
            try await payerLedger.save(on: db)

            let receiverLedger = LedgerEntry(
                groupID: groupID,
                userID: input.receiverId,
                amount: -input.amount,
                referenceType: "PAYMENT",
                referenceId: paymentID
            )
            try await receiverLedger.save(on: db)

            let activity = GroupActivity(groupID: groupID, actorID: actorID, type: "PAYMENT_CREATED", referenceId: paymentID)
            try await activity.save(on: db)
        }

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

        try await req.db.transaction { db in
            // Re-read inside the transaction to close the check-then-act race on concurrent reversals.
            guard let locked = try await Payment.find(paymentID, on: db) else {
                throw Abort(.notFound, reason: "Payment not found")
            }
            guard locked.reversedAt == nil else {
                throw Abort(.badRequest, reason: "Payment already reversed")
            }

            locked.reversedAt = Date()
            try await locked.update(on: db)
            payment.reversedAt = locked.reversedAt

            try await LedgerEntry.query(on: db)
                .filter(\.$referenceType == "PAYMENT")
                .filter(\.$referenceId == paymentID)
                .delete()

            let activity = GroupActivity(groupID: groupID, actorID: actorID, type: "PAYMENT_REVERSED", referenceId: paymentID)
            try await activity.save(on: db)
        }

        return payment
    }

    func list(groupID: UUID) async throws -> [Payment] {
        try await Payment
            .query(on: req.db)
            .filter(\.$group.$id == groupID)
            .filter(\.$reversedAt == nil)
            .with(\.$payer)
            .with(\.$receiver)
            .sort(\.$createdAt, .descending)
            .all()
    }

    private static func validateAmount(_ amount: Int64) throws {
        guard amount > 0 else {
            throw Abort(.badRequest, reason: "Payment amount must be greater than zero")
        }
        guard amount <= maxAmount else {
            throw Abort(.badRequest, reason: "Payment amount exceeds the allowed maximum")
        }
    }
}
