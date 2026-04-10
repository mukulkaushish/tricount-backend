import Vapor

extension Request {
    func decodeContent<T: Content>(_ type: T.Type = T.self) throws -> T {
        try content.decode(type)
    }

    func dataResponse<T: Content>(
        _ value: T,
        status: HTTPStatus = .ok
    ) throws -> Response {
        try Response.data(value, status: status)
    }

    func htmlResponse(
        _ html: String,
        status: HTTPStatus = .ok
    ) -> Response {
        Response.html(html, status: status)
    }
}

extension Response {
    static func json<T: Content>(
        _ value: T,
        status: HTTPStatus = .ok
    ) throws -> Response {
        let response = Response(status: status)
        response.headers.contentType = .json
        try response.content.encode(value)
        return response
    }

    static func data<T: Content>(
        _ value: T,
        status: HTTPStatus = .ok
    ) throws -> Response {
        let response = Response(status: status)
        response.headers.contentType = .json
        try response.content.encode(value)
        return response
    }

    static func html(
        _ html: String,
        status: HTTPStatus = .ok
    ) -> Response {
        let response = Response(status: status)
        response.headers.contentType = .html
        response.body = .init(string: html)
        return response
    }
}
