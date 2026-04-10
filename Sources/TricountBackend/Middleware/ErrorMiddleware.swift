import Vapor

/// Converts all thrown errors (Vapor `Abort`, `AuthError`, or unknown) into the
/// standard API shape: `{ "error": "CODE", "message": "...", "statusCode": N }`.
struct TricountErrorMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        do {
            return try await next.respond(to: request)
        } catch let authErr as AuthError {
            return errorResponse(
                code: authErr.errorCode,
                message: authErr.reason,
                status: authErr.status,
                for: request
            )
        } catch let abort as any AbortError {
            let code = httpStatusToCode(abort.status)
            return errorResponse(
                code: code,
                message: abort.reason,
                status: abort.status,
                for: request
            )
        } catch {
            request.logger.error(
                "Unhandled error",
                metadata: [
                    "errorType": .string(String(reflecting: type(of: error))),
                    "error": .string(String(reflecting: error))
                ]
            )
            return errorResponse(
                code: "INTERNAL_SERVER_ERROR",
                message: "An unexpected error occurred.",
                status: .internalServerError,
                for: request
            )
        }
    }

    private func errorResponse(
        code: String,
        message: String,
        status: HTTPStatus,
        for req: Request
    ) -> Response {
        let body = ErrorResponse(error: code, message: message, statusCode: Int(status.code))
        return (try? Response.data(body, status: status)) ?? Response(status: status)
    }

    private func httpStatusToCode(_ status: HTTPStatus) -> String {
        switch status {
        case .badRequest:          return "BAD_REQUEST"
        case .unauthorized:        return "UNAUTHORIZED"
        case .forbidden:           return "FORBIDDEN"
        case .notFound:            return "NOT_FOUND"
        case .conflict:            return "CONFLICT"
        case .unprocessableEntity: return "VALIDATION_ERROR"
        case .tooManyRequests:     return "RATE_LIMIT_EXCEEDED"
        default:                   return "INTERNAL_SERVER_ERROR"
        }
    }
}
