import Fluent
import Foundation
import Vapor

struct CreateTodoRequest: Content {
    let title: String

    var normalizedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func toModel() -> Todo {
        Todo(title: normalizedTitle)
    }
}

struct TodoResponse: Content {
    let id: UUID
    let title: String
}
