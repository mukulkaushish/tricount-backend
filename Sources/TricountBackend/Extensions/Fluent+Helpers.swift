import Fluent
import Vapor

extension QueryBuilder {
    /// Returns the first result or throws the given error.
    func firstOrThrow(_ error: any Error) async throws -> Model {
        guard let model = try await first() else { throw error }
        return model
    }
}

extension Model where IDValue == UUID {
    static func requireFind(_ id: UUID, on db: any Database, notFoundMessage: String? = nil) async throws -> Self {
        guard let model = try await find(id, on: db) else {
            throw Abort(.notFound, reason: notFoundMessage ?? "\(Self.self) not found")
        }
        return model
    }
}
