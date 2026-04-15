import Fluent
import Vapor
import Foundation

/// Password recovery and reset workflows.
extension AuthService {
    // MARK: - Forgot Password

    func forgotPassword(dto: ForgotPasswordRequest) async throws {
        let email = AuthValidation.normalizeEmail(dto.email)
        req.logger.info("Password reset requested", metadata: ["email": .string(email)])

        guard let user = try await User.query(on: req.db)
            .filter(\.$email == email)
            .filter(\.$provider == "email")
            .first(),
              user.passwordHash != nil
        else {
            return
        }

        let code = try await replacePasswordResetOTP(for: user)
        try await req.authEmailDispatcher.sendPasswordResetOTP(
            to: user.email,
            code: code,
            displayName: user.displayName
        )
        req.setDevelopmentDebugHeader(name: "X-Debug-OTP-Code", value: code)
    }

    func resetPassword(dto: ResetPasswordRequest) async throws -> MessageResponse {
        let email = AuthValidation.normalizeEmail(dto.email)
        guard AuthValidation.isValidEmail(email) else {
            throw Abort(.unprocessableEntity, reason: "Invalid email format")
        }

        try validatePassword(dto.newPassword)
        let code = try normalizeSixDigitCode(dto.code, reason: "Password reset code must be a 6-digit number")

        guard let user = try await User.query(on: req.db)
            .filter(\.$email == email)
            .filter(\.$provider == "email")
            .first(),
              user.passwordHash != nil,
              let userId = user.id
        else {
            throw AuthError.passwordResetCodeInvalid
        }

        guard let resetCode = try await PasswordResetOTP.query(on: req.db)
            .filter(\.$user.$id == userId)
            .filter(\.$email == email)
            .filter(\.$codeHash == sha256(code))
            .filter(\.$isUsed == false)
            .sort(\.$createdAt, .descending)
            .first(),
              resetCode.isValid
        else {
            throw AuthError.passwordResetCodeInvalid
        }

        resetCode.isUsed = true
        try await resetCode.save(on: req.db)

        user.passwordHash = try await req.passwordHasher.hash(dto.newPassword, on: req.eventLoop)
        try await user.save(on: req.db)

        try await revokeActiveRefreshTokens(for: userId)

        return MessageResponse(message: "Password has been reset.")
    }

    // MARK: - Recovery Helpers

    func replacePasswordResetOTP(for user: User) async throws -> String {
        guard let userId = user.id else {
            throw Abort(.internalServerError)
        }

        try await PasswordResetOTP.query(on: req.db)
            .filter(\.$user.$id == userId)
            .filter(\.$isUsed == false)
            .set(\.$isUsed, to: true)
            .update()

        let code = generateOTPCode()
        let otp = PasswordResetOTP(
            userId: userId,
            email: user.email,
            codeHash: sha256(code),
            expiresAt: PasswordResetOTP.expirationFromNow
        )
        try await otp.save(on: req.db)
        return code
    }
}
