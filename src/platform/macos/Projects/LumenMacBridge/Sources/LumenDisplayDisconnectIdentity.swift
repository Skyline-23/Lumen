import CoreGraphics

public struct LumenDisplayDisconnectCapabilityDisplay: Codable, Equatable, Hashable, Sendable {
    public let displayID: CGDirectDisplayID
    public let vendorID: UInt32
    public let productID: UInt32
    public let serialNumber: UInt32
    public let builtin: Bool

    public init(
        displayID: CGDirectDisplayID,
        vendorID: UInt32,
        productID: UInt32,
        serialNumber: UInt32,
        builtin: Bool
    ) {
        self.displayID = displayID
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
        self.builtin = builtin
    }

    var hasStableIdentity: Bool {
        vendorID != 0 && productID != 0 && serialNumber != 0
    }

    var stableIdentity: StableIdentity {
        StableIdentity(
            vendorID: vendorID,
            productID: productID,
            serialNumber: serialNumber,
            builtin: builtin
        )
    }

    struct StableIdentity: Comparable, Equatable, Hashable, Sendable {
        let vendorID: UInt32
        let productID: UInt32
        let serialNumber: UInt32
        let builtin: Bool

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.vendorID != rhs.vendorID {
                return lhs.vendorID < rhs.vendorID
            }
            if lhs.productID != rhs.productID {
                return lhs.productID < rhs.productID
            }
            if lhs.serialNumber != rhs.serialNumber {
                return lhs.serialNumber < rhs.serialNumber
            }
            return !lhs.builtin && rhs.builtin
        }
    }
}

func lumenCurrentPhysicalDisplays(
    snapshot: LumenMacPhysicalDisplayTopology,
    current: LumenMacPhysicalDisplayTopology,
    sessionDisplayID: CGDirectDisplayID
) throws -> [LumenDisplayDisconnectCapabilityDisplay] {
    let expected = try snapshot.displays
        .filter { $0.enabled && $0.active && $0.online }
        .map(capabilityDisplay)
    let live = try current.displays
        .filter { state in
            state.id != String(sessionDisplayID) &&
                state.online
        }
        .map(capabilityDisplay)
    let expectedIdentities = expected.map(\.stableIdentity).sorted()
    let liveIdentities = live.map(\.stableIdentity).sorted()
    guard !live.isEmpty,
          expected.allSatisfy(\.hasStableIdentity),
          live.allSatisfy(\.hasStableIdentity),
          Set(expectedIdentities).count == expectedIdentities.count,
          Set(liveIdentities).count == liveIdentities.count,
          expectedIdentities == liveIdentities else {
        throw LumenPhysicalDisplayControlFailure(
            code: .physicalDisplayDisconnectUnverified
        )
    }
    return live.sorted { $0.displayID < $1.displayID }
}

private func capabilityDisplay(
    _ state: LumenMacPhysicalDisplayState
) throws -> LumenDisplayDisconnectCapabilityDisplay {
    guard let displayID = UInt32(state.id),
          let vendorID = state.vendorID,
          let productID = state.productID,
          let serialNumber = state.serialNumber,
          let builtin = state.builtin else {
        throw LumenPhysicalDisplayControlFailure(
            code: .physicalDisplayDisconnectUnverified
        )
    }
    return LumenDisplayDisconnectCapabilityDisplay(
        displayID: displayID,
        vendorID: vendorID,
        productID: productID,
        serialNumber: serialNumber,
        builtin: builtin
    )
}
