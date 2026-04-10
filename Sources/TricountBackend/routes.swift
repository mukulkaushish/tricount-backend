import Vapor

func routes(_ app: Application) throws {
    app.documented().getRaw { _ async in
        HealthCheckResponse(status: "ok", service: "tricount-backend")
    }

    // Redirect /docs to the generated HTML documentation
    app.get("docs") { $0.redirect(to: "/docs/index.html") }

    let v1 = app.grouped("v1")
    try v1.register(collection: TodoController())
    try v1.register(collection: AuthController())
}
