import ApolloCore
import Foundation

public enum ApolloCaptureBackend: String, CaseIterable, Codable, Sendable {
    case legacyApollo = "legacy-apollo"
    case macDisplayKit = "mac-display-kit"
}

public struct ApolloBridgeStatus: Equatable, Sendable {
    public let coreVersion: String
    public let runtimeDescription: String
    public let preferredCaptureBackend: ApolloCaptureBackend
    public let integrationStatus: String

    public init(
        coreVersion: String,
        runtimeDescription: String,
        preferredCaptureBackend: ApolloCaptureBackend,
        integrationStatus: String
    ) {
        self.coreVersion = coreVersion
        self.runtimeDescription = runtimeDescription
        self.preferredCaptureBackend = preferredCaptureBackend
        self.integrationStatus = integrationStatus
    }
}

public actor ApolloBridgeRuntime {
    public static let shared = ApolloBridgeRuntime()

    private var preferredCaptureBackend: ApolloCaptureBackend = .macDisplayKit

    public init() {}

    public func setPreferredCaptureBackend(_ backend: ApolloCaptureBackend) {
        preferredCaptureBackend = backend
    }

    public func statusSnapshot() -> ApolloBridgeStatus {
        ApolloBridgeStatus(
            coreVersion: String(cString: ApolloCoreBootstrapVersionString()),
            runtimeDescription: String(cString: ApolloCoreBootstrapRuntimeDescription()),
            preferredCaptureBackend: preferredCaptureBackend,
            integrationStatus: "Swift shell, C/C++ core, and bridge targets are ready. Wire MacDisplayKit into ApolloMacBridge next."
        )
    }
}
