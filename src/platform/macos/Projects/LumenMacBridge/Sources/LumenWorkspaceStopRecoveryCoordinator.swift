import Foundation

public struct LumenWorkspaceStopRecoveryResult: Equatable, Sendable {
    public let usedDurableRecovery: Bool
    public let stopFailureMessage: String?
}

public struct LumenWorkspaceStopRecoveryError: LocalizedError, Sendable {
    public let stopFailureMessage: String
    public let recoveryFailureMessage: String

    public var errorDescription: String? {
        "workspace stop failed: \(stopFailureMessage); durable recovery failed: \(recoveryFailureMessage)"
    }
}

struct LumenWorkspaceRecoveryRetryPolicy: Sendable {
    static let production = Self(
        maximumAttempts: 2,
        delay: .milliseconds(250)
    )

    let maximumAttempts: Int
    let delay: Duration

    init(maximumAttempts: Int, delay: Duration) {
        precondition(maximumAttempts > 0)
        self.maximumAttempts = maximumAttempts
        self.delay = delay
    }
}

public enum LumenWorkspaceStopRecoveryCoordinator {
    public typealias Stop = @Sendable () async throws -> Void
    public typealias Recover = @Sendable () async throws -> Bool
    typealias Sleep = @Sendable (Duration) async -> Void

    public static func stop(
        stop: @escaping Stop,
        recover: @escaping Recover
    ) async throws -> LumenWorkspaceStopRecoveryResult {
        try await self.stop(
            stop: stop,
            recover: recover,
            retryPolicy: .production,
            sleep: { delay in
                try? await Task.sleep(for: delay)
            }
        )
    }

    static func stop(
        stop: @escaping Stop,
        recover: @escaping Recover,
        retryPolicy: LumenWorkspaceRecoveryRetryPolicy,
        sleep: @escaping Sleep
    ) async throws -> LumenWorkspaceStopRecoveryResult {
        do {
            try await stop()
            return LumenWorkspaceStopRecoveryResult(
                usedDurableRecovery: false,
                stopFailureMessage: nil
            )
        } catch {
            let stopFailureMessage = (error as NSError).localizedDescription
            var recoveryFailureMessage = "the durable recovery journal was unavailable"

            for attempt in 1 ... retryPolicy.maximumAttempts {
                do {
                    if try await recover() {
                        return LumenWorkspaceStopRecoveryResult(
                            usedDurableRecovery: true,
                            stopFailureMessage: stopFailureMessage
                        )
                    }
                    recoveryFailureMessage = "the durable recovery journal was unavailable"
                } catch {
                    recoveryFailureMessage = (error as NSError).localizedDescription
                }

                if attempt < retryPolicy.maximumAttempts {
                    await sleep(retryPolicy.delay)
                }
            }

            throw LumenWorkspaceStopRecoveryError(
                stopFailureMessage: stopFailureMessage,
                recoveryFailureMessage: recoveryFailureMessage
            )
        }
    }
}
