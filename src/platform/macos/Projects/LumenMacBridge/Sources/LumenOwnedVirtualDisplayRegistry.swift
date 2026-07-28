struct LumenMacVirtualDisplayRegistryAccess: Sendable {
    let currentOwner: @Sendable (String) -> LumenRetainedVirtualDisplayReference?
    let displayID: @Sendable (LumenRetainedVirtualDisplayReference) -> UInt32
    let releaseDisplayTopology: @Sendable (UInt32) async throws -> Void
    let discardCaptureState: @Sendable (UInt32) async -> Void
    let removeMatchingOwner: @Sendable (
        String,
        LumenRetainedVirtualDisplayReference
    ) -> Bool

    static let production = Self(
        currentOwner: { key in
            LumenMacVirtualDisplay.registeredDisplay(forKey: key).map {
                LumenRetainedVirtualDisplayReference(display: $0)
            }
        },
        displayID: { $0.display.displayID },
        releaseDisplayTopology: { displayID in
            try LumenCoreGraphicsDisplayMirrorController()
                .unmirror(targetDisplayID: displayID)
        },
        discardCaptureState: { displayID in
            await LumenScreenCaptureDisplayPrefetch.discard(displayID: displayID)
        },
        removeMatchingOwner: { key, owner in
            LumenMacVirtualDisplay.removeRegisteredDisplay(
                forKey: key,
                ifMatchingDisplay: owner.display
            )
        }
    )
}

actor LumenMacOwnedVirtualDisplayRegistry {
    private struct Record {
        let owner: LumenRetainedVirtualDisplayReference
        let displayID: UInt32
    }

    static let shared = LumenMacOwnedVirtualDisplayRegistry(access: .production)

    private let access: LumenMacVirtualDisplayRegistryAccess
    private var owners: [String: Record] = [:]
    private var releasingKeys: Set<String> = []

    init(access: LumenMacVirtualDisplayRegistryAccess) {
        self.access = access
    }

    func register(
        _ owner: LumenRetainedVirtualDisplayReference,
        forKey key: String
    ) throws {
        let displayID = access.displayID(owner)
        guard access.currentOwner(key)?.display === owner.display,
              displayID != 0,
              !releasingKeys.contains(key),
              owners[key].map({ $0.owner.display === owner.display }) ?? true else {
            throw LumenMacWorkspaceSessionError.virtualDisplayOwnershipMismatch
        }
        owners[key] = Record(owner: owner, displayID: displayID)
    }

    func destroy(
        _ owner: LumenRetainedVirtualDisplayReference,
        forKey key: String
    ) async throws {
        guard let record = owners[key],
              record.owner.display === owner.display,
              access.currentOwner(key)?.display === owner.display,
              !releasingKeys.contains(key) else {
            throw LumenMacWorkspaceSessionError.virtualDisplayOwnershipMismatch
        }
        releasingKeys.insert(key)
        defer { releasingKeys.remove(key) }
        try await access.releaseDisplayTopology(record.displayID)
        guard owners[key]?.owner.display === owner.display,
              access.currentOwner(key)?.display === owner.display else {
            throw LumenMacWorkspaceSessionError.virtualDisplayOwnershipMismatch
        }
        await access.discardCaptureState(record.displayID)
        guard owners[key]?.owner.display === owner.display,
              access.currentOwner(key)?.display === owner.display,
              access.removeMatchingOwner(key, owner) else {
            throw LumenMacWorkspaceSessionError.virtualDisplayOwnershipMismatch
        }
        owners.removeValue(forKey: key)
    }

    func recoverDisplay(forKey key: String) async throws {
        guard let record = owners[key] else {
            guard access.currentOwner(key) == nil else {
                throw LumenMacWorkspaceSessionError.virtualDisplayOwnershipMismatch
            }
            return
        }
        guard !releasingKeys.contains(key) else {
            throw LumenMacWorkspaceSessionError.virtualDisplayOwnershipMismatch
        }
        guard let currentOwner = access.currentOwner(key) else {
            try await releaseOrphanedDisplay(record, forKey: key)
            return
        }
        guard currentOwner.display === record.owner.display else {
            throw LumenMacWorkspaceSessionError.virtualDisplayOwnershipMismatch
        }
        try await releaseRegisteredDisplay(record, forKey: key)
    }

    private func releaseOrphanedDisplay(_ record: Record, forKey key: String) async throws {
        releasingKeys.insert(key)
        defer { releasingKeys.remove(key) }
        if access.displayID(record.owner) == record.displayID,
           record.displayID != 0 {
            try await access.releaseDisplayTopology(record.displayID)
            guard access.displayID(record.owner) == record.displayID else {
                throw LumenMacWorkspaceSessionError.virtualDisplayOwnershipMismatch
            }
        }
        await access.discardCaptureState(record.displayID)
        owners.removeValue(forKey: key)
    }

    private func releaseRegisteredDisplay(_ record: Record, forKey key: String) async throws {
        releasingKeys.insert(key)
        defer { releasingKeys.remove(key) }
        try await access.releaseDisplayTopology(record.displayID)
        guard owners[key]?.owner.display === record.owner.display,
              access.currentOwner(key)?.display === record.owner.display else {
            throw LumenMacWorkspaceSessionError.virtualDisplayOwnershipMismatch
        }
        await access.discardCaptureState(record.displayID)
        guard owners[key]?.owner.display === record.owner.display,
              access.currentOwner(key)?.display === record.owner.display,
              access.removeMatchingOwner(key, record.owner) else {
            throw LumenMacWorkspaceSessionError.virtualDisplayOwnershipMismatch
        }
        owners.removeValue(forKey: key)
    }
}
