import Vapor

private let routeDocumentationUserInfoKey: AnySendableHashable = "tricount.route-documentation"

extension Route {
    var routeDocumentationMetadata: RouteDocumentationMetadata? {
        get { userInfo[routeDocumentationUserInfoKey] as? RouteDocumentationMetadata }
        set { userInfo[routeDocumentationUserInfoKey] = newValue }
    }
}

extension RoutesBuilder {
    func documented(auth: RouteDocumentationAuth = .none) -> DocumentedRoutesBuilder {
        DocumentedRoutesBuilder(base: self, defaultAuth: auth)
    }
}

struct DocumentedRoutesBuilder {
    private let base: any RoutesBuilder
    private let defaultAuth: RouteDocumentationAuth

    init(base: any RoutesBuilder, defaultAuth: RouteDocumentationAuth = .none) {
        self.base = base
        self.defaultAuth = defaultAuth
    }

    func grouped(_ path: PathComponent...) -> DocumentedRoutesBuilder {
        grouped(path)
    }

    func grouped(_ path: [PathComponent]) -> DocumentedRoutesBuilder {
        DocumentedRoutesBuilder(base: base.grouped(path), defaultAuth: defaultAuth)
    }

    func grouped(_ middleware: any Middleware...) -> DocumentedRoutesBuilder {
        DocumentedRoutesBuilder(base: base.grouped(middleware), defaultAuth: defaultAuth)
    }

    func bearerProtected() -> DocumentedRoutesBuilder {
        DocumentedRoutesBuilder(base: base.grouped(JWTAuthMiddleware()), defaultAuth: .bearer)
    }

    @discardableResult
    func getRaw<ResponseBody: Content>(
        status: HTTPStatus = .ok,
        use closure: @Sendable @escaping (Request) async throws -> ResponseBody
    ) -> Route {
        getRaw([], status: status, use: closure)
    }

    @discardableResult
    func getRaw<ResponseBody: Content>(
        _ path: PathComponent...,
        status: HTTPStatus = .ok,
        use closure: @Sendable @escaping (Request) async throws -> ResponseBody
    ) -> Route {
        getRaw(path, status: status, use: closure)
    }

    @discardableResult
    func getRaw<ResponseBody: Content>(
        _ path: [PathComponent],
        status: HTTPStatus = .ok,
        use closure: @Sendable @escaping (Request) async throws -> ResponseBody
    ) -> Route {
        let metadata = RouteDocumentationMetadata(
            auth: defaultAuth,
            requestBody: nil,
            successResponse: .raw(ResponseBody.self, status: status)
        )

        return register(method: .GET, path: path, metadata: metadata) { request in
            let responseBody = try await closure(request)
            return try Response.json(responseBody, status: status)
        }
    }

    @discardableResult
    func getData<ResponseBody: Content>(
        status: HTTPStatus = .ok,
        use closure: @Sendable @escaping (Request) async throws -> ResponseBody
    ) -> Route {
        getData([], status: status, use: closure)
    }

    @discardableResult
    func getData<ResponseBody: Content>(
        _ path: PathComponent...,
        status: HTTPStatus = .ok,
        use closure: @Sendable @escaping (Request) async throws -> ResponseBody
    ) -> Route {
        getData(path, status: status, use: closure)
    }

    @discardableResult
    func getData<ResponseBody: Content>(
        _ path: [PathComponent],
        status: HTTPStatus = .ok,
        use closure: @Sendable @escaping (Request) async throws -> ResponseBody
    ) -> Route {
        let metadata = RouteDocumentationMetadata(
            auth: defaultAuth,
            requestBody: nil,
            successResponse: .raw(ResponseBody.self, status: status)
        )

        return register(method: .GET, path: path, metadata: metadata) { request in
            let responseBody = try await closure(request)
            return try Response.json(responseBody, status: status)
        }
    }

    @discardableResult
    func postRaw<RequestBody: Content, ResponseBody: Content>(
        _ path: PathComponent...,
        status: HTTPStatus = .ok,
        use closure: @Sendable @escaping (Request, RequestBody) async throws -> ResponseBody
    ) -> Route {
        postRaw(path, status: status, use: closure)
    }

