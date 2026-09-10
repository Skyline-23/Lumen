import Foundation

/// One prepared FC3 frame waits for local first-packet admission, not a remote
/// acknowledgement. AsyncStream provides cancellation without a polling task.
final class LumenPreparedVideoReceipt: Sendable {
    let sessionEpoch: UInt32
    let frameID: UInt32
    private let results: AsyncStream<Bool>
    private let continuation: AsyncStream<Bool>.Continuation

    init(sessionEpoch: UInt32, frameID: UInt32) {
        self.sessionEpoch = sessionEpoch
        self.frameID = frameID
        (results, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func resolve(accepted: Bool) {
        continuation.yield(accepted)
        continuation.finish()
    }

    func wait() async -> Bool {
        var iterator = results.makeAsyncIterator()
        return await iterator.next() ?? false
    }
}
