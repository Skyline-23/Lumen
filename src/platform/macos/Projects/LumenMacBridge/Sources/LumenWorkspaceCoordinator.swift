import Foundation
import LumenEngineBridge

@frozen public enum LumenMacWorkspacePolicy: CaseIterable, Equatable, Hashable, Sendable {
    case coexist
    case promoteVirtualMain
    case focusedWorkspace
    case isolatedWorkspace

    fileprivate var engineValue: LumenWorkspacePolicy {
        switch self {
        case .coexist:
            LumenWorkspacePolicyCoexist
        case .promoteVirtualMain:
            LumenWorkspacePolicyPromoteVirtualMain
        case .focusedWorkspace:
            LumenWorkspacePolicyFocusedWorkspace
        case .isolatedWorkspace:
            LumenWorkspacePolicyIsolatedWorkspace
        }
    }
}

public enum LumenMacWorkspaceState: Equatable, Sendable {
    case idle
    case starting
    case active
    case stopping
}

public enum LumenMacWorkspaceAction: Equatable, Sendable {
    case snapshotWorkspace
    case createVirtualDisplay
    case configureVirtualDisplay
    case promoteVirtualMain
    case moveTargetWindows
    case applyIsolation
    case startCapture
    case stopCapture
    case restoreWorkspace
    case verifyPhysicalDisplays
    case destroyVirtualDisplay
    case awaitExternalFirstEncodedFrame

    fileprivate init(engineValue: LumenWorkspaceCommandKind) throws {
        switch engineValue {
        case LumenWorkspaceCommandSnapshotWorkspace:
            self = .snapshotWorkspace
        case LumenWorkspaceCommandCreateVirtualDisplay:
            self = .createVirtualDisplay
        case LumenWorkspaceCommandConfigureVirtualDisplay:
            self = .configureVirtualDisplay
        case LumenWorkspaceCommandPromoteVirtualMain:
            self = .promoteVirtualMain
        case LumenWorkspaceCommandMoveTargetWindows:
            self = .moveTargetWindows
        case LumenWorkspaceCommandApplyIsolation:
            self = .applyIsolation
        case LumenWorkspaceCommandStartCapture:
            self = .startCapture
        case LumenWorkspaceCommandStopCapture:
            self = .stopCapture
        case LumenWorkspaceCommandRestoreWorkspace:
            self = .restoreWorkspace
        case LumenWorkspaceCommandVerifyPhysicalDisplays:
            self = .verifyPhysicalDisplays
        case LumenWorkspaceCommandDestroyVirtualDisplay:
            self = .destroyVirtualDisplay
        case LumenWorkspaceCommandAwaitExternalFirstEncodedFrame:
            self = .awaitExternalFirstEncodedFrame
        default:
            throw LumenWorkspaceCoordinatorError.unknownCommand(engineValue.rawValue)
        }
    }

    fileprivate var engineValue: LumenWorkspaceCommandKind {
        switch self {
        case .snapshotWorkspace:
            LumenWorkspaceCommandSnapshotWorkspace
        case .createVirtualDisplay:
            LumenWorkspaceCommandCreateVirtualDisplay
        case .configureVirtualDisplay:
            LumenWorkspaceCommandConfigureVirtualDisplay
        case .promoteVirtualMain:
            LumenWorkspaceCommandPromoteVirtualMain
        case .moveTargetWindows:
            LumenWorkspaceCommandMoveTargetWindows
        case .applyIsolation:
            LumenWorkspaceCommandApplyIsolation
        case .startCapture:
            LumenWorkspaceCommandStartCapture
        case .stopCapture:
            LumenWorkspaceCommandStopCapture
        case .restoreWorkspace:
            LumenWorkspaceCommandRestoreWorkspace
        case .verifyPhysicalDisplays:
            LumenWorkspaceCommandVerifyPhysicalDisplays
        case .destroyVirtualDisplay:
            LumenWorkspaceCommandDestroyVirtualDisplay
        case .awaitExternalFirstEncodedFrame:
            LumenWorkspaceCommandAwaitExternalFirstEncodedFrame
        }
    }
}

public struct LumenMacWorkspaceCommand: Equatable, Sendable {
    public let action: LumenMacWorkspaceAction
    public let generation: UInt64
    public let sequence: UInt32
    public let payload: LumenMacWorkspaceCommandPayload

