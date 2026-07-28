extension LumenScreenCaptureDisplayResolver.Environment {
    init(
        now: @escaping LumenScreenCaptureDisplayResolver.MonotonicNow,
        sleepUntil: @escaping LumenScreenCaptureDisplayResolver.MonotonicSleep,
        readiness: @escaping @Sendable () async ->
            LumenCaptureDisplayReadinessSnapshot,
        stampedLookup: @escaping @Sendable (_ generation: UInt64) async throws ->
            LumenScreenCaptureQueryCompletion<Value>
    ) {
        self.now = now
        self.sleepUntil = sleepUntil
        self.readiness = readiness
        lookup = stampedLookup
    }

    init(
        now: @escaping LumenScreenCaptureDisplayResolver.MonotonicNow,
        sleepUntil: @escaping LumenScreenCaptureDisplayResolver.MonotonicSleep,
        readiness: @escaping @Sendable () async ->
            LumenCaptureDisplayReadinessSnapshot,
        lookup: @escaping @Sendable (_ generation: UInt64) async throws -> Value?
    ) {
        self.now = now
        self.sleepUntil = sleepUntil
        self.readiness = readiness
        self.lookup = { generation in
            let value = try await lookup(generation)
            return LumenScreenCaptureQueryCompletion(
                value: value,
                completedAtNanoseconds: await now()
            )
        }
    }
}

extension LumenScreenCaptureDisplayResolver {
    static func validateOwnership(
        _ snapshot: LumenCaptureDisplayReadinessSnapshot,
        displayID: UInt32,
        authority: LumenScreenCaptureDisplayAuthority
    ) throws {
        switch authority {
        case .retained(let ownerToken):
            guard snapshot.ownerToken == ownerToken else {
                throw LumenScreenCaptureError.displayOwnershipLost(displayID)
            }
        case .exactExternal:
            guard snapshot.ownerToken == nil else {
                throw LumenScreenCaptureError.displayUnavailable(displayID)
            }
        }
    }
}
