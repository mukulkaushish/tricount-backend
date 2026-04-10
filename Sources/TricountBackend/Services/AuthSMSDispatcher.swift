import Vapor

protocol AuthSMSDispatching: Sendable {
    func sendPhoneVerificationOTP(to phoneNumber: String, code: String) async throws
}

struct LoggingAuthSMSDispatcher: AuthSMSDispatching {
    let logger: Logger

    func sendPhoneVerificationOTP(to phoneNumber: String, code: String) async throws {
        logger.info(
            "Phone verification OTP generated",
            metadata: [
                "phoneNumber": .string(phoneNumber),
                "code": .string(code)
            ]
        )
    }
}

extension Application {
    private struct AuthSMSDispatcherFactoryKey: StorageKey {
        typealias Value = @Sendable (Request) -> any AuthSMSDispatching
    }

    var authSMSDispatcherFactory: @Sendable (Request) -> any AuthSMSDispatching {
        get {
            self.storage[AuthSMSDispatcherFactoryKey.self] ?? { request in
                LoggingAuthSMSDispatcher(logger: request.logger)
            }
        }
        set {
            self.storage[AuthSMSDispatcherFactoryKey.self] = newValue
        }
    }
}

extension Request {
    var authSMSDispatcher: any AuthSMSDispatching {
        self.application.authSMSDispatcherFactory(self)
    }
}
