import CoreMedia
import Foundation

final class LumenSampleBufferHandle: Sendable {
    private let address: UInt

    init(retaining sampleBuffer: CMSampleBuffer) {
        address = UInt(bitPattern: Unmanaged.passRetained(sampleBuffer).toOpaque())
    }

    deinit {
        guard let pointer = UnsafeRawPointer(bitPattern: address) else {
            return
        }
        Unmanaged<CMSampleBuffer>.fromOpaque(pointer).release()
    }

    var value: CMSampleBuffer {
        guard let pointer = UnsafeRawPointer(bitPattern: address) else {
            preconditionFailure("Lumen sample buffer handle lost its pointer value")
        }
        return Unmanaged<CMSampleBuffer>.fromOpaque(pointer).takeUnretainedValue()
    }
}
