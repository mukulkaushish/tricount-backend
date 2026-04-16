import Vapor

func routes(_ app: Application) throws {
    app.documented().getRaw { _ async in
        HealthCheckResponse(status: "ok", service: "tricount-backend")
    }

    app.get("docs") { _ in
        Response(status: .seeOther, headers: ["Location": "/docs/index.html"])
    }

    let v1 = app.grouped("v1")

    // Auth endpoints
    try v1.register(collection: AuthController())

    // Groups & Members
    try v1.register(collection: GroupController())

    // Expenses
    try v1.register(collection: ExpenseController())

    // Payments
    try v1.register(collection: PaymentController())

    // Payment Identity
    try v1.register(collection: PaymentIdentityController())

    // Invites
    try v1.register(collection: InviteController())
}
