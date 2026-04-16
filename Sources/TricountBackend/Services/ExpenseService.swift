import Fluent
import Vapor

struct ExpenseService {
    let req: Request

    private var groups: GroupService { req.services.groups }

    private static let maxTitleLength = 200
    private static let maxNotesLength = 2000
    private static let maxAmount: Int64 = 1_000_000_000_00  // 1e11 paise (safety cap)
    private static let maxSplitCount = 100

    func create(groupID: UUID, _ input: CreateExpenseRequest, actorID: UUID) async throws -> Expense {
        try await groups.assertUserIsMember(groupID: groupID, userID: actorID)

        try Self.validateAmount(input.amount)
        let title = try Self.validateTitle(input.title)
        let notes = try Self.validateNotes(input.notes)
        try Self.validateSplits(input.splits, expectedTotal: input.amount)

        // Single batched membership check covering payer + every split user.
        try await groups.assertUsersAreMembers(
            groupID: groupID,
            userIDs: [input.paidBy] + input.splits.map(\.userId)
        )

        let expense = Expense(
            groupID: groupID,
            paidByID: input.paidBy,
            amount: input.amount,
            currency: input.currency ?? "INR",
            title: title,
            notes: notes
        )

        try await req.db.transaction { db in
            try await expense.save(on: db)
            let expenseID = try expense.requireID()

            let splitRecords = input.splits.map { split in
                ExpenseSplit(expenseID: expenseID, userID: split.userId, amount: split.amount)
            }
            try await splitRecords.create(on: db)

            var ledgerRecords = input.splits.map { split in
                LedgerEntry(
                    groupID: groupID,
                    userID: split.userId,
                    amount: -split.amount,
                    referenceType: "EXPENSE",
                    referenceId: expenseID
                )
            }
            ledgerRecords.append(LedgerEntry(
                groupID: groupID,
                userID: input.paidBy,
                amount: input.amount,
                referenceType: "EXPENSE",
                referenceId: expenseID
            ))
            try await ledgerRecords.create(on: db)

            let activity = GroupActivity(groupID: groupID, actorID: actorID, type: "EXPENSE_CREATED", referenceId: expenseID)
            try await activity.save(on: db)
        }

        return expense
    }

    func get(expenseID: UUID) async throws -> Expense {
        let expense = try await Expense.requireFind(expenseID, on: req.db, notFoundMessage: "Expense not found")
        guard expense.deletedAt == nil else {
            throw Abort(.notFound, reason: "Expense not found")
        }
        return expense
    }

    func update(expenseID: UUID, _ input: UpdateExpenseRequest, actorID: UUID) async throws -> Expense {
        let expense = try await get(expenseID: expenseID)
        let groupID = expense.$group.id

        try await groups.assertUserIsMember(groupID: groupID, userID: actorID)

        if let title = input.title {
            expense.title = try Self.validateTitle(title)
        }
        if let amount = input.amount {
            try Self.validateAmount(amount)
            expense.amount = amount
        }
        if let currency = input.currency {
            expense.currency = currency
        }
        if let paidBy = input.paidBy {
            expense.$paidBy.id = paidBy
        }
        if let notes = input.notes {
            expense.notes = try Self.validateNotes(notes)
        }

        let newSplits = input.splits
        if let splits = newSplits {
            try Self.validateSplits(splits, expectedTotal: expense.amount)
        } else if input.amount != nil || input.paidBy != nil {
            throw Abort(.badRequest, reason: "splits must be provided when amount or paid_by changes")
        }

        // Batched membership check for any user referenced by this update.
        var changedUsers: [UUID] = []
        if let paidBy = input.paidBy { changedUsers.append(paidBy) }
        if let splits = newSplits { changedUsers.append(contentsOf: splits.map(\.userId)) }
        try await groups.assertUsersAreMembers(groupID: groupID, userIDs: changedUsers)

        try await req.db.transaction { db in
            try await expense.update(on: db)

            if let splits = newSplits {
                try await ExpenseSplit.query(on: db)
                    .filter(\.$expense.$id == expenseID)
                    .delete()
                try await LedgerEntry.query(on: db)
                    .filter(\.$referenceType == "EXPENSE")
                    .filter(\.$referenceId == expenseID)
                    .delete()

                let splitRecords = splits.map { split in
                    ExpenseSplit(expenseID: expenseID, userID: split.userId, amount: split.amount)
                }
                try await splitRecords.create(on: db)

                var ledgerRecords = splits.map { split in
                    LedgerEntry(
                        groupID: groupID,
                        userID: split.userId,
                        amount: -split.amount,
                        referenceType: "EXPENSE",
                        referenceId: expenseID
                    )
                }
                ledgerRecords.append(LedgerEntry(
                    groupID: groupID,
                    userID: expense.$paidBy.id,
                    amount: expense.amount,
                    referenceType: "EXPENSE",
                    referenceId: expenseID
                ))
                try await ledgerRecords.create(on: db)
            }

            let activity = GroupActivity(groupID: groupID, actorID: actorID, type: "EXPENSE_UPDATED", referenceId: expenseID)
            try await activity.save(on: db)
        }

        return expense
    }

