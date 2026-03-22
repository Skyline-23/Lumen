import ApolloMacCaptureAdapter
import AppKit
import CoreGraphics
import Foundation

enum ApolloCaptureCodecChoice: String, CaseIterable, Identifiable {
    case hevc
    case h264
    case proResProxy = "prores-proxy"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hevc:
            return "HEVC Main10"
        case .h264:
            return "H.264"
        case .proResProxy:
            return "ProRes Proxy"
        }
    }

    var bridgeValue: ApolloCoreCaptureCodec {
        switch self {
        case .hevc:
            return ApolloCoreCaptureCodecHEVC
        case .h264:
            return ApolloCoreCaptureCodecH264
        case .proResProxy:
            return ApolloCoreCaptureCodecProResProxy
        }
    }
}

enum ApolloCapturePreprocessChoice: String, CaseIterable, Identifiable {
    case none
    case downscale2x = "downscale-2x"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none:
            return "None"
        case .downscale2x:
            return "Downscale 2x"
        }
    }

    var bridgeValue: ApolloMacBridgePreprocessStrategy {
        switch self {
        case .none:
            return ApolloMacBridgePreprocessStrategyNone
        case .downscale2x:
            return ApolloMacBridgePreprocessStrategyDownscale2x
        }
    }
}

enum ApolloCaptureQueueProfileChoice: String, CaseIterable, Identifiable {
    case q1
    case q2
    case q3
    case q4

    var id: String { rawValue }

    var label: String { rawValue.uppercased() }

    var bridgeValue: ApolloMacBridgeQueueProfile {
        switch self {
        case .q1:
            return ApolloMacBridgeQueueProfileQ1
        case .q2:
            return ApolloMacBridgeQueueProfileQ2
        case .q3:
            return ApolloMacBridgeQueueProfileQ3
        case .q4:
            return ApolloMacBridgeQueueProfileQ4
        }
    }
}

@MainActor
final class ApolloCaptureController: ObservableObject {
    @Published private(set) var status: ApolloMacCaptureAdapterStatus?
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var isStarting = false
    @Published var selectedCodec: ApolloCaptureCodecChoice = .hevc
    @Published var selectedPreprocess: ApolloCapturePreprocessChoice = .none
    @Published var selectedQueueProfile: ApolloCaptureQueueProfileChoice = .q2
    @Published var showCursor = false

    private let adapter: ApolloMacCaptureAdapter
    private var statusObserver: NSObjectProtocol?

    init(adapter: ApolloMacCaptureAdapter = ApolloMacCaptureAdapter()) {
        self.adapter = adapter
        statusObserver = NotificationCenter.default.addObserver(
            forName: .ApolloMacCaptureAdapterStatusDidChange,
            object: adapter,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshStatus()
            }
        }
        adapter.startAutomaticApolloCoreCaptureOrchestration()
        self.status = adapter.copyStatusSnapshot()
    }

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
        adapter.stopAutomaticApolloCoreCaptureOrchestration()
    }

    var menuBarImageName: String {
        status?.captureSessionRunning == true ? "dot.radiowaves.left.and.right" : "bolt.horizontal.circle"
    }

    func startOrRestartCapture() async {
        isStarting = true
        lastErrorMessage = nil

        var configuration = adapter.makePanelNativeConfiguration(forDisplayID: CGMainDisplayID())
        configuration.codec = selectedCodec.bridgeValue
        configuration.preprocess_strategy = selectedPreprocess.bridgeValue
        configuration.queue_profile = selectedQueueProfile.bridgeValue
        configuration.show_cursor = showCursor

        do {
            try adapter.startManagedCaptureSession(
                with: configuration,
                frameCapacity: 128,
                eventCapacity: 32
            )
            refreshStatus()
        } catch {
            refreshStatus()
            lastErrorMessage = error.localizedDescription
        }

        isStarting = false
    }

    func stopCapture() {
        adapter.stopManagedCaptureSession()
        refreshStatus()
    }

    func refreshStatus() {
        status = adapter.copyStatusSnapshot()
    }

    func openWebDashboard() {
        guard let url = URL(string: "https://localhost:47990") else {
            return
        }

        NSWorkspace.shared.open(url)
    }
}