    @discardableResult
    func postRaw<RequestBody: Content, ResponseBody: Content>(
        _ path: [PathComponent],
        status: HTTPStatus = .ok,
        use closure: @Sendable @escaping (Request, RequestBody) async throws -> ResponseBody
    ) -> Route {
        let metadata = RouteDocumentationMetadata(
            auth: defaultAuth,
            requestBody: .json(RequestBody.self),
            successResponse: .raw(ResponseBody.self, status: status)
        )

        return register(method: .POST, path: path, metadata: metadata) { request in
            let requestBody = try request.decodeContent(RequestBody.self)
            let responseBody = try await closure(request, requestBody)
            return try Response.json(responseBody, status: status)
        }
    }

    @discardableResult
    func postData<RequestBody: Content, ResponseBody: Content>(
        _ path: PathComponent...,
        status: HTTPStatus = .ok,
        use closure: @Sendable @escaping (Request, RequestBody) async throws -> ResponseBody
    ) -> Route {
        postData(path, status: status, use: closure)
    }

    @discardableResult
    func postData<RequestBody: Content, ResponseBody: Content>(
        _ path: [PathComponent],
        status: HTTPStatus = .ok,
        use closure: @Sendable @escaping (Request, RequestBody) async throws -> ResponseBody
    ) -> Route {
        let metadata = RouteDocumentationMetadata(
            auth: defaultAuth,
            requestBody: .json(RequestBody.self),
            successResponse: .raw(ResponseBody.self, status: status)
        )

        return register(method: .POST, path: path, metadata: metadata) { request in
            let requestBody = try request.decodeContent(RequestBody.self)
            let responseBody = try await closure(request, requestBody)
            return try Response.json(responseBody, status: status)
        }
    }

    @discardableResult
    func postData<ResponseBody: Content>(
        _ path: PathComponent...,
        status: HTTPStatus = .ok,
        use closure: @Sendable @escaping (Request) async throws -> ResponseBody
    ) -> Route {
        postData(path, status: status, use: closure)
    }

    @discardableResult
    func postData<ResponseBody: Content>(
        _ path: [PathComponent],
        status: HTTPStatus = .ok,
        use closure: @Sendable @escaping (Request) async throws -> ResponseBody
    ) -> Route {
        let metadata = RouteDocumentationMetadata(
            auth: defaultAuth,
            requestBody: nil,
            successResponse: .raw(ResponseBody.self, status: status)
        )

        return register(method: .POST, path: path, metadata: metadata) { request in
            let responseBody = try await closure(request)
            return try Response.json(responseBody, status: status)
        }
    }

    @discardableResult
    func postNoContent(
        _ path: PathComponent...,
        status: HTTPStatus = .noContent,
        use closure: @Sendable @escaping (Request) async throws -> Void
    ) -> Route {
        postNoContent(path, status: status, use: closure)
    }

    @discardableResult
    func postNoContent(
        _ path: [PathComponent],
        status: HTTPStatus = .noContent,
        use closure: @Sendable @escaping (Request) async throws -> Void
    ) -> Route {
        let metadata = RouteDocumentationMetadata(
            auth: defaultAuth,
            requestBody: nil,
            successResponse: .empty(status: status)
        )

        return register(method: .POST, path: path, metadata: metadata) { request in
            try await closure(request)
            return Response(status: status)
        }
    }

    @discardableResult
    func deleteNoContent(
        _ path: PathComponent...,
        status: HTTPStatus = .noContent,
        use closure: @Sendable @escaping (Request) async throws -> Void
    ) -> Route {
        deleteNoContent(path, status: status, use: closure)
    }

    @discardableResult
    func deleteNoContent(
        _ path: [PathComponent],
        status: HTTPStatus = .noContent,
        use closure: @Sendable @escaping (Request) async throws -> Void
    ) -> Route {
        let metadata = RouteDocumentationMetadata(
            auth: defaultAuth,
            requestBody: nil,
            successResponse: .empty(status: status)
        )

        return register(method: .DELETE, path: path, metadata: metadata) { request in
            try await closure(request)
            return Response(status: status)
        }
    }

    private func register(
        method: HTTPMethod,
        path: [PathComponent],
        metadata: RouteDocumentationMetadata,
        use closure: @Sendable @escaping (Request) async throws -> Response
    ) -> Route {
        let route = base.on(method, path, use: closure)
        route.routeDocumentationMetadata = metadata
        return route
    }
}
