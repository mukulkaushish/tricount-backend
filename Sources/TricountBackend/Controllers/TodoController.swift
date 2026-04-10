import Fluent
import Vapor

struct TodoController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let todos = routes.documented().grouped("todos")

        todos.getRaw(use: self.index)
        todos.postRaw(use: self.create)
        todos.grouped(":todoID").deleteNoContent(use: self.delete)
    }

    @Sendable
    func index(req: Request) async throws -> [TodoResponse] {
        try await Todo.query(on: req.db).all().map { try $0.toResponse() }
    }

    @Sendable
    func create(req: Request, body: CreateTodoRequest) async throws -> TodoResponse {
        guard !body.normalizedTitle.isEmpty else {
            throw Abort(.badRequest, reason: "Title is required")
        }

        let todo = body.toModel()

        try await todo.save(on: req.db)
        return try todo.toResponse()
    }

    @Sendable
    func delete(req: Request) async throws {
        let todoID = try req.requireUUIDParameter("todoID")
        guard let todo = try await Todo.find(todoID, on: req.db) else {
            throw Abort(.notFound)
        }

        try await todo.delete(on: req.db)
    }
}
