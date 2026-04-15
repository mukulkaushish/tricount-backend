import Vapor

func routes(_ app: Application) throws {
    app.documented().getRaw { _ async in
        HealthCheckResponse(status: "ok", service: "tricount-backend")
    }

    app.get("docs") { _ in
        Response(status: .seeOther, headers: ["Location": "/docs/index.html"])
    }

    let v1 = app.grouped("v1")
    try v1.register(collection: AuthController())
}
