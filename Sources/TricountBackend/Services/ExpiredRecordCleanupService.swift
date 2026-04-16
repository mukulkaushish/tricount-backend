import Vapor
import Fluent

private struct CleanupTaskKey: StorageKey {
    typealias Value = Task<Void, Never>
}

/// Purges expired OTP codes, challenges, and revoked refresh tokens.
///
/// Runs as a recurring background task every hour. Deletes records whose
/// `expiresAt` is older than `Date() - 14 minutes` (a safety buffer so
/// tokens that just expired aren't cleaned up while still being validated).
struct ExpiredRecordCleanupService: Sendable {
    let app: Application

    /// Safety buffer beyond expiry before records are eligible for deletion.
    static let gracePeriodMinutes: Int = 14

    /// How often the cleanup runs (in minutes).
    static let intervalMinutes: Int = 60

    // MARK: - Scheduling

    /// Starts the recurring cleanup task via Vapor's lifecycle. Call once from `configure.swift`.
    func scheduleRecurringCleanup() {
        app.lifecycle.use(CleanupLifecycle(service: self))
    }

    // MARK: - Cleanup logic

    func cleanupAll() async {
        let cutoff = Date().addingTimeInterval(-Double(Self.gracePeriodMinutes * 60))
        let db = app.db
        let logger = app.logger

        logger.info("Cleanup started — cutoff: records expired before \(Self.gracePeriodMinutes) min ago")

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await purge("EmailVerificationOTP", logger: logger) {
                try await EmailVerificationOTP.query(on: db)
                    .group(.or) { $0.filter(\.$expiresAt < cutoff); $0.filter(\.$isUsed == true) }
                    .delete()
            }}
            group.addTask { await purge("PasswordResetOTP", logger: logger) {
                try await PasswordResetOTP.query(on: db)
                    .group(.or) { $0.filter(\.$expiresAt < cutoff); $0.filter(\.$isUsed == true) }
                    .delete()
            }}
            group.addTask { await purge("EmailMFAChallenge", logger: logger) {
                try await EmailMFAChallenge.query(on: db)
                    .group(.or) { $0.filter(\.$expiresAt < cutoff); $0.filter(\.$isUsed == true) }
                    .delete()
            }}
            group.addTask { await purge("AuthenticatorAppSetupChallenge", logger: logger) {
                try await AuthenticatorAppSetupChallenge.query(on: db)
                    .group(.or) { $0.filter(\.$expiresAt < cutoff); $0.filter(\.$isUsed == true) }
                    .delete()
            }}
            group.addTask { await purge("PhoneVerificationOTP", logger: logger) {
                try await PhoneVerificationOTP.query(on: db)
                    .group(.or) { $0.filter(\.$expiresAt < cutoff); $0.filter(\.$isUsed == true) }
                    .delete()
            }}
            group.addTask { await purge("PasskeyChallenge", logger: logger) {
                try await PasskeyChallenge.query(on: db)
                    .group(.or) { $0.filter(\.$expiresAt < cutoff); $0.filter(\.$usedAt != nil) }
                    .delete()
            }}
            group.addTask { await purge("RefreshToken", logger: logger) {
                try await RefreshToken.query(on: db)
                    .group(.or) { $0.filter(\.$expiresAt < cutoff); $0.filter(\.$isRevoked == true) }
                    .delete()
            }}
            group.addTask { await purge("SyncOperation", logger: logger) {
                // No grace period — once a sync op expires, it's safe to drop. Client idempotency window already elapsed.
                try await SyncOperation.query(on: db)
                    .filter(\.$expiresAt < Date())
                    .delete()
            }}
        }

        logger.info("Cleanup completed")
    }

    private func purge(_ name: String, logger: Logger, _ operation: @Sendable () async throws -> Void) async {
        do {
            try await operation()
            logger.debug("Purged \(name)")
        } catch {
            logger.warning("Failed to purge \(name): \(error)")
        }
    }
}

// MARK: - Vapor lifecycle integration

private struct CleanupLifecycle: LifecycleHandler, Sendable {
    let service: ExpiredRecordCleanupService

    func didBoot(_ application: Application) throws {
        let interval = ExpiredRecordCleanupService.intervalMinutes
        let grace = ExpiredRecordCleanupService.gracePeriodMinutes
        application.logger.info("Cleanup cron started — interval: \(interval)min, grace: \(grace)min")

        let task = Task {
            // Run once immediately on boot
            await service.cleanupAll()

            // Repeat on schedule
            let sleepNs = UInt64(interval) * 60 * 1_000_000_000
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: sleepNs)
                guard !Task.isCancelled else { break }
                await service.cleanupAll()
            }
        }
        application.storage[CleanupTaskKey.self] = task
    }

    func shutdown(_ application: Application) {
        application.storage[CleanupTaskKey.self]?.cancel()
        application.storage[CleanupTaskKey.self] = nil
    }
}
