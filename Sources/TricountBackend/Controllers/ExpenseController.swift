import Vapor
import Fluent

struct ExpenseController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let groups = routes.grouped("groups", ":id", "expenses")

        groups.post(use: createExpense)
        groups.get(use: listExpenses)
        groups.get(":expenseId", use: getExpense)
        groups.put(":expenseId", use: updateExpense)
        groups.delete(":expenseId", use: deleteExpense)
    }

    func createExpense(req: Request) async throws -> Response {
        let payload = try req.auth.require(UserJWTPayload.self)
        guard let groupID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid group ID")
        }

        let input = try req.content.decode(CreateExpenseRequest.self)
        let expense = try await ExpenseService.createExpense(req, groupID: groupID, input, actorID: UUID(uuidString: payload.userId)!)

        let splits = try await ExpenseService.getExpenseSplits(req, expenseID: try expense.requireID())
        var splitResponses: [ExpenseSplitResponse] = []

        for split in splits {
            guard let user = try await User.find(try split.$user.id, on: req.db) else {
                throw Abort(.notFound, reason: "User not found")
            }

            splitResponses.append(ExpenseSplitResponse(
                id: try split.requireID(),
                user: UserBasicInfo(id: try user.requireID(), displayName: user.displayName, email: user.email, avatarUrl: nil),
                amount: split.amount
            ))
        }

        guard let paidByUser = try await User.find(try expense.$paidBy.id, on: req.db) else {
            throw Abort(.notFound, reason: "Payer not found")
        }

        let response = CreateExpenseResponse(
            id: try expense.requireID(),
            groupId: groupID,
            title: expense.title,
            amount: expense.amount,
            currency: expense.currency,
            paidBy: UserBasicInfo(id: try paidByUser.requireID(), displayName: paidByUser.displayName, email: paidByUser.email, avatarUrl: nil),
            splits: splitResponses,
            notes: expense.notes,
            createdAt: expense.createdAt ?? Date()
        )

        var httpResponse = Response(status: .created)
        try httpResponse.content.encode(response)
        return httpResponse
    }

    func listExpenses(req: Request) async throws -> ListExpensesResponse {
        let payload = try req.auth.require(UserJWTPayload.self)
        guard let groupID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid group ID")
        }

        try await GroupService.assertUserIsMember(req, groupID: groupID, userID: UUID(uuidString: payload.userId)!)

        let expenses = try await ExpenseService.listExpenses(req, groupID: groupID)
        var responses: [ExpenseListResponse] = []

        for expense in expenses {
            guard let paidByUser = try await User.find(try expense.$paidBy.id, on: req.db) else {
                throw Abort(.notFound, reason: "Payer not found")
            }

            responses.append(ExpenseListResponse(
                id: try expense.requireID(),
                title: expense.title,
                amount: expense.amount,
                currency: expense.currency,
                paidBy: UserBasicInfo(id: try paidByUser.requireID(), displayName: paidByUser.displayName, email: paidByUser.email, avatarUrl: nil),
                createdAt: expense.createdAt ?? Date()
            ))
        }

        return ListExpensesResponse(expenses: responses, total: responses.count)
    }

    func getExpense(req: Request) async throws -> ExpenseDetailsResponse {
        let payload = try req.auth.require(UserJWTPayload.self)
        guard let groupID = req.parameters.get("id", as: UUID.self),
              let expenseID = req.parameters.get("expenseId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid parameters")
        }

        try await GroupService.assertUserIsMember(req, groupID: groupID, userID: UUID(uuidString: payload.userId)!)

        let expense = try await ExpenseService.getExpense(req, expenseID: expenseID)
        guard let paidByUser = try await User.find(try expense.$paidBy.id, on: req.db) else {
            throw Abort(.notFound, reason: "Payer not found")
        }

        let splits = try await ExpenseService.getExpenseSplits(req, expenseID: expenseID)
        var splitResponses: [ExpenseSplitResponse] = []

        for split in splits {
            guard let user = try await User.find(try split.$user.id, on: req.db) else {
                throw Abort(.notFound, reason: "User not found")
            }

            splitResponses.append(ExpenseSplitResponse(
                id: try split.requireID(),
                user: UserBasicInfo(id: try user.requireID(), displayName: user.displayName, email: user.email, avatarUrl: nil),
                amount: split.amount
            ))
        }

        return ExpenseDetailsResponse(
            id: try expense.requireID(),
            groupId: groupID,
            title: expense.title,
            amount: expense.amount,
            currency: expense.currency,
            paidBy: UserBasicInfo(id: try paidByUser.requireID(), displayName: paidByUser.displayName, email: paidByUser.email, avatarUrl: nil),
            splits: splitResponses,
            notes: expense.notes,
            createdAt: expense.createdAt ?? Date(),
            updatedAt: expense.updatedAt ?? expense.createdAt ?? Date()
        )
    }

    func updateExpense(req: Request) async throws -> ExpenseDetailsResponse {
        let payload = try req.auth.require(UserJWTPayload.self)
        guard let groupID = req.parameters.get("id", as: UUID.self),
              let expenseID = req.parameters.get("expenseId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid parameters")
        }

        let input = try req.content.decode(UpdateExpenseRequest.self)
        let updatedExpense = try await ExpenseService.updateExpense(req, expenseID: expenseID, input, actorID: UUID(uuidString: payload.userId)!)

        guard let paidByUser = try await User.find(try updatedExpense.$paidBy.id, on: req.db) else {
            throw Abort(.notFound, reason: "Payer not found")
        }

        let splits = try await ExpenseService.getExpenseSplits(req, expenseID: try updatedExpense.requireID())
        var splitResponses: [ExpenseSplitResponse] = []

        for split in splits {
            guard let user = try await User.find(try split.$user.id, on: req.db) else {
                throw Abort(.notFound, reason: "User not found")
            }

            splitResponses.append(ExpenseSplitResponse(
                id: try split.requireID(),
                user: UserBasicInfo(id: try user.requireID(), displayName: user.displayName, email: user.email, avatarUrl: nil),
                amount: split.amount
            ))
        }

        return ExpenseDetailsResponse(
            id: try updatedExpense.requireID(),
            groupId: groupID,
            title: updatedExpense.title,
            amount: updatedExpense.amount,
            currency: updatedExpense.currency,
            paidBy: UserBasicInfo(id: try paidByUser.requireID(), displayName: paidByUser.displayName, email: paidByUser.email, avatarUrl: nil),
            splits: splitResponses,
            notes: updatedExpense.notes,
            createdAt: updatedExpense.createdAt ?? Date(),
            updatedAt: updatedExpense.updatedAt ?? updatedExpense.createdAt ?? Date()
        )
    }

    func deleteExpense(req: Request) async throws -> HTTPStatus {
        let payload = try req.auth.require(UserJWTPayload.self)
        guard let groupID = req.parameters.get("id", as: UUID.self),
              let expenseID = req.parameters.get("expenseId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid parameters")
        }

        try await GroupService.assertUserIsMember(req, groupID: groupID, userID: UUID(uuidString: payload.userId)!)
        try await ExpenseService.deleteExpense(req, expenseID: expenseID, actorID: UUID(uuidString: payload.userId)!)
        return .ok
    }
}
