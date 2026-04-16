import Vapor

protocol AuthEmailDispatching: Sendable {
    func sendVerificationOTP(to email: String, code: String, displayName: String) async throws
    func sendPasswordResetOTP(to email: String, code: String, displayName: String) async throws
    func sendMFALoginOTP(to email: String, code: String, displayName: String) async throws
    func sendMFAEnableOTP(to email: String, code: String, displayName: String) async throws
    func sendGroupInvitation(to email: String, inviteeName: String, groupName: String, inviterName: String, inviteToken: String) async throws
}

struct LoggingAuthEmailDispatcher: AuthEmailDispatching {
    let logger: Logger
    let environment: Environment

    func sendVerificationOTP(to email: String, code: String, displayName: String) async throws {
        log(codeType: "Email verification OTP generated", email: email, code: code, displayName: displayName)
    }

    func sendPasswordResetOTP(to email: String, code: String, displayName: String) async throws {
        log(codeType: "Password reset OTP generated", email: email, code: code, displayName: displayName)
    }

    func sendMFALoginOTP(to email: String, code: String, displayName: String) async throws {
        log(codeType: "MFA login OTP generated", email: email, code: code, displayName: displayName)
    }

    func sendMFAEnableOTP(to email: String, code: String, displayName: String) async throws {
        log(codeType: "MFA enable OTP generated", email: email, code: code, displayName: displayName)
    }

    func sendGroupInvitation(to email: String, inviteeName: String, groupName: String, inviterName: String, inviteToken: String) async throws {
        guard environment == .development else { return }
        logger.info(
            "Group invitation dispatched",
            metadata: [
                "email": .string(email),
                "inviteeName": .string(inviteeName),
                "groupName": .string(groupName),
                "inviterName": .string(inviterName),
                "inviteToken": .string(inviteToken)
            ]
        )
    }

    private func log(codeType: String, email: String, code: String, displayName: String) {
        guard environment == .development else { return }
        logger.info(
            "\(codeType)",
            metadata: [
                "email": .string(email),
                "displayName": .string(displayName),
                "code": .string(code)
            ]
        )
    }
}

extension Application {
    private struct AuthEmailDispatcherFactoryKey: StorageKey {
        typealias Value = @Sendable (Request) -> any AuthEmailDispatching
    }

    var authEmailDispatcherFactory: @Sendable (Request) -> any AuthEmailDispatching {
        get {
            self.storage[AuthEmailDispatcherFactoryKey.self] ?? { request in
                LoggingAuthEmailDispatcher(
                    logger: request.logger,
                    environment: request.application.environment
                )
            }
        }
        set {
            self.storage[AuthEmailDispatcherFactoryKey.self] = newValue
        }
    }
}

extension Request {
    var authEmailDispatcher: any AuthEmailDispatching {
        self.application.authEmailDispatcherFactory(self)
    }
}
