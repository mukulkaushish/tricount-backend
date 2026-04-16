import Vapor

public func configure(_ app: Application) async throws {
    try app.loadRuntimeConfiguration()
    app.configureMiddleware()
    app.configureJWT()
    try app.configureDatabase()
    app.configureMigrations()

    try routes(app)
    // Always generate the API reference so GET / serves a live Scalar UI regardless of environment.
    try app.generateRouteDocumentation()
    if app.runtimeConfiguration.startup.autoMigrateOnBoot {
        try await app.autoMigrate()
    }

    // Schedule recurring cleanup: runs on boot + every hour, purges records expired > 14 min ago
    let cleanup = ExpiredRecordCleanupService(app: app)
    cleanup.scheduleRecurringCleanup()
}
