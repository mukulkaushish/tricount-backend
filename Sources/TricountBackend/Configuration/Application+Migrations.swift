import Fluent
import Vapor

extension Application {
    func configureMigrations() {
        // Execution order is defined by this registration list, not by folder order.
        // The numeric filename prefixes in `Sources/TricountBackend/Migrations/` are
        // only there to make the chronology obvious to humans.
        migrations.add(CreateUser())
        migrations.add(AddUserVerificationFields())
        migrations.add(AddAppleIdentifierToUsers())
        migrations.add(CreateEmailVerificationOTP())
        migrations.add(CreateRefreshToken())
        migrations.add(CreatePasskeyCredential())
        migrations.add(CreatePasskeyChallenge())
        migrations.add(AddMFAFieldsToUsers())
        migrations.add(CreatePasswordResetOTP())
        migrations.add(CreateEmailMFAChallenge())
        migrations.add(AddMethodToEmailMFAChallenges())
        migrations.add(AddPhoneAndAuthenticatorFieldsToUsers())
        migrations.add(CreatePhoneVerificationOTP())
        migrations.add(CreateAuthenticatorAppSetupChallenge())
        migrations.add(CreateBackupCode())
        migrations.add(AddPerformanceIndexes())
        migrations.add(AddBackupCodeIndexes())
    }
}
