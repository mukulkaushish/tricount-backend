import Vapor

private struct DebugResponseHeadersKey: StorageKey {
    typealias Value = HTTPHeaders
}

extension Request {
    var authenticatedUserID: UUID {
        get throws {
            let payload = try jwtPayload
            guard let userID = UUID(uuidString: payload.userId) else {
                throw AuthError.invalidToken
            }
            return userID
        }
    }

    var isProductionEnvironment: Bool {
        application.environment == .production
    }

    var isDevelopmentEnvironment: Bool {
        application.environment == .development
    }

    func logSensitiveDevelopmentValue(_ message: Logger.Message, metadata: Logger.Metadata = [:]) {
        guard isDevelopmentEnvironment else { return }
        logger.info(message, metadata: metadata)
    }

    func setDevelopmentDebugHeader(name: String, value: String) {
        guard isDevelopmentEnvironment else { return }

        var headers = storage[DebugResponseHeadersKey.self] ?? HTTPHeaders()
        headers.replaceOrAdd(name: name, value: value)
        storage[DebugResponseHeadersKey.self] = headers
    }

    func applyDevelopmentDebugHeaders(to response: Response) {
        guard isDevelopmentEnvironment,
              let headers = storage[DebugResponseHeadersKey.self] else {
            return
        }

        for header in headers {
            response.headers.replaceOrAdd(name: header.name, value: header.value)
        }
    }

    func requireUUIDParameter(_ name: String) throws -> UUID {
        guard let rawValue = parameters.get(name),
              let value = UUID(uuidString: rawValue) else {
            throw Abort(.badRequest, reason: "Invalid or missing '\(name)' route parameter.")
        }

        return value
    }
}
