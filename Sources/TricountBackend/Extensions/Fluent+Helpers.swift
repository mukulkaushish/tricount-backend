import Fluent
import Vapor

extension QueryBuilder {
    /// Returns the first result or throws the given error.
    func firstOrThrow(_ error: any Error) async throws -> Model {
        guard let model = try await first() else { throw error }
        return model
    }
}
