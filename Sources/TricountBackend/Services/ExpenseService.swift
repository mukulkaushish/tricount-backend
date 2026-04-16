import Fluent
import Vapor

struct ExpenseService {
    let req: Request

    private var groups: GroupService { req.services.groups }

    func create(groupID: UUID, _ input: CreateExpenseRequest, actorID: UUID) async throws -> Expense {
        try await groups.assertUserIsMember(groupID: groupID, userID: actorID)

        let expense = Expense(
            groupID: groupID,
            paidByID: input.paidBy,
            amount: input.amount,
            currency: input.currency ?? "INR",
            title: input.title,
            notes: input.notes
        )
        try await expense.save(on: req.db)

        let totalSplit = input.splits.reduce(0) { $0 + $1.amount }
        guard totalSplit == input.amount else {
            try await expense.delete(on: req.db)
            throw Abort(.badRequest, reason: "Split amounts must equal total expense")
        }

        for split in input.splits {
            try await groups.assertUserIsMember(groupID: groupID, userID: split.userId)

            let splitRecord = ExpenseSplit(
                expenseID: try expense.requireID(),
                userID: split.userId,
                amount: split.amount
            )
            try await splitRecord.save(on: req.db)

            let ledgerEntry = LedgerEntry(
                groupID: groupID,
                userID: split.userId,
                amount: -split.amount,
                referenceType: "EXPENSE",
                referenceId: try expense.requireID()
            )
            try await ledgerEntry.save(on: req.db)
        }

        let ledgerEntry = LedgerEntry(
            groupID: groupID,
            userID: input.paidBy,
            amount: input.amount,
            referenceType: "EXPENSE",
            referenceId: try expense.requireID()
        )
        try await ledgerEntry.save(on: req.db)

        try await groups.logActivity(groupID: groupID, actorID: actorID, type: "EXPENSE_CREATED", referenceId: try expense.requireID())

        return expense
    }

    func get(expenseID: UUID) async throws -> Expense {
        try await Expense.requireFind(expenseID, on: req.db, notFoundMessage: "Expense not found")
    }

    func update(expenseID: UUID, _ input: UpdateExpenseRequest, actorID: UUID) async throws -> Expense {
        let expense = try await get(expenseID: expenseID)
        let groupID = expense.$group.id

        try await groups.assertUserIsMember(groupID: groupID, userID: actorID)

        expense.deletedAt = Date()
        try await expense.update(on: req.db)

        let newExpense = Expense(
            groupID: groupID,
            paidByID: input.paidBy ?? expense.$paidBy.id,
            amount: input.amount ?? expense.amount,
            currency: input.currency ?? expense.currency,
            title: input.title ?? expense.title,
            notes: input.notes
        )
        try await newExpense.save(on: req.db)

        let splits = input.splits ?? []
        let totalSplit = splits.reduce(0) { $0 + $1.amount }
        guard totalSplit == newExpense.amount else {
            throw Abort(.badRequest, reason: "Split amounts must equal total expense")
        }

        for split in splits {
            try await groups.assertUserIsMember(groupID: groupID, userID: split.userId)

            let splitRecord = ExpenseSplit(
                expenseID: try newExpense.requireID(),
                userID: split.userId,
                amount: split.amount
            )
            try await splitRecord.save(on: req.db)

            let ledgerEntry = LedgerEntry(
                groupID: groupID,
                userID: split.userId,
                amount: -split.amount,
                referenceType: "EXPENSE",
                referenceId: try newExpense.requireID()
            )
            try await ledgerEntry.save(on: req.db)
        }

        let ledgerEntry = LedgerEntry(
            groupID: groupID,
            userID: newExpense.$paidBy.id,
            amount: newExpense.amount,
            referenceType: "EXPENSE",
            referenceId: try newExpense.requireID()
        )
        try await ledgerEntry.save(on: req.db)

        try await groups.logActivity(groupID: groupID, actorID: actorID, type: "EXPENSE_UPDATED", referenceId: try newExpense.requireID())

        return newExpense
    }

    func delete(expenseID: UUID, actorID: UUID) async throws {
        let expense = try await get(expenseID: expenseID)
        let groupID = expense.$group.id

        try await groups.assertUserIsMember(groupID: groupID, userID: actorID)

        expense.deletedAt = Date()
        try await expense.update(on: req.db)

        try await LedgerEntry
            .query(on: req.db)
            .filter(\.$referenceType == "EXPENSE")
            .filter(\.$referenceId == expenseID)
            .delete()

        try await groups.logActivity(groupID: groupID, actorID: actorID, type: "EXPENSE_DELETED", referenceId: expenseID)
    }

    func list(groupID: UUID) async throws -> [Expense] {
        try await Expense
            .query(on: req.db)
            .filter(\.$group.$id == groupID)
            .filter(\.$deletedAt == nil)
            .all()
    }

    func getSplits(expenseID: UUID) async throws -> [ExpenseSplit] {
        try await ExpenseSplit
            .query(on: req.db)
            .filter(\.$expense.$id == expenseID)
            .all()
    }
}
