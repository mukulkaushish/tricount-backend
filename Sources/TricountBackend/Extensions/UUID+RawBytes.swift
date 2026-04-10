import Foundation

extension UUID {
    var rawBytes: Data {
        var uuid = uuid
        return withUnsafeBytes(of: &uuid) { Data($0) }
    }
}