    fileprivate init(
        engineValue: LumenWorkspaceCommand,
        payload: LumenMacWorkspaceCommandPayload
    ) throws {
        action = try LumenMacWorkspaceAction(engineValue: engineValue.kind)
        generation = engineValue.generation
        sequence = engineValue.sequence
        self.payload = payload
    }

    fileprivate var engineValue: LumenWorkspaceCommand {
        LumenWorkspaceCommand(
            kind: action.engineValue,
            generation: generation,
            sequence: sequence,
            payload_kind: payload.engineKind
        )
    }
}

public enum LumenWorkspaceCoordinatorError: Error, Equatable {
    case incompatibleABI(expected: UInt32, actual: UInt32)
    case allocationFailed
    case engineStatus(UInt32)
    case unknownCommand(UInt32)
    case unknownState(UInt32)
}

public struct LumenMacDisplayModeRequest: Equatable, Sendable {
    public let width: UInt32
    public let height: UInt32
    public let scalePercent: UInt32
    public let dimensionsAreLogical: Bool

    public init(
        width: UInt32,
        height: UInt32,
        scalePercent: UInt32,
        dimensionsAreLogical: Bool
    ) {
        self.width = width
        self.height = height
        self.scalePercent = scalePercent
        self.dimensionsAreLogical = dimensionsAreLogical
    }
}

public struct LumenMacDisplayGeometry: Equatable, Sendable {
    public let streamWidth: UInt32
    public let streamHeight: UInt32
    public let logicalWidth: UInt32
    public let logicalHeight: UInt32
    public let backingWidth: UInt32
    public let backingHeight: UInt32

    fileprivate init(engineValue: LumenDisplayGeometry) {
        streamWidth = engineValue.stream_width
        streamHeight = engineValue.stream_height
        logicalWidth = engineValue.logical_width
        logicalHeight = engineValue.logical_height
        backingWidth = engineValue.backing_width
        backingHeight = engineValue.backing_height
    }
}

public enum LumenMacDisplayGeometryResolver {
    public static func resolve(
        _ request: LumenMacDisplayModeRequest
    ) throws -> LumenMacDisplayGeometry {
        var geometry = LumenDisplayGeometry(
            stream_width: 0,
            stream_height: 0,
            logical_width: 0,
            logical_height: 0,
            backing_width: 0,
            backing_height: 0
        )
        let status = lumen_engine_resolve_display_geometry(
            LumenDisplayModeRequest(
                width: request.width,
                height: request.height,
                scale_percent: request.scalePercent,
                dimensions_are_logical: request.dimensionsAreLogical
            ),
            &geometry
        )
        guard status == LumenEngineStatusOk else {
            throw LumenWorkspaceCoordinatorError.engineStatus(status.rawValue)
        }
        return LumenMacDisplayGeometry(engineValue: geometry)
    }
}

public struct LumenMacDisplayColorProfile: Equatable, Sendable {
    public let gamutRawValue: UInt32
    public let transferRawValue: UInt32
    public let redX: Double
    public let redY: Double
    public let greenX: Double
    public let greenY: Double
    public let blueX: Double
    public let blueY: Double
    public let whiteX: Double
    public let whiteY: Double
    public let hdrCapable: Bool

    fileprivate init(engineValue: LumenDisplayColorProfile) {
        gamutRawValue = engineValue.gamut.rawValue
        transferRawValue = engineValue.transfer.rawValue
        redX = engineValue.red_x
        redY = engineValue.red_y
        greenX = engineValue.green_x
        greenY = engineValue.green_y
        blueX = engineValue.blue_x
        blueY = engineValue.blue_y
        whiteX = engineValue.white_x
        whiteY = engineValue.white_y
        hdrCapable = engineValue.hdr_capable
    }
}

public enum LumenMacDisplayColorResolver {
    public static func resolve(
        hdrEnabled: Bool,
        clientGamut: Int32,
        clientTransfer: Int32
    ) throws -> LumenMacDisplayColorProfile {
        var profile = LumenDisplayColorProfile(
            gamut: LumenDisplayGamut(rawValue: 0),
            transfer: LumenDisplayTransfer(rawValue: 0),
            red_x: 0,
            red_y: 0,
            green_x: 0,
            green_y: 0,
            blue_x: 0,
            blue_y: 0,
            white_x: 0,
            white_y: 0,
            hdr_capable: false
        )
        let status = lumen_engine_resolve_display_color(
            LumenDisplayColorRequest(
                hdr_enabled: hdrEnabled,
                client_gamut: clientGamut,
                client_transfer: clientTransfer
            ),
            &profile
        )
        guard status == LumenEngineStatusOk else {
            throw LumenWorkspaceCoordinatorError.engineStatus(status.rawValue)
        }
        return LumenMacDisplayColorProfile(engineValue: profile)
    }
}

