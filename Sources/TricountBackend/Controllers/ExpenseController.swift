import Vapor
import Fluent

struct ExpenseController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let expenses = routes
            .grouped("groups", ":id")
            .grouped(JWTAuthMiddleware())
            .grouped(VerifiedUserMiddleware())
            .grouped(GroupMemberMiddleware())
            .grouped(IdempotencyMiddleware())
            .grouped("expenses")

        expenses.post(use: createExpense)
            .documented(auth: .bearer, response: .raw(CreateExpenseResponse.self, status: .created), requestBody: .json(CreateExpenseRequest.self))
        expenses.get(use: listExpenses)
            .documented(auth: .bearer, response: .raw(ListExpensesResponse.self))
        expenses.get(":expenseId", use: getExpense)
            .documented(auth: .bearer, response: .raw(ExpenseDetailsResponse.self))
        expenses.put(":expenseId", use: updateExpense)
            .documented(auth: .bearer, response: .raw(ExpenseDetailsResponse.self), requestBody: .json(UpdateExpenseRequest.self))
        expenses.delete(":expenseId", use: deleteExpense)
            .documented(auth: .bearer, response: .empty())
    }

    func createExpense(req: Request) async throws -> Response {
        let ctx = try req.groupContext

        let input = try req.content.decode(CreateExpenseRequest.self)
        let expense = try await req.services.expenses.create(groupID: ctx.groupID, input, actorID: ctx.userID)

        async let splitsQuery = buildSplitResponses(req, expenseID: try expense.requireID())
        async let paidByQuery = User.requireFind(expense.$paidBy.id, on: req.db, notFoundMessage: "Payer not found")
        let (splitResponses, paidByUser) = try await (splitsQuery, paidByQuery)

        let response = CreateExpenseResponse(
            id: try expense.requireID(),
            groupId: ctx.groupID,
            title: expense.title,
            amount: expense.amount,
            currency: expense.currency,
            paidBy: try paidByUser.toBasicInfo(),
            splits: splitResponses,
            notes: expense.notes,
            createdAt: expense.createdAt ?? Date()
        )

        let httpResponse = Response(status: .created)
        try httpResponse.content.encode(response)
        return httpResponse
    }

    func listExpenses(req: Request) async throws -> ListExpensesResponse {
        let ctx = try req.groupContext

        let expenses = try await req.services.expenses.list(groupID: ctx.groupID)
        let responses = try expenses.map { expense in
            ExpenseListResponse(
                id: try expense.requireID(),
                title: expense.title,
                amount: expense.amount,
                currency: expense.currency,
                paidBy: try expense.paidBy.toBasicInfo(),
                createdAt: expense.createdAt ?? Date()
            )
        }

        return ListExpensesResponse(expenses: responses, total: responses.count)
    }

    func getExpense(req: Request) async throws -> ExpenseDetailsResponse {
        let ctx = try req.groupContext
        let expenseID = try req.requireUUIDParameter("expenseId")
        let expense = try await req.services.expenses.get(expenseID: expenseID)
        return try await buildDetailsResponse(req, expense: expense, groupID: ctx.groupID)
    }

    func updateExpense(req: Request) async throws -> ExpenseDetailsResponse {
        let ctx = try req.groupContext
        let expenseID = try req.requireUUIDParameter("expenseId")

        let input = try req.content.decode(UpdateExpenseRequest.self)
        let expense = try await req.services.expenses.update(expenseID: expenseID, input, actorID: ctx.userID)
        return try await buildDetailsResponse(req, expense: expense, groupID: ctx.groupID)
    }

    func deleteExpense(req: Request) async throws -> HTTPStatus {
        let ctx = try req.groupContext
        let expenseID = try req.requireUUIDParameter("expenseId")
        try await req.services.expenses.delete(expenseID: expenseID, actorID: ctx.userID)
        return .ok
    }

    // MARK: - Private Helpers

    private func buildSplitResponses(_ req: Request, expenseID: UUID) async throws -> [ExpenseSplitResponse] {
        let splits = try await req.services.expenses.getSplits(expenseID: expenseID)
        return try splits.map { split in
            ExpenseSplitResponse(
                id: try split.requireID(),
                user: try split.user.toBasicInfo(),
                amount: split.amount
            )
        }
    }

    private func buildDetailsResponse(_ req: Request, expense: Expense, groupID: UUID) async throws -> ExpenseDetailsResponse {
        async let paidByQuery = User.requireFind(expense.$paidBy.id, on: req.db, notFoundMessage: "Payer not found")
        async let splitsQuery = buildSplitResponses(req, expenseID: try expense.requireID())
        let (paidByUser, splitResponses) = try await (paidByQuery, splitsQuery)

        return ExpenseDetailsResponse(
            id: try expense.requireID(),
            groupId: groupID,
            title: expense.title,
            amount: expense.amount,
            currency: expense.currency,
            paidBy: try paidByUser.toBasicInfo(),
            splits: splitResponses,
            notes: expense.notes,
            createdAt: expense.createdAt ?? Date(),
            updatedAt: expense.updatedAt ?? expense.createdAt ?? Date()
        )
    }
}
