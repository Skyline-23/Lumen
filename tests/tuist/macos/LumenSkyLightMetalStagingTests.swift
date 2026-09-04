@testable import LumenMacBridge
import CoreVideo
import Foundation
import Metal
import XCTest

final class LumenSkyLightMetalStagingTests: XCTestCase {
    func testSupportedBiPlanarFormatsUseMatchingMetalPlaneFormats() {
        let sdr = LumenSkyLightMetalStagingFormat(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        XCTAssertEqual(sdr?.lumaPixelFormat, .r8Unorm)
        XCTAssertEqual(sdr?.chromaPixelFormat, .rg8Unorm)

        let hdr = LumenSkyLightMetalStagingFormat(
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )
        XCTAssertEqual(hdr?.lumaPixelFormat, .r16Unorm)
        XCTAssertEqual(hdr?.chromaPixelFormat, .rg16Unorm)
    }

    func testUnsupportedFormatCannotEnterMetalStaging() {
        XCTAssertNil(
            LumenSkyLightMetalStagingFormat(
                pixelFormat: kCVPixelFormatType_32BGRA
            )
        )
    }

    func testBoundedAdmissionAllowsTwoCopiesAndRejectsThird() {
        var admission = LumenSkyLightMetalStagingAdmission()
        XCTAssertTrue(admission.beginCopy())
        XCTAssertTrue(admission.beginCopy())
        XCTAssertEqual(admission.inFlightCopyCount, 2)
        XCTAssertFalse(admission.beginCopy())
        XCTAssertTrue(admission.isCopyInFlight)
        XCTAssertTrue(admission.completeCopy())
        XCTAssertEqual(admission.inFlightCopyCount, 1)
        XCTAssertFalse(admission.canDrain)
        XCTAssertTrue(admission.completeCopy())
        XCTAssertEqual(admission.inFlightCopyCount, 0)
        XCTAssertTrue(admission.canDrain)
        XCTAssertFalse(admission.isCopyInFlight)
        XCTAssertFalse(admission.completeCopy())
    }

    func testSupportedShapeAccepts420vAndX420PlaneGeometry() throws {
        let pixelFormats: [OSType] = [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        ]
        for pixelFormat in pixelFormats {
            var pixelBufferValue: CVPixelBuffer?
            XCTAssertEqual(
                CVPixelBufferCreate(
                    kCFAllocatorDefault,
                    64,
                    32,
                    pixelFormat,
                    [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                    &pixelBufferValue
                ),
                kCVReturnSuccess,
                "pixel format=\(pixelFormat)"
            )
            let pixelBuffer = try XCTUnwrap(pixelBufferValue)
            let format = try XCTUnwrap(
                LumenSkyLightMetalStagingFormat(pixelFormat: pixelFormat)
            )

            XCTAssertNil(
                format.mismatchDescription(
                    for: pixelBuffer,
                    width: 64,
                    height: 32
                ),
                "pixel format=\(pixelFormat)"
            )
            XCTAssertNotNil(
                format.mismatchDescription(
                    for: pixelBuffer,
                    width: 32,
                    height: 32
                ),
                "pixel format=\(pixelFormat)"
            )
        }
    }

    func testPoolCapacityCoversPendingCopyAndTwoVideoToolboxSlots() {
        XCTAssertEqual(
            LumenSkyLightMetalStagingPolicy.maximumGPUCopiesInFlight,
            2
        )
        XCTAssertEqual(
            LumenSkyLightMetalStagingPolicy.poolCapacity,
            LumenRealtimeVideoEncoderAdmissionPolicy
                .maximumInflightFrameCount + 1 +
                LumenSkyLightMetalStagingPolicy.maximumGPUCopiesInFlight
        )
        XCTAssertEqual(LumenSkyLightMetalStagingPolicy.poolCapacity, 5)
    }

    func testStagingGenerationRetiresOlderCopyCompletion() {
        var generation = LumenSkyLightMetalStagingGeneration()
        let first = generation.advance()
        XCTAssertTrue(generation.accepts(first))

        let second = generation.advance()
        XCTAssertFalse(generation.accepts(first))
        XCTAssertTrue(generation.accepts(second))
    }

    func testPoolEnforcesTheBoundedOwnershipCapacity() throws {
        let resources = try LumenSkyLightMetalStagingResources.make(
            width: 64,
            height: 32,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        var retained: [CVPixelBuffer] = []
        for _ in 0..<LumenSkyLightMetalStagingPolicy.poolCapacity {
            let (pixelBuffer, status) = resources.allocateDestination()
            XCTAssertEqual(status, kCVReturnSuccess)
            retained.append(try XCTUnwrap(pixelBuffer))
        }

        let (overflow, overflowStatus) = resources.allocateDestination()
        XCTAssertNil(overflow)
        XCTAssertEqual(
            overflowStatus,
            kCVReturnWouldExceedAllocationThreshold
        )

        retained.removeLast()
        let (replacement, replacementStatus) = resources.allocateDestination()
        XCTAssertEqual(replacementStatus, kCVReturnSuccess)
        XCTAssertNotNil(replacement)
    }

    func testMetalBlitCopiesBothPlanesAndPreservesColorAttachments() throws {
        try assertMetalBlit(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            colorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            transferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
            matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2
        )
        try assertMetalBlit(
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            colorPrimaries: kCVImageBufferColorPrimaries_ITU_R_2020,
            transferFunction:
                kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
            matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020
        )
    }

    private func assertMetalBlit(
        pixelFormat: OSType,
        colorPrimaries: CFString,
        transferFunction: CFString,
        matrix: CFString
    ) throws {
        let width = 64
        let height = 32
        let resources = try LumenSkyLightMetalStagingResources.make(
            width: width,
            height: height,
            pixelFormat: pixelFormat
        )
        let source = try makePixelBuffer(
            width: width,
            height: height,
            pixelFormat: pixelFormat
        )
        let (destinationValue, destinationStatus) =
            resources.allocateDestination()
        XCTAssertEqual(destinationStatus, kCVReturnSuccess)
        let destination = try XCTUnwrap(destinationValue)

        fillPlanes(source, seed: pixelFormat ==
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ? 0x61 : 0x23)
        CVBufferSetAttachment(
            source,
            kCVImageBufferColorPrimariesKey,
            colorPrimaries,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            source,
            kCVImageBufferTransferFunctionKey,
            transferFunction,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            source,
            kCVImageBufferYCbCrMatrixKey,
            matrix,
            .shouldPropagate
        )
        CVBufferPropagateAttachments(source, destination)

        let sourceLuma = try makeTexture(
            resources: resources,
            pixelBuffer: source,
            plane: 0
        )
        let sourceChroma = try makeTexture(
            resources: resources,
            pixelBuffer: source,
            plane: 1
        )
        let destinationLuma = try makeTexture(
            resources: resources,
            pixelBuffer: destination,
            plane: 0
        )
        let destinationChroma = try makeTexture(
            resources: resources,
            pixelBuffer: destination,
            plane: 1
        )
        let commandBuffer = try XCTUnwrap(
            resources.commandQueue.makeCommandBuffer()
        )
        let blit = try XCTUnwrap(commandBuffer.makeBlitCommandEncoder())
        blit.copy(
            from: try XCTUnwrap(CVMetalTextureGetTexture(sourceLuma)),
            to: try XCTUnwrap(CVMetalTextureGetTexture(destinationLuma))
        )
        blit.copy(
            from: try XCTUnwrap(CVMetalTextureGetTexture(sourceChroma)),
            to: try XCTUnwrap(CVMetalTextureGetTexture(destinationChroma))
        )
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        XCTAssertEqual(commandBuffer.status, .completed)
        XCTAssertNil(commandBuffer.error)
        XCTAssertEqual(activePlaneBytes(source), activePlaneBytes(destination))
        XCTAssertEqual(
            attachment(destination, key: kCVImageBufferColorPrimariesKey),
            colorPrimaries as String
        )
        XCTAssertEqual(
            attachment(destination, key: kCVImageBufferTransferFunctionKey),
            transferFunction as String
        )
        XCTAssertEqual(
            attachment(destination, key: kCVImageBufferYCbCrMatrixKey),
            matrix as String
        )
    }

    private func makePixelBuffer(
        width: Int,
        height: Int,
        pixelFormat: OSType
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            [
                kCVPixelBufferIOSurfacePropertiesKey: [:],
                kCVPixelBufferMetalCompatibilityKey: true
            ] as CFDictionary,
            &pixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        return try XCTUnwrap(pixelBuffer)
    }

    private func makeTexture(
        resources: LumenSkyLightMetalStagingResources,
        pixelBuffer: CVPixelBuffer,
        plane: Int
    ) throws -> CVMetalTexture {
        let (texture, status) = resources.makeTexture(
            from: pixelBuffer,
            plane: plane
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        return try XCTUnwrap(texture)
    }

    private func fillPlanes(_ pixelBuffer: CVPixelBuffer, seed: UInt8) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(
                pixelBuffer,
                plane
            ) else {
                XCTFail("Missing plane base address")
                continue
            }
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(
                pixelBuffer,
                plane
            )
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            for row in 0..<height {
                memset(
                    base.advanced(by: row * rowBytes),
                    Int32(seed &+ UInt8((row + plane * 17) & 0xff)),
                    rowBytes
                )
            }
        }
    }

    private func activePlaneBytes(
        _ pixelBuffer: CVPixelBuffer
    ) -> [[UInt8]] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let bytesPerComponent =
            CVPixelBufferGetPixelFormatType(pixelBuffer) ==
                kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ? 2 : 1
        return (0..<CVPixelBufferGetPlaneCount(pixelBuffer)).map { plane in
            guard let base = CVPixelBufferGetBaseAddressOfPlane(
                pixelBuffer,
                plane
            ) else {
                XCTFail("Missing plane base address")
                return []
            }
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(
                pixelBuffer,
                plane
            )
            let activeRowBytes = CVPixelBufferGetWidthOfPlane(
                pixelBuffer,
                plane
            ) * bytesPerComponent * (plane == 0 ? 1 : 2)
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            var bytes: [UInt8] = []
            bytes.reserveCapacity(activeRowBytes * height)
            for row in 0..<height {
                let rowBase = base.advanced(by: row * rowBytes)
                    .assumingMemoryBound(to: UInt8.self)
                bytes.append(contentsOf: UnsafeBufferPointer(
                    start: rowBase,
                    count: activeRowBytes
                ))
            }
            return bytes
        }
    }

    private func attachment(
        _ pixelBuffer: CVPixelBuffer,
        key: CFString
    ) -> String? {
        CVBufferCopyAttachment(pixelBuffer, key, nil) as? String
    }
}
