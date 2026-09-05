import CoreMedia
import CoreVideo
import Metal

/// The private SkyLight path only emits the two bi-planar 4:2:0 formats that
/// VideoToolbox accepts for the current capture contracts.  Keep the Metal
/// mapping in one place so an 8-bit SDR frame can never accidentally use the
/// 10-bit texture formats (or vice versa).
struct LumenSkyLightMetalStagingFormat: Equatable {
    let pixelFormat: OSType
    let lumaPixelFormat: MTLPixelFormat
    let chromaPixelFormat: MTLPixelFormat

    init?(pixelFormat: OSType) {
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            self.pixelFormat = pixelFormat
            lumaPixelFormat = .r8Unorm
            chromaPixelFormat = .rg8Unorm
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            self.pixelFormat = pixelFormat
            lumaPixelFormat = .r16Unorm
            chromaPixelFormat = .rg16Unorm
        default:
            return nil
        }
    }

    /// Validates only the shape needed to construct the two Metal textures.
    /// The full HDR/source contract is deliberately checked again on the
    /// encoder-owned destination after GPU completion.
    func mismatchDescription(
        for pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int
    ) -> String? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == pixelFormat else {
            return "pixel-format expected=\(fourCC(pixelFormat)) actual=\(fourCC(CVPixelBufferGetPixelFormatType(pixelBuffer)))"
        }
        guard CVPixelBufferGetWidth(pixelBuffer) == width,
              CVPixelBufferGetHeight(pixelBuffer) == height else {
            return "dimensions expected=\(width)x\(height) actual=\(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer))"
        }
        guard CVPixelBufferIsPlanar(pixelBuffer),
              CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else {
            return "plane-count expected=2 actual=\(CVPixelBufferGetPlaneCount(pixelBuffer))"
        }

        let expectedChromaWidth = (width + 1) / 2
        let expectedChromaHeight = (height + 1) / 2
        guard CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) == width,
              CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) == height else {
            return "luma-plane expected=\(width)x\(height) actual=\(CVPixelBufferGetWidthOfPlane(pixelBuffer, 0))x\(CVPixelBufferGetHeightOfPlane(pixelBuffer, 0))"
        }
        guard CVPixelBufferGetWidthOfPlane(pixelBuffer, 1) == expectedChromaWidth,
              CVPixelBufferGetHeightOfPlane(pixelBuffer, 1) == expectedChromaHeight else {
            return "chroma-plane expected=\(expectedChromaWidth)x\(expectedChromaHeight) actual=\(CVPixelBufferGetWidthOfPlane(pixelBuffer, 1))x\(CVPixelBufferGetHeightOfPlane(pixelBuffer, 1))"
        }
        return nil
    }

    private func fourCC(_ value: OSType) -> String {
        String(bytes: [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ], encoding: .ascii) ?? String(value)
    }
}

/// Bounds the number of compositor surfaces retained by the asynchronous Metal
/// staging path.  The callback queue may submit two copies before either
/// completion returns; a third source is rejected at the admission boundary
/// instead of growing an unbounded IOSurface or command-buffer backlog.
struct LumenSkyLightMetalStagingAdmission: Equatable {
    private(set) var inFlightCopyCount = 0

    var isCopyInFlight: Bool { inFlightCopyCount > 0 }

    var canDrain: Bool { inFlightCopyCount == 0 }

    mutating func beginCopy() -> Bool {
        guard inFlightCopyCount <
                LumenSkyLightMetalStagingPolicy.maximumGPUCopiesInFlight else {
            return false
        }
        inFlightCopyCount += 1
        return true
    }

    mutating func completeCopy() -> Bool {
        guard inFlightCopyCount > 0 else { return false }
        inFlightCopyCount -= 1
        return true
    }
}

enum LumenSkyLightMetalStagingPolicy {
    static let maximumGPUCopiesInFlight = 2
    // Two destinations can be in GPU blits, one newest source can be retained
    // at the staging boundary, and the two encoder slots can still be owned by
    // VideoToolbox. Keep all five ownership cases representable so a burst
    // cannot turn bounded GPU overlap into a pool-allocation drop.
    static let poolCapacity =
        LumenRealtimeVideoEncoderAdmissionPolicy.maximumInflightFrameCount
        + 1 // one bounded latest pending destination/source handoff
        + maximumGPUCopiesInFlight
}

/// A resource-generation token fences completions from an older staging pool.
/// It is deliberately independent of the media epoch: a media epoch retires
/// encoded callbacks, while this token retires Metal resources and admission
/// counters when a stream is prepared or released again.
struct LumenSkyLightMetalStagingGeneration: Equatable, Sendable {
    private(set) var value: UInt64 = 0

    @discardableResult
    mutating func advance() -> UInt64 {
        value &+= 1
        return value
    }

    func accepts(_ copyGeneration: UInt64) -> Bool {
        copyGeneration == value
    }
}

/// Retains every object needed by a committed blit until Metal reports that
/// the GPU has finished.  The source IOSurface lease and source textures are
/// explicitly released on the runtime owner queue before destination
/// validation/admission begins.
final class LumenSkyLightMetalCopyContext: @unchecked Sendable {
    let destination: CVPixelBuffer
    let presentationTime: CMTime
    let sourceDisplayTime: UInt64
    let streamIdentity: UInt
    let mediaEpoch: UInt64
    let stagingGeneration: UInt64
    let startedMachTime: UInt64
    var sourceSurfaceLease: LumenMacSkyLightDisplayStreamFrameLease?
    var sourceLumaTexture: CVMetalTexture?
    var sourceChromaTexture: CVMetalTexture?
    var destinationLumaTexture: CVMetalTexture?
    var destinationChromaTexture: CVMetalTexture?

