import CoreMedia
import Foundation
import ScreenCaptureKit

/// Metadata-only idle callbacks are useful even when SCK has no image to send.
/// Missing damage information must never suppress a possibly changed surface.
struct LumenScreenCaptureContentMetadata {
    let status: SCFrameStatus?
    let signal: LumenUnchangedContentCadenceController.Signal

    init(sampleBuffer: CMSampleBuffer) {
        let attachments = (CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]])?.first
        status = (attachments?[.status] as? NSNumber)
            .flatMap { SCFrameStatus(rawValue: $0.intValue) }
        let dirtyRectCount = (attachments?[.dirtyRects] as? [NSValue])?.count
        signal = Self.signal(status: status, dirtyRectCount: dirtyRectCount)
    }

    static func signal(
        status: SCFrameStatus?,
        dirtyRectCount: Int?
    ) -> LumenUnchangedContentCadenceController.Signal {
        switch status {
        case .idle:
            return .idle
        case .complete:
            guard let dirtyRectCount, dirtyRectCount >= 0 else { return .unknown }
            return dirtyRectCount == 0 ? .unchanged : .changed
        default:
            return .unknown
        }
    }
}
