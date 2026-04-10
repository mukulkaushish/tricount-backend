import Vapor

func routes(_ app: Application) throws {
    app.documented().getRaw { _ async in
        HealthCheckResponse(status: "ok", service: "tricount-backend")
    }

    // Serve docs index directly (no redirect)
    app.get("docs") { req in
        req.fileio.streamFile(at: app.directory.publicDirectory + "docs/index.html")
    }

    let v1 = app.grouped("v1")
    try v1.register(collection: TodoController())
    try v1.register(collection: AuthController())
}
