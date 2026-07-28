import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import OSLog
import ScreenCaptureKit
import Synchronization
import VideoToolbox

enum LumenScreenCaptureDisplayAdmissionMode: String, Equatable, Sendable {
    case prefetchedShareableContent = "prefetched-shareable-content"
    case retainedShareableContent = "retained-shareable-content"
    case shareableContentEnumeration = "shareable-content-enumeration"
}

struct LumenScreenCaptureDisplayAdmissionResult<Value: Sendable>: Sendable {
    let value: Value
    let mode: LumenScreenCaptureDisplayAdmissionMode
}

enum LumenScreenCaptureDisplayAdmission {
    static func resolve<Value: Sendable>(
        displayID: UInt32,
        prefetched: @escaping @Sendable () async throws -> Value?,
        enumerateShareableContent: @escaping @Sendable () async throws ->
            LumenScreenCaptureDisplayAdmissionResult<Value>
    ) async throws -> LumenScreenCaptureDisplayAdmissionResult<Value> {
        if let value = try await prefetched() {
            return .init(value: value, mode: .prefetchedShareableContent)
        }
        return try await enumerateShareableContent()
    }
}

struct LumenScreenCaptureDisplayHandle: @unchecked Sendable {
    let value: SCDisplay
}

struct LumenRetainedVirtualDisplayReference: @unchecked Sendable {
    let display: LumenMacVirtualDisplay

    var ownerToken: UInt {
        UInt(bitPattern: ObjectIdentifier(display))
    }

    func isCurrent(displayID: UInt32) -> Bool {
        display.displayID == displayID &&
            LumenMacVirtualDisplay.registeredDisplay(forDisplayID: displayID) === display
    }
}

actor LumenExpectedDisplayOwnerStore<Owner: Sendable> {
    private var owners: [UInt32: Owner] = [:]

    func set(_ owner: Owner, displayID: UInt32) {
        owners[displayID] = owner
    }

    func owner(displayID: UInt32) -> Owner? {
        owners[displayID]
    }

    func discard(displayID: UInt32) {
        owners.removeValue(forKey: displayID)
    }
}

struct LumenScreenCapturePreparedDisplay: @unchecked Sendable {
    let handle: LumenScreenCaptureDisplayHandle
    let owner: LumenRetainedVirtualDisplayReference
}

actor LumenPreparedDisplayStore<Value: Sendable> {
    private struct Entry {
        let ownerToken: UInt
        let generation: UInt64
        var value: Value?
        var expiresAt: UInt64?
    }

    private var entries: [UInt32: Entry] = [:]
    private var generations: [UInt32: UInt64] = [:]

    func begin(
        displayID: UInt32,
        ownerToken: UInt
    ) -> UInt64 {
        let generation = (generations[displayID] ?? 0) &+ 1
        generations[displayID] = generation
        entries[displayID] = Entry(
            ownerToken: ownerToken,
            generation: generation,
            value: nil,
            expiresAt: nil
        )
        return generation
    }

    func complete(
        displayID: UInt32,
        ownerToken: UInt,
        generation: UInt64,
        value: Value,
        expiresAt: UInt64
    ) throws {
        try Task.checkCancellation()
        guard var entry = entries[displayID],
              entry.ownerToken == ownerToken,
              entry.generation == generation else {
            return
        }
        entry.value = value
        entry.expiresAt = expiresAt
        entries[displayID] = entry
    }

    func take(
        displayID: UInt32,
        ownerToken: UInt,
        now: UInt64
    ) -> Value? {
        guard let entry = entries[displayID] else {
            return nil
        }
        guard entry.ownerToken == ownerToken else {
            entries.removeValue(forKey: displayID)
            return nil
        }
        entries.removeValue(forKey: displayID)
        guard let expiresAt = entry.expiresAt,
              now <= expiresAt else {
            return nil
        }
        return entry.value
    }

    func discard(displayID: UInt32, generation: UInt64? = nil) {
        guard generation == nil || entries[displayID]?.generation == generation else {
            return
        }
        entries.removeValue(forKey: displayID)
    }
}
