import Crypto
import Foundation
import Vapor

enum TOTPService {
    static let digits = 6
    static let period = 30

    static func generateSecret(byteCount: Int = 20) -> String {
        let key = SymmetricKey(size: .bits256)
        return key.withUnsafeBytes { bytes in
            let data = Data(bytes.prefix(byteCount))
            return Base32.encode(data)
        }
    }

    static func generateCode(secret: String, at date: Date = Date()) throws -> String {
        let secretData = try Base32.decode(secret)
        let counter = UInt64(floor(date.timeIntervalSince1970 / Double(period)))
        return try hotp(secretData: secretData, counter: counter)
    }

    static func verify(code: String, secret: String, at date: Date = Date(), allowedDriftWindows: Int = 1) throws -> Bool {
        let secretData = try Base32.decode(secret)
        let counter = Int64(floor(date.timeIntervalSince1970 / Double(period)))

        for drift in (-allowedDriftWindows)...allowedDriftWindows {
            let candidateCounter = counter + Int64(drift)
            guard candidateCounter >= 0 else { continue }
            let candidate = try hotp(secretData: secretData, counter: UInt64(candidateCounter))
            if candidate == code {
                return true
            }
        }

        return false
    }

    static func otpauthURL(secret: String, issuer: String, accountName: String) -> String {
        let encodedIssuer = issuer.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? issuer
        let encodedAccount = accountName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? accountName
        let encodedIssuerQuery = issuer.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? issuer
        let encodedSecret = secret.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? secret

        return "otpauth://totp/\(encodedIssuer):\(encodedAccount)?secret=\(encodedSecret)&issuer=\(encodedIssuerQuery)&algorithm=SHA1&digits=\(digits)&period=\(period)"
    }

    private static func hotp(secretData: Data, counter: UInt64) throws -> String {
        var bigEndianCounter = counter.bigEndian
        let message = withUnsafeBytes(of: &bigEndianCounter) { Data($0) }
        let key = SymmetricKey(data: secretData)
        let digest = HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key)
        let hash = Data(digest)

        guard let last = hash.last else {
            throw Abort(.internalServerError, reason: "Unable to generate TOTP code")
        }

        let offset = Int(last & 0x0f)
        guard offset + 4 <= hash.count else {
            throw Abort(.internalServerError, reason: "Unable to generate TOTP code")
        }

        let slice = hash[offset ..< offset + 4]
        let truncated = slice.reduce(UInt32.zero) { ($0 << 8) | UInt32($1) } & 0x7fff_ffff
        let modulus = UInt32(pow(10.0, Double(digits)))
        let code = truncated % modulus
        return String(format: "%0*u", digits, code)
    }
}

private enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    private static let lookup = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($1, UInt8($0)) })

    static func encode(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }

        var result = ""
        var buffer = 0
        var bitsLeft = 0

        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bitsLeft += 8

            while bitsLeft >= 5 {
                let index = (buffer >> (bitsLeft - 5)) & 0x1f
                result.append(alphabet[index])
                bitsLeft -= 5
            }
        }

        if bitsLeft > 0 {
            let index = (buffer << (5 - bitsLeft)) & 0x1f
            result.append(alphabet[index])
        }

        return result
    }

    static func decode(_ string: String) throws -> Data {
        let normalized = string
            .uppercased()
            .replacingOccurrences(of: "=", with: "")
            .filter { !$0.isWhitespace }

        guard !normalized.isEmpty else {
            throw Abort(.badRequest, reason: "Authenticator secret is empty")
        }

        var buffer = 0
        var bitsLeft = 0
        var bytes: [UInt8] = []

        for character in normalized {
            guard let value = lookup[character] else {
                throw Abort(.badRequest, reason: "Authenticator secret is invalid")
            }

            buffer = (buffer << 5) | Int(value)
            bitsLeft += 5

            while bitsLeft >= 8 {
                let byte = UInt8((buffer >> (bitsLeft - 8)) & 0xff)
                bytes.append(byte)
                bitsLeft -= 8
            }
        }

        return Data(bytes)
    }
}
