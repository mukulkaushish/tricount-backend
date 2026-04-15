import Vapor

extension Application {
    func configureMiddleware() {
        logger.logLevel = runtimeConfiguration.observability.logLevel

        middleware = .init()  // Clear Vapor's default middleware (includes RouteLoggingMiddleware)
        middleware.use(LoggingMiddleware())
        middleware.use(RateLimitMiddleware())

        // Serves static files from the Public/ directory
        middleware.use(FileMiddleware(publicDirectory: directory.publicDirectory))

        // Converts errors to { "error": ..., "message": ..., "statusCode": ... }
        middleware.use(TricountErrorMiddleware())
    }
}
