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

public enum LumenWorkspaceStopRecoveryCoordinator {
    public typealias Stop = @Sendable () async throws -> Void
    public typealias Recover = @Sendable () async throws -> Bool

    public static func stop(
        stop: @escaping Stop,
        recover: @escaping Recover
    ) async throws -> LumenWorkspaceStopRecoveryResult {
        do {
            try await stop()
            return LumenWorkspaceStopRecoveryResult(
                usedDurableRecovery: false,
                stopFailureMessage: nil
            )
        } catch {
            let stopFailureMessage = (error as NSError).localizedDescription
            let recovered: Bool
            do {
                recovered = try await recover()
            } catch {
                throw LumenWorkspaceStopRecoveryError(
                    stopFailureMessage: stopFailureMessage,
                    recoveryFailureMessage: (error as NSError).localizedDescription
                )
            }
            guard recovered else {
                throw LumenWorkspaceStopRecoveryError(
                    stopFailureMessage: stopFailureMessage,
                    recoveryFailureMessage: "the durable recovery journal was unavailable"
                )
            }
            return LumenWorkspaceStopRecoveryResult(
                usedDurableRecovery: true,
                stopFailureMessage: stopFailureMessage
            )
        }
    }
}