    init(
        destination: CVPixelBuffer,
        presentationTime: CMTime,
        sourceDisplayTime: UInt64,
        streamIdentity: UInt,
        mediaEpoch: UInt64,
        stagingGeneration: UInt64,
        startedMachTime: UInt64,
        sourceSurfaceLease: LumenMacSkyLightDisplayStreamFrameLease?,
        sourceLumaTexture: CVMetalTexture,
        sourceChromaTexture: CVMetalTexture,
        destinationLumaTexture: CVMetalTexture,
        destinationChromaTexture: CVMetalTexture
    ) {
        self.destination = destination
        self.presentationTime = presentationTime
        self.sourceDisplayTime = sourceDisplayTime
        self.streamIdentity = streamIdentity
        self.mediaEpoch = mediaEpoch
        self.stagingGeneration = stagingGeneration
        self.startedMachTime = startedMachTime
        self.sourceSurfaceLease = sourceSurfaceLease
        self.sourceLumaTexture = sourceLumaTexture
        self.sourceChromaTexture = sourceChromaTexture
        self.destinationLumaTexture = destinationLumaTexture
        self.destinationChromaTexture = destinationChromaTexture
    }

    func releaseGPUOwnedSourceResources() {
        sourceSurfaceLease = nil
        sourceLumaTexture = nil
        sourceChromaTexture = nil
        destinationLumaTexture = nil
        destinationChromaTexture = nil
    }
}

/// Owns the Metal objects and the encoder-owned destination pool for one
/// private SkyLight stream.  Creation and flushing happen outside the hot
/// callback, while the runtime's serial queue owns when this object is used.
final class LumenSkyLightMetalStagingResources: @unchecked Sendable {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let textureCache: CVMetalTextureCache
    let pixelBufferPool: CVPixelBufferPool
    let format: LumenSkyLightMetalStagingFormat
    let width: Int
    let height: Int

    private init(
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        textureCache: CVMetalTextureCache,
        pixelBufferPool: CVPixelBufferPool,
        format: LumenSkyLightMetalStagingFormat,
        width: Int,
        height: Int
    ) {
        self.device = device
        self.commandQueue = commandQueue
        self.textureCache = textureCache
        self.pixelBufferPool = pixelBufferPool
        self.format = format
        self.width = width
        self.height = height
    }

    static func make(
        width: Int,
        height: Int,
        pixelFormat: OSType
    ) throws -> LumenSkyLightMetalStagingResources {
        guard let format = LumenSkyLightMetalStagingFormat(
            pixelFormat: pixelFormat
        ) else {
            throw LumenSkyLightMetalStagingResourceError(
                "unsupported pixel format \(pixelFormat)"
            )
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw LumenSkyLightMetalStagingResourceError(
                "no system Metal device"
            )
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw LumenSkyLightMetalStagingResourceError(
                "Metal command queue creation failed"
            )
        }

        var textureCache: CVMetalTextureCache?
        let textureCacheStatus = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &textureCache
        )
        guard textureCacheStatus == kCVReturnSuccess,
              let textureCache else {
            throw LumenSkyLightMetalStagingResourceError(
                "Metal texture-cache creation failed status=\(textureCacheStatus)"
            )
        }

        var pixelBufferPool: CVPixelBufferPool?
        let poolStatus = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            [
                kCVPixelBufferPoolMinimumBufferCountKey:
                    LumenSkyLightMetalStagingPolicy.poolCapacity
            ] as CFDictionary,
            [
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: pixelFormat,
                kCVPixelBufferIOSurfacePropertiesKey: [:],
                kCVPixelBufferMetalCompatibilityKey: true
            ] as CFDictionary,
            &pixelBufferPool
        )
        guard poolStatus == kCVReturnSuccess,
              let pixelBufferPool else {
            throw LumenSkyLightMetalStagingResourceError(
                "pixel-buffer-pool creation failed status=\(poolStatus)"
            )
        }

        return LumenSkyLightMetalStagingResources(
            device: device,
            commandQueue: commandQueue,
            textureCache: textureCache,
            pixelBufferPool: pixelBufferPool,
            format: format,
            width: width,
            height: height
        )
    }

    func allocateDestination() -> (CVPixelBuffer?, CVReturn) {
        var destination: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault,
            pixelBufferPool,
            [
                kCVPixelBufferPoolAllocationThresholdKey:
                    LumenSkyLightMetalStagingPolicy.poolCapacity
            ] as CFDictionary,
            &destination
        )
        return (destination, status)
    }

    func makeTexture(
        from pixelBuffer: CVPixelBuffer,
        plane: Int
    ) -> (CVMetalTexture?, CVReturn) {
        let pixelFormat = plane == 0
            ? format.lumaPixelFormat
            : format.chromaPixelFormat
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            plane,
            &texture
        )
        guard status == kCVReturnSuccess,
              let texture,
              CVMetalTextureGetTexture(texture) != nil else {
            return (nil, status == kCVReturnSuccess
                ? kCVReturnInvalidArgument
                : status)
        }
        return (texture, status)
    }

    func flush() {
        CVMetalTextureCacheFlush(textureCache, 0)
        CVPixelBufferPoolFlush(pixelBufferPool, .excessBuffers)
    }
}

struct LumenSkyLightMetalStagingResourceError: Error, LocalizedError {
    let reason: String

    init(_ reason: String) {
        self.reason = reason
    }

    var errorDescription: String? { reason }
}
