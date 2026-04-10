@testable import TricountBackend
import Vapor
import VaporTesting

extension TestingHTTPResponse {
    func decodeBody<T: Content>(_ type: T.Type = T.self) throws -> T {
        try content.decode(type)
    }

    func decodeData<T: Content>(_ type: T.Type = T.self) throws -> T {
        try decodeBody(type)
    }

    var bodyString: String {
        var copy = body
        return copy.readString(length: copy.readableBytes) ?? ""
    }
}
