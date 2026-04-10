import Vapor

public func configure(_ app: Application) async throws {
    app.configureMiddleware()
    app.configureJWT()
    try app.configureDatabase()
    app.configureMigrations()

    try routes(app)
    try app.generateRouteDocumentation()
    try await app.autoMigrate()

    // Schedule recurring cleanup: runs on boot + every hour, purges records expired > 14 min ago
    let cleanup = ExpiredRecordCleanupService(app: app)
    cleanup.scheduleRecurringCleanup()
}
