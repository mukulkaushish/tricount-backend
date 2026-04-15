import Fluent
import Vapor
import Foundation

/// Authenticated account and profile verification workflows.
extension AuthService {
    // MARK: - Verify Profile

    func verifyGoogleProfile(dto: VerifyProfileRequest) async throws -> UserDTO {
        let googleProfile = try await googleProfile(from: dto.idToken)
        return try await verifyProfile(with: googleProfile)
    }

    func verifyAppleProfile(dto: VerifyProfileRequest) async throws -> UserDTO {
        let appleProfile = try await appleProfile(from: dto.idToken)
        return try await verifyProfile(with: appleProfile)
    }

    func requestEmailVerificationOTP() async throws -> MessageResponse {
        let user = try await currentUser()

        guard !user.isEmailVerified else {
            return MessageResponse(message: "Email is already verified.")
        }

        let code = try await replaceEmailVerificationOTP(for: user)
        try await req.authEmailDispatcher.sendVerificationOTP(
            to: user.email,
            code: code,
            displayName: user.displayName
        )
        req.setDevelopmentDebugHeader(name: "X-Debug-OTP-Code", value: code)

        return MessageResponse(message: "Verification code sent to \(user.email).")
    }

    func confirmEmailVerificationOTP(dto: VerifyEmailOTPRequest) async throws -> UserDTO {
        let code = try normalizeSixDigitCode(
            dto.code,
            reason: "Verification code must be a 6-digit number"
        )

        let user = try await currentUser()
        guard let userId = user.id else {
            throw Abort(.internalServerError)
        }

        guard let otp = try await EmailVerificationOTP.query(on: req.db)
            .filter(\.$user.$id == userId)
            .filter(\.$codeHash == sha256(code))
            .filter(\.$isUsed == false)
            .sort(\.$createdAt, .descending)
            .first(),
              otp.isValid,
              otp.email == user.email
        else {
            throw AuthError.verificationOTPInvalid
        }

        otp.isUsed = true
        try await otp.save(on: req.db)

        user.isEmailVerified = true
        user.verifiedAt = user.verifiedAt ?? Date()
        try await user.save(on: req.db)

        return UserDTO(from: user)
    }

    // MARK: - Account Helpers

    func verifyProfile(with profile: SocialIdentityProfile) async throws -> UserDTO {
        let user = try await currentUser()
        guard let normalizedEmail = profile.normalizedEmail else {
            throw AuthError.appleEmailMissing
        }

        guard normalizedEmail == user.email else {
            throw AuthError.verificationEmailMismatch
        }

        try await syncVerifiedSocialProfile(profile, to: user)
        return UserDTO(from: user)
    }

    func replaceEmailVerificationOTP(for user: User) async throws -> String {
        guard let userId = user.id else {
            throw Abort(.internalServerError)
        }

        try await EmailVerificationOTP.query(on: req.db)
            .filter(\.$user.$id == userId)
            .filter(\.$isUsed == false)
            .set(\.$isUsed, to: true)
            .update()

        let code = generateOTPCode()
        let otp = EmailVerificationOTP(
            userId: userId,
            email: user.email,
            codeHash: sha256(code),
            expiresAt: EmailVerificationOTP.expirationFromNow
        )
        try await otp.save(on: req.db)
        return code
    }
}
