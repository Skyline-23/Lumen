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

/// The caller owns immutable source pixels until conversion completes. A
/// destination supplied for a partial update must not be leased to an encoder.
struct LumenRGB10ConversionSurface: @unchecked Sendable {
    let buffer: CVPixelBuffer
}

struct LumenRGB10ConversionResult: Sendable {
    // A partial update accepts only a successfully completed result minted by
    // the same converter, never an arbitrary (possibly uninitialized) P010 buffer.
    fileprivate let ownerID: UUID
    let surface: LumenRGB10ConversionSurface
    let gpuMilliseconds: Double
    let elapsedMilliseconds: Double
    let region: CGRect
}

private struct LumenRGB10ConversionLease: @unchecked Sendable {
    let source: LumenRGB10ConversionSurface
    let destination: LumenRGB10ConversionSurface
    let textures: [CVMetalTexture]
}

/// PQ-encoded BT.2020 RGB to video-range P010. No EOTF/OETF is applied:
/// the non-constant-luminance YCbCr matrix operates on the encoded channels.
/// Not enabled by the production capture runtime until its live-source color
/// semantics, buffer history and matched E2E gain have been verified.
actor LumenRGB10ToP010Converter {
    private let ownerID = UUID()
    private let resources: LumenSkyLightMetalStagingResources
    private let pipeline: MTLComputePipelineState
    private var inFlightDestinations: Set<UInt> = []

    init(width: Int, height: Int) throws {
        guard width > 0, height > 0, width.isMultiple(of: 2), height.isMultiple(of: 2) else {
            throw LumenSkyLightMetalStagingResourceError("RGB10 conversion requires positive even dimensions")
        }
        resources = try .make(width: width, height: height,
                              pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        float packed10(float value) { return round(value) * (64.0f / 65535.0f); }
        kernel void rgb10_to_p010(texture2d<float, access::read> rgb [[texture(0)]],
                                 texture2d<float, access::write> yPlane [[texture(1)]],
                                 texture2d<float, access::write> uvPlane [[texture(2)]],
                                 constant uint2 &origin [[buffer(0)]],
                                 constant uint2 &extent [[buffer(1)]],
                                 uint2 cell [[thread_position_in_grid]]) {
            if (any(cell >= extent / 2)) return;
            uint2 p = origin + cell * 2;
            const float3 weights = float3(0.2627f, 0.6780f, 0.0593f);
            float3 average = float3(0);
            for (uint dy = 0; dy < 2; ++dy) for (uint dx = 0; dx < 2; ++dx) {
                uint2 at = p + uint2(dx, dy);
                float3 c = rgb.read(at).rgb;
                average += c * 0.25f;
                float y = dot(c, weights);
                yPlane.write(float4(packed10(clamp(64.0f + 876.0f * y, 64.0f, 940.0f)), 0, 0, 1), at);
            }
            float luma = dot(average, weights);
            float cb = 512.0f + 896.0f * (average.b - luma) / (2.0f * (1.0f - weights.b));
            float cr = 512.0f + 896.0f * (average.r - luma) / (2.0f * (1.0f - weights.r));
            uvPlane.write(float4(packed10(clamp(cb, 64.0f, 960.0f)),
                                 packed10(clamp(cr, 64.0f, 960.0f)), 0, 1), p / 2);
        }
        """
        let library = try resources.device.makeLibrary(source: source, options: nil)
        guard let function = library.makeFunction(name: "rgb10_to_p010") else {
            throw LumenSkyLightMetalStagingResourceError("RGB10 conversion kernel missing")
        }
        pipeline = try resources.device.makeComputePipelineState(function: function)
    }

    func convert(_ source: LumenRGB10ConversionSurface,
                 destination existing: LumenRGB10ConversionResult? = nil,
                 dirtyRegion: CGRect? = nil) async throws -> LumenRGB10ConversionResult {
        let started = ProcessInfo.processInfo.systemUptime
        guard inFlightDestinations.count < 2,
              CVPixelBufferGetPixelFormatType(source.buffer) == kCVPixelFormatType_ARGB2101010LEPacked,
              CVPixelBufferGetWidth(source.buffer) == resources.width,
              CVPixelBufferGetHeight(source.buffer) == resources.height,
              CVBufferCopyAttachment(source.buffer, kCVImageBufferTransferFunctionKey, nil) as? String == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String,
              CVBufferCopyAttachment(source.buffer, kCVImageBufferColorPrimariesKey, nil) as? String == kCVImageBufferColorPrimaries_ITU_R_2020 as String else {
            throw LumenSkyLightMetalStagingResourceError("RGB10 source format/color contract or two-slot admission failed")
        }
        let bounds = CGRect(x: 0, y: 0, width: resources.width, height: resources.height)
        guard existing == nil || existing?.ownerID == ownerID else {
            throw LumenSkyLightMetalStagingResourceError("RGB10 destination belongs to another converter")
        }
        let requested = dirtyRegion ?? bounds
        guard requested.origin.x.isFinite, requested.origin.y.isFinite,
              requested.width.isFinite, requested.height.isFinite,
              !requested.isEmpty, bounds.contains(requested), dirtyRegion == nil || existing != nil else {
            throw LumenSkyLightMetalStagingResourceError("Partial conversion requires valid region and initialized destination")
        }
        let x = floor(requested.minX / 2) * 2, y = floor(requested.minY / 2) * 2
        let region = CGRect(x: x, y: y, width: ceil(requested.maxX / 2) * 2 - x,
                            height: ceil(requested.maxY / 2) * 2 - y)
        let destination: LumenRGB10ConversionSurface
        if let existing { destination = existing.surface }
        else {
            let (buffer, status) = resources.allocateDestination()
            guard status == kCVReturnSuccess, let buffer else {
                throw LumenSkyLightMetalStagingResourceError("RGB10 destination allocation failed: \(status)")
            }
            destination = .init(buffer: buffer)
        }
        guard resources.format.mismatchDescription(for: destination.buffer,
            width: resources.width, height: resources.height) == nil else {
            throw LumenSkyLightMetalStagingResourceError("RGB10 destination contract mismatch")
        }
        let identity = UInt(bitPattern: Unmanaged.passUnretained(destination.buffer).toOpaque())
        guard !inFlightDestinations.contains(identity) else {
            throw LumenSkyLightMetalStagingResourceError("RGB10 destination already in GPU use")
        }
        var sourceTexture: CVMetalTexture?
        let sourceStatus = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, resources.textureCache,
            source.buffer, nil, .bgr10a2Unorm, resources.width, resources.height, 0, &sourceTexture)
        let (yTexture, yStatus) = resources.makeTexture(from: destination.buffer, plane: 0)
        let (uvTexture, uvStatus) = resources.makeTexture(from: destination.buffer, plane: 1)
        guard sourceStatus == kCVReturnSuccess, yStatus == kCVReturnSuccess, uvStatus == kCVReturnSuccess,
              let sourceTexture, let yTexture, let uvTexture,
              let rgb = CVMetalTextureGetTexture(sourceTexture), let luma = CVMetalTextureGetTexture(yTexture),
              let chroma = CVMetalTextureGetTexture(uvTexture),
              let command = resources.commandQueue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
            throw LumenSkyLightMetalStagingResourceError("RGB10 GPU resources failed: \(sourceStatus)/\(yStatus)/\(uvStatus)")
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(rgb, index: 0); encoder.setTexture(luma, index: 1); encoder.setTexture(chroma, index: 2)
        var origin = SIMD2<UInt32>(UInt32(region.minX), UInt32(region.minY))
        var extent = SIMD2<UInt32>(UInt32(region.width), UInt32(region.height))
        encoder.setBytes(&origin, length: MemoryLayout.size(ofValue: origin), index: 0)
        encoder.setBytes(&extent, length: MemoryLayout.size(ofValue: extent), index: 1)
        encoder.dispatchThreads(.init(width: Int(region.width) / 2, height: Int(region.height) / 2, depth: 1),
                                threadsPerThreadgroup: .init(width: 16, height: 8, depth: 1))
        encoder.endEncoding()
        let lease = LumenRGB10ConversionLease(source: source, destination: destination,
                                              textures: [sourceTexture, yTexture, uvTexture])
        inFlightDestinations.insert(identity)
        defer { inFlightDestinations.remove(identity) }
        let outcome: (Bool, Double, String?) = await withCheckedContinuation { continuation in
            command.addCompletedHandler { completed in
                withExtendedLifetime(lease) {
                    continuation.resume(returning: (completed.status == .completed,
                        max(0, completed.gpuEndTime - completed.gpuStartTime) * 1_000,
                        completed.error?.localizedDescription))
                }
            }
            command.commit()
        }
        guard outcome.0 else { throw LumenSkyLightMetalStagingResourceError(outcome.2 ?? "RGB10 GPU command failed") }
        CVBufferPropagateAttachments(source.buffer, destination.buffer)
        CVBufferSetAttachment(destination.buffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(destination.buffer, kCVImageBufferChromaLocationTopFieldKey,
                              kCVImageBufferChromaLocation_Center, .shouldPropagate)
        return .init(ownerID: ownerID, surface: destination, gpuMilliseconds: outcome.1,
                     elapsedMilliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1_000, region: region)
    }
}
