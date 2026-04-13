import Vapor

/// Handles authenticated account and profile-verification endpoints.
struct AuthAccountController: DocumentedRouteCollection {
    func boot(routes: DocumentedRoutesBuilder) throws {
        routes.getData("me", use: me)

        routes.postData("verify-profile", "google", use: verifyGoogleProfile)
        routes.postData("verify-profile", "apple", use: verifyAppleProfile)
        routes.postData("verify-profile", "email", "request-otp", use: requestEmailVerificationOTP)
            .rateLimit(.custom(
                identifier: "auth.verify-email-otp",
                limit: 5,
                windowSeconds: 3600
            ))
        routes.postData("verify-profile", "email", "confirm", use: confirmEmailVerificationOTP)
        routes.postNoContent("logout", use: logout)
    }

    @Sendable
    func me(req: Request) async throws -> UserDTO {
        UserDTO(from: try await req.authService.currentUser())
    }

    @Sendable
    func verifyGoogleProfile(req: Request, body: VerifyProfileRequest) async throws -> UserDTO {
        try await req.authService.verifyGoogleProfile(dto: body)
    }

    @Sendable
    func verifyAppleProfile(req: Request, body: VerifyProfileRequest) async throws -> UserDTO {
        try await req.authService.verifyAppleProfile(dto: body)
    }

    @Sendable
    func requestEmailVerificationOTP(req: Request) async throws -> MessageResponse {
        try await req.authService.requestEmailVerificationOTP()
    }

    @Sendable
    func confirmEmailVerificationOTP(req: Request, body: VerifyEmailOTPRequest) async throws -> UserDTO {
        try await req.authService.confirmEmailVerificationOTP(dto: body)
    }

    @Sendable
    func logout(req: Request) async throws {
        try await req.authService.logout()
    }
}
