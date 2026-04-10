import Foundation

enum AuthValidation {
    static func normalizeEmail(_ email: String) -> String {
        email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isValidEmail(_ email: String) -> Bool {
        let regex = #"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#
        return email.range(of: regex, options: .regularExpression) != nil
    }

    static func normalizePhoneNumber(_ phoneNumber: String) -> String {
        let trimmed = phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ""

        for (index, character) in trimmed.enumerated() {
            if character == "+", index == 0 {
                result.append(character)
                continue
            }

            if character.isNumber {
                result.append(character)
            }
        }

        if !result.hasPrefix("+"), result.allSatisfy(\.isNumber), !result.isEmpty {
            result = "+" + result
        }

        return result
    }

    static func isValidPhoneNumber(_ phoneNumber: String) -> Bool {
        let regex = #"^\+[1-9][0-9]{7,14}$"#
        return phoneNumber.range(of: regex, options: .regularExpression) != nil
    }
}
