import Vapor

extension Application {
    func configureMiddleware() {
        logger.logLevel = runtimeConfiguration.observability.logLevel

        middleware = .init()  // Clear Vapor's default middleware (includes RouteLoggingMiddleware)
        middleware.use(LoggingMiddleware())
        middleware.use(RateLimitMiddleware())

        // Serves the generated API reference (index.html + openapi.json) at the web root.
        middleware.use(FileMiddleware(publicDirectory: directory.publicDirectory))

        // Converts errors to { "error": ..., "message": ..., "statusCode": ... }
        middleware.use(TricountErrorMiddleware())
    }
}
