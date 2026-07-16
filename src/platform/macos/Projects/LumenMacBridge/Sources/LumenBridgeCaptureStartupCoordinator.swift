import Foundation

@objc public enum LumenBridgeCaptureStartupSource: Int, Sendable {
    case video = 1
    case audio = 2
    case unknown = 3
}

public struct LumenBridgeCaptureStartupError: LocalizedError, Sendable {
    public let source: LumenBridgeCaptureStartupSource
    public let message: String

    public var errorDescription: String? {
        "\(sourceName) capture startup failed: \(message)"
    }

    private var sourceName: String {
        switch source {
        case .video:
            "video"
        case .audio:
            "audio"
        case .unknown:
            "unknown"
        }
    }
}

public enum LumenBridgeCaptureStartupCoordinator {
    public typealias Operation = @Sendable () async throws -> Void

    public static func start(
        video: @escaping Operation,
        audio: @escaping Operation
    ) async throws {
        async let videoFailure = failure(source: .video, operation: video)
        async let audioFailure = failure(source: .audio, operation: audio)
        let (resolvedVideoFailure, resolvedAudioFailure) = await (videoFailure, audioFailure)

        if let resolvedVideoFailure {
            throw resolvedVideoFailure
        }
        if let resolvedAudioFailure {
            throw resolvedAudioFailure
        }
    }

    private static func failure(
        source: LumenBridgeCaptureStartupSource,
        operation: @escaping Operation
    ) async -> LumenBridgeCaptureStartupError? {
        do {
            try await operation()
            return nil
        } catch {
            return LumenBridgeCaptureStartupError(
                source: source,
                message: (error as NSError).localizedDescription
            )
        }
    }
}