    func delete(expenseID: UUID, actorID: UUID) async throws {
        let expense = try await get(expenseID: expenseID)
        let groupID = expense.$group.id

        try await groups.assertUserIsMember(groupID: groupID, userID: actorID)

        try await req.db.transaction { db in
            expense.deletedAt = Date()
            try await expense.update(on: db)

            // Hard-delete child rows so balance computations ignore them even if a consumer forgets to join on deleted_at.
            try await ExpenseSplit.query(on: db)
                .filter(\.$expense.$id == expenseID)
                .delete()
            try await LedgerEntry.query(on: db)
                .filter(\.$referenceType == "EXPENSE")
                .filter(\.$referenceId == expenseID)
                .delete()

            let activity = GroupActivity(groupID: groupID, actorID: actorID, type: "EXPENSE_DELETED", referenceId: expenseID)
            try await activity.save(on: db)
        }
    }

    func list(groupID: UUID) async throws -> [Expense] {
        try await Expense
            .query(on: req.db)
            .filter(\.$group.$id == groupID)
            .filter(\.$deletedAt == nil)
            .with(\.$paidBy)
            .sort(\.$createdAt, .descending)
            .all()
    }

    func getSplits(expenseID: UUID) async throws -> [ExpenseSplit] {
        try await ExpenseSplit
            .query(on: req.db)
            .filter(\.$expense.$id == expenseID)
            .with(\.$user)
            .all()
    }

    // MARK: - Validation helpers

    private static func validateAmount(_ amount: Int64) throws {
        guard amount > 0 else {
            throw Abort(.badRequest, reason: "Expense amount must be greater than zero")
        }
        guard amount <= maxAmount else {
            throw Abort(.badRequest, reason: "Expense amount exceeds the allowed maximum")
        }
    }

    private static func validateTitle(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw Abort(.badRequest, reason: "Expense title cannot be empty")
        }
        guard trimmed.count <= maxTitleLength else {
            throw Abort(.badRequest, reason: "Expense title must be \(maxTitleLength) characters or fewer")
        }
        return trimmed
    }

    private static func validateNotes(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard trimmed.count <= maxNotesLength else {
            throw Abort(.badRequest, reason: "Expense notes must be \(maxNotesLength) characters or fewer")
        }
        return trimmed
    }

    private static func validateSplits(_ splits: [ExpenseSplitInput], expectedTotal: Int64) throws {
        guard !splits.isEmpty else {
            throw Abort(.badRequest, reason: "At least one split is required")
        }
        guard splits.count <= maxSplitCount else {
            throw Abort(.badRequest, reason: "An expense can have at most \(maxSplitCount) splits")
        }
        for split in splits {
            guard split.amount > 0 else {
                throw Abort(.badRequest, reason: "Split amounts must be greater than zero")
            }
        }
        let uniqueUsers = Set(splits.map(\.userId))
        guard uniqueUsers.count == splits.count else {
            throw Abort(.badRequest, reason: "Each split must reference a distinct user")
        }
        let total = splits.reduce(0) { $0 + $1.amount }
        guard total == expectedTotal else {
            throw Abort(.badRequest, reason: "Split amounts (\(total)) must equal total expense (\(expectedTotal))")
        }
    }
}
