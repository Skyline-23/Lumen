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

    public static func startVisualFirst(
        video: @escaping Operation,
        launchAudio: @escaping Operation
    ) async throws {
        try await run(source: .video, operation: video)
        try await run(source: .audio, operation: launchAudio)
    }

    private static func run(
        source: LumenBridgeCaptureStartupSource,
        operation: @escaping Operation
    ) async throws {
        do {
            try await operation()
        } catch {
            throw LumenBridgeCaptureStartupError(
                source: source,
                message: (error as NSError).localizedDescription
            )
        }
    }
}
