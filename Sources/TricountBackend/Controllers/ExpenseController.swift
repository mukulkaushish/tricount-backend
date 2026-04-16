import Vapor
import Fluent

struct ExpenseController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let expenses = routes
            .grouped("groups", ":id")
            .grouped(JWTAuthMiddleware())
            .grouped(GroupMemberMiddleware())
            .grouped("expenses")

        expenses.post(use: createExpense)
        expenses.get(use: listExpenses)
        expenses.get(":expenseId", use: getExpense)
        expenses.put(":expenseId", use: updateExpense)
        expenses.delete(":expenseId", use: deleteExpense)
    }

    func createExpense(req: Request) async throws -> Response {
        let ctx = try req.groupContext

        let input = try req.content.decode(CreateExpenseRequest.self)
        let expense = try await req.services.expenses.create(groupID: ctx.groupID, input, actorID: ctx.userID)

        let splitResponses = try await buildSplitResponses(req, expenseID: try expense.requireID())
        let paidByUser = try await User.requireFind(expense.$paidBy.id, on: req.db, notFoundMessage: "Payer not found")

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

        var httpResponse = Response(status: .created)
        try httpResponse.content.encode(response)
        return httpResponse
    }

    func listExpenses(req: Request) async throws -> ListExpensesResponse {
        let ctx = try req.groupContext

        let expenses = try await req.services.expenses.list(groupID: ctx.groupID)
        var responses: [ExpenseListResponse] = []

        for expense in expenses {
            let paidByUser = try await User.requireFind(expense.$paidBy.id, on: req.db, notFoundMessage: "Payer not found")
            responses.append(ExpenseListResponse(
                id: try expense.requireID(),
                title: expense.title,
                amount: expense.amount,
                currency: expense.currency,
                paidBy: try paidByUser.toBasicInfo(),
                createdAt: expense.createdAt ?? Date()
            ))
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
        var responses: [ExpenseSplitResponse] = []

        for split in splits {
            let user = try await User.requireFind(split.$user.id, on: req.db)
            responses.append(ExpenseSplitResponse(
                id: try split.requireID(),
                user: try user.toBasicInfo(),
                amount: split.amount
            ))
        }

        return responses
    }

    private func buildDetailsResponse(_ req: Request, expense: Expense, groupID: UUID) async throws -> ExpenseDetailsResponse {
        let paidByUser = try await User.requireFind(expense.$paidBy.id, on: req.db, notFoundMessage: "Payer not found")
        let splitResponses = try await buildSplitResponses(req, expenseID: try expense.requireID())

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
