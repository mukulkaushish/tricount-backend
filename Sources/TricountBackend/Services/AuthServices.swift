import Vapor

/// Capability-scoped auth service access for controllers.
///
/// Controllers should depend on the capability they expose rather than the
/// internal `AuthService` implementation shape. This keeps route ownership
/// aligned with service ownership while preserving the existing API contract.
struct AuthServices {
    let req: Request

    var session: AuthSessionService {
        AuthSessionService(req: req)
    }

    var account: AuthAccountService {
        AuthAccountService(req: req)
    }

    var mfaLogin: AuthMFALoginService {
        AuthMFALoginService(req: req)
    }

    var mfaSettings: AuthMFASettingsService {
        AuthMFASettingsService(req: req)
    }

    var passkeys: AuthPasskeyManagementService {
        AuthPasskeyManagementService(req: req)
    }
}

struct AuthSessionService {
    let req: Request

    private var core: AuthService {
        AuthService(req: req)
    }

    func login(dto: LoginRequest) async throws -> AuthenticationResultResponse {
        try await core.login(dto: dto)
    }

    func register(dto: RegisterRequest) async throws -> AuthResponse {
        try await core.register(dto: dto)
    }

    func forgotPassword(dto: ForgotPasswordRequest) async throws {
        try await core.forgotPassword(dto: dto)
    }

    func resetPassword(dto: ResetPasswordRequest) async throws -> MessageResponse {
        try await core.resetPassword(dto: dto)
    }

    func googleSignIn(dto: GoogleLoginRequest) async throws -> AuthenticationResultResponse {
        try await core.googleSignIn(dto: dto)
    }

    func appleSignIn(dto: AppleLoginRequest) async throws -> AuthenticationResultResponse {
        try await core.appleSignIn(dto: dto)
    }

    func refresh(dto: RefreshTokenRequest) async throws -> TokenRefreshResponse {
        try await core.refresh(dto: dto)
    }

    func beginPasskeyAuthentication(
        dto: PasskeyAuthenticationOptionsRequest
    ) async throws -> PasskeyAuthenticationOptionsResponse {
        try await core.beginPasskeyAuthentication(dto: dto)
    }

    func finishPasskeyAuthentication(
        dto: PasskeyAuthenticationVerificationRequest
    ) async throws -> AuthenticationResultResponse {
        try await core.finishPasskeyAuthentication(dto: dto)
    }
}

struct AuthAccountService {
    let req: Request

    private var core: AuthService {
        AuthService(req: req)
    }

    func currentUser() async throws -> User {
        try await core.currentUser()
    }

    func verifyGoogleProfile(dto: VerifyProfileRequest) async throws -> UserDTO {
        try await core.verifyGoogleProfile(dto: dto)
    }

    func verifyAppleProfile(dto: VerifyProfileRequest) async throws -> UserDTO {
        try await core.verifyAppleProfile(dto: dto)
    }

    func requestEmailVerificationOTP() async throws -> MessageResponse {
        try await core.requestEmailVerificationOTP()
    }

    func confirmEmailVerificationOTP(dto: VerifyEmailOTPRequest) async throws -> UserDTO {
        try await core.confirmEmailVerificationOTP(dto: dto)
    }

    func logout() async throws {
        try await core.logout()
    }
}

struct AuthMFALoginService {
    let req: Request

    private var core: AuthService {
        AuthService(req: req)
    }

    func verifyEmail(dto: MFALoginVerifyRequest) async throws -> AuthResponse {
        try await core.verifyEmailMFALogin(dto: dto)
    }

    func verifyPhone(dto: MFALoginVerifyRequest) async throws -> AuthResponse {
        try await core.verifyPhoneMFALogin(dto: dto)
    }

    func verifyAuthenticatorApp(dto: MFALoginVerifyRequest) async throws -> AuthResponse {
        try await core.verifyAuthenticatorAppMFALogin(dto: dto)
    }

    func verifyBackupCode(dto: MFALoginVerifyRequest) async throws -> AuthResponse {
        try await core.verifyBackupCodeMFALogin(dto: dto)
    }

    func beginPasskey(dto: PasskeyMFALoginOptionsRequest) async throws -> PasskeyAuthenticationOptionsResponse {
        try await core.beginPasskeyMFALogin(dto: dto)
    }

    func finishPasskey(dto: PasskeyMFALoginVerificationRequest) async throws -> AuthResponse {
        try await core.finishPasskeyMFALogin(dto: dto)
    }
}

struct AuthMFASettingsService {
    let req: Request

    private var core: AuthService {
        AuthService(req: req)
    }

    func enable(dto: EnableMFARequest) async throws -> UserDTO {
        try await core.enableMFA(dto: dto)
    }

    func disable() async throws -> UserDTO {
        try await core.disableMFA()
    }

    func requestEmailEnable() async throws -> MessageResponse {
        try await core.requestEmailMFAEnable()
    }

    func confirmEmailEnable(dto: ConfirmEmailMFAEnableRequest) async throws -> UserDTO {
        try await core.confirmEmailMFAEnable(dto: dto)
    }

    func disableEmail() async throws -> UserDTO {
        try await core.disableEmailMFA()
    }

    func beginAuthenticatorAppSetup() async throws -> AuthenticatorAppMFASetupResponse {
        try await core.beginAuthenticatorAppMFASetup()
    }

    func confirmAuthenticatorAppEnable(dto: ConfirmEmailMFAEnableRequest) async throws -> UserDTO {
        try await core.confirmAuthenticatorAppMFAEnable(dto: dto)
    }

    func disableAuthenticatorApp() async throws -> UserDTO {
        try await core.disableAuthenticatorAppMFA()
    }

    func generateBackupCodes() async throws -> BackupCodesResponse {
        try await core.generateBackupCodes()
    }

    func regenerateBackupCodes() async throws -> BackupCodesResponse {
        try await core.regenerateBackupCodes()
    }

    func requestPhoneVerification(dto: SetupPhoneVerificationRequest) async throws -> MessageResponse {
        try await core.requestPhoneVerification(dto: dto)
    }

    func confirmPhoneVerification(dto: ConfirmPhoneVerificationRequest) async throws -> UserDTO {
        try await core.confirmPhoneVerification(dto: dto)
    }

    func removePhoneNumber() async throws -> UserDTO {
        try await core.removePhoneNumber()
    }
}

struct AuthPasskeyManagementService {
    let req: Request

    private var core: AuthService {
        AuthService(req: req)
    }

    func list() async throws -> [PasskeyCredentialDTO] {
        try await core.listPasskeys()
    }

    func remove(dto: RemovePasskeyRequest) async throws -> MessageResponse {
        try await core.removePasskey(dto: dto)
    }

    func reset() async throws -> MessageResponse {
        try await core.resetPasskeys()
    }

    func beginRegistration() async throws -> PasskeyRegistrationOptionsResponse {
        try await core.beginPasskeyRegistration()
    }

    func finishRegistration(dto: PasskeyRegistrationVerificationRequest) async throws -> PasskeyCredentialDTO {
        try await core.finishPasskeyRegistration(dto: dto)
    }
}

extension Request {
    var authServices: AuthServices {
        AuthServices(req: self)
    }
}
