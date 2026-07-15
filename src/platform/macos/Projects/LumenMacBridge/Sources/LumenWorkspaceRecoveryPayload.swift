import Foundation

public struct LumenMacPhysicalDisplayMode: Codable, Equatable, Sendable {
    public let width: UInt32
    public let height: UInt32
    public let refreshMillihertz: UInt32
    public let bitDepth: UInt8

    public init(width: UInt32, height: UInt32, refreshMillihertz: UInt32, bitDepth: UInt8) {
        self.width = width
        self.height = height
        self.refreshMillihertz = refreshMillihertz
        self.bitDepth = bitDepth
    }

    enum CodingKeys: String, CodingKey {
        case width
        case height
        case refreshMillihertz = "refresh_millihz"
        case bitDepth = "bit_depth"
    }
}

public struct LumenMacPhysicalDisplayState: Codable, Equatable, Sendable {
    public let id: String
    public let mode: LumenMacPhysicalDisplayMode
    public let originX: Int32
    public let originY: Int32
    public let mirrorMasterID: String?
    public let enabled: Bool
    public let active: Bool
    public let online: Bool

    public init(
        id: String,
        mode: LumenMacPhysicalDisplayMode,
        originX: Int32,
        originY: Int32,
        mirrorMasterID: String?,
        enabled: Bool,
        active: Bool,
        online: Bool
    ) {
        self.id = id
        self.mode = mode
        self.originX = originX
        self.originY = originY
        self.mirrorMasterID = mirrorMasterID
        self.enabled = enabled
        self.active = active
        self.online = online
    }

    enum CodingKeys: String, CodingKey {
        case id
        case mode
        case originX = "origin_x"
        case originY = "origin_y"
        case mirrorMasterID = "mirror_master_id"
        case enabled
        case active
        case online
    }
}

public struct LumenMacWindowsAdapterLUID: Codable, Equatable, Sendable {
    public let highPart: Int32
    public let lowPart: UInt32

    public init(highPart: Int32, lowPart: UInt32) {
        self.highPart = highPart
        self.lowPart = lowPart
    }

    enum CodingKeys: String, CodingKey {
        case highPart = "high_part"
        case lowPart = "low_part"
    }
}

public struct LumenMacPhysicalDisplayTopology: Codable, Equatable, Sendable {
    public let displays: [LumenMacPhysicalDisplayState]
    public let windowsAdapterLUID: LumenMacWindowsAdapterLUID?
    public let windowsTargetPaths: [String]

    public init(
        displays: [LumenMacPhysicalDisplayState],
        windowsAdapterLUID: LumenMacWindowsAdapterLUID?,
        windowsTargetPaths: [String]
    ) {
        self.displays = displays
        self.windowsAdapterLUID = windowsAdapterLUID
        self.windowsTargetPaths = windowsTargetPaths
    }

    enum CodingKeys: String, CodingKey {
        case displays
        case windowsAdapterLUID = "windows_adapter_luid"
        case windowsTargetPaths = "windows_target_paths"
    }
}

public struct LumenMacVirtualDisplayIdentity: Codable, Equatable, Sendable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}

public enum LumenMacWorkspaceCommandPayload: Equatable, Sendable {
    case none
    case physicalTopology(LumenMacPhysicalDisplayTopology)
    case virtualDisplayIdentity(LumenMacVirtualDisplayIdentity)
}

public enum LumenMacWorkspaceCommandResult: Equatable, Sendable {
    case succeeded
    case failed
    case physicalTopology(LumenMacPhysicalDisplayTopology)
    case virtualDisplayIdentity(LumenMacVirtualDisplayIdentity)
}
