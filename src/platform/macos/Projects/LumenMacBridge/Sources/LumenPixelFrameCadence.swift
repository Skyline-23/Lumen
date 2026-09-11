/// Packet pacing after exact pixel comparison. Compositor damage may include
/// occluded animations even when the captured pixels have not changed.
struct LumenPixelFrameCadence {
    private var lastEmissionSeconds: Double?

    func shouldEmit(hasPixelChanges: Bool, forceRefresh: Bool, sourceTimeSeconds: Double) -> Bool {
        guard !hasPixelChanges, !forceRefresh, let lastEmissionSeconds else { return true }
        let elapsed = sourceTimeSeconds - lastEmissionSeconds
        return elapsed < 0 || elapsed >= 1
    }

    mutating func recordEmission(sourceTimeSeconds: Double) {
        lastEmissionSeconds = sourceTimeSeconds
    }
}