public actor LumenWorkspaceCoordinator {
    private let engine: LumenEngineHandle

    public nonisolated static var defaultRecoveryJournalPath: String {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Lumen", directoryHint: .isDirectory)
            .appending(path: "display-recovery.json", directoryHint: .notDirectory)
            .path(percentEncoded: false)
    }

    public init(recoveryJournalPath: String? = nil) throws {
        let actualVersion = LumenEngineBridgeABIVersion()
        guard actualVersion == LUMEN_ENGINE_ABI_VERSION else {
            throw LumenWorkspaceCoordinatorError.incompatibleABI(
                expected: LUMEN_ENGINE_ABI_VERSION,
                actual: actualVersion
            )
        }
        let path = recoveryJournalPath ?? Self.defaultRecoveryJournalPath
        let engine = path.withCString { pointer in
            lumen_workspace_engine_create_recoverable(pointer, LumenWorkspacePlatformMacos)
        }
        guard let engine else {
            throw LumenWorkspaceCoordinatorError.allocationFailed
        }
        self.engine = LumenEngineHandle(engine, destructor: lumen_workspace_engine_destroy)
    }

    public func beginSession(
        policy: LumenMacWorkspacePolicy,
        moveTargetWindows: Bool = false,
        manageCapture: Bool = true
    ) throws -> Bool {
        let status = lumen_workspace_engine_begin_session(
            engine.rawValue,
            LumenWorkspaceSessionRequest(
                policy: policy.engineValue,
                move_target_windows: moveTargetWindows,
                manage_capture: manageCapture
            )
        )
        if status == LumenEngineStatusRecoveryRequired {
            return false
        }
        try requireSuccess(status)
        return true
    }

    public func nextCommand() throws -> LumenMacWorkspaceCommand? {
        var command = LumenWorkspaceCommand(
            kind: LumenWorkspaceCommandSnapshotWorkspace,
            generation: 0,
            sequence: 0,
            payload_kind: LumenWorkspaceCommandPayloadNone
        )
        let status = lumen_workspace_engine_next_command(engine.rawValue, &command)
        if status == LumenEngineStatusNoCommand {
            return nil
        }
        try requireSuccess(status)
        let payload = try LumenWorkspacePayloadCodec.decode(engine: engine.rawValue, command: command)
        return try LumenMacWorkspaceCommand(engineValue: command, payload: payload)
    }

    public func complete(
        _ command: LumenMacWorkspaceCommand,
        result: LumenMacWorkspaceCommandResult
    ) throws {
        try requireSuccess(
            LumenWorkspacePayloadCodec.complete(
                engine: engine.rawValue,
                command: command.engineValue,
                result: result
            )
        )
    }

    public func recordDesktopMirrorApplied() throws {
        try requireSuccess(
            lumen_workspace_engine_record_desktop_mirror_applied(engine.rawValue)
        )
    }

    public func endSession() throws {
        try requireSuccess(lumen_workspace_engine_end_session(engine.rawValue))
    }

    public func currentState() throws -> LumenMacWorkspaceState {
        let state = lumen_workspace_engine_state(engine.rawValue)
        switch state {
        case LumenWorkspaceStateIdle:
            return .idle
        case LumenWorkspaceStateStarting:
            return .starting
        case LumenWorkspaceStateActive:
            return .active
        case LumenWorkspaceStateStopping:
            return .stopping
        default:
            throw LumenWorkspaceCoordinatorError.unknownState(state.rawValue)
        }
    }

    public func generation() -> UInt64 {
        lumen_workspace_engine_generation(engine.rawValue)
    }

    public func lastFailureStatus() -> UInt32 {
        lumen_workspace_engine_last_failure(engine.rawValue).rawValue
    }

    private func requireSuccess(_ status: LumenEngineStatus) throws {
        guard status == LumenEngineStatusOk else {
            throw LumenWorkspaceCoordinatorError.engineStatus(status.rawValue)
        }
    }
}
