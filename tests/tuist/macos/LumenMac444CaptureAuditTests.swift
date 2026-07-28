import CoreGraphics
import CoreMedia
import CoreVideo
@testable import LumenMacBridge
import XCTest

final class LumenMac444CaptureAuditTests: XCTestCase {
    func testLiveRequiredHardware444CaptureWritesAuditArtifactWhenRequested() async throws {
        guard let artifactPath = ProcessInfo.processInfo.environment["LUMEN_VT444_CAPTURE_ARTIFACT_PATH"] else {
            throw XCTSkip("Set LUMEN_VT444_CAPTURE_ARTIFACT_PATH for permission-gated ScreenCaptureKit QA")
        }
        let artifactURL = URL(fileURLWithPath: artifactPath)
        try? FileManager.default.removeItem(at: artifactURL)

        let configurations = [
            makeConfiguration(codec: .h264, profile: .h264High444Predictive, targetFrameRate: 60),
            makeConfiguration(codec: .hevc, profile: .hevcMain444, targetFrameRate: 120),
            makeConfiguration(
                codec: .hevc,
                profile: .hevcMain44410,
                bitDepth: 10,
                dynamicRange: .hdr10,
                colorRange: .limited,
                targetFrameRate: 60
            )
        ]
        var audits: [LumenExactCaptureAuditSnapshot] = []
        for configuration in configurations {
            audits.append(try await captureAudit(configuration: configuration))
        }
        try FileManager.default.createDirectory(
            at: artifactURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(audits).write(to: artifactURL, options: .atomic)

        Self.assertExpectedAudits(audits)
    }

    private static func assertExpectedAudits(
        _ audits: [LumenExactCaptureAuditSnapshot]
    ) {
        XCTAssertEqual(audits.map(\.inputFourCC), ["444f", "444f", "xf44"])
        XCTAssertEqual(audits.map(\.lumaPlaneWidth), [192, 192, 192])
        XCTAssertEqual(audits.map(\.lumaPlaneHeight), [108, 108, 108])
        XCTAssertEqual(audits.map(\.chromaPlaneWidth), [192, 192, 192])
        XCTAssertEqual(audits.map(\.chromaPlaneHeight), [108, 108, 108])
        XCTAssertEqual(
            audits.map(\.profile),
            [
                "H264_High444Predictive_AutoLevel",
                "HEVC_Main444_AutoLevel",
                "HEVC_Main44410_AutoLevel"
            ]
        )
        XCTAssertTrue(audits.allSatisfy { $0.hardwareUsed == true })
        XCTAssertEqual(audits.map(\.configurationAtom), ["avcC", "hvcC", "hvcC"])
        XCTAssertEqual(audits[0].profileIdc, 244)
        XCTAssertEqual(audits[1].chromaFormatIdc, 3)
        XCTAssertEqual(audits[1].lumaBitDepth, 8)
        XCTAssertEqual(audits[1].chromaBitDepth, 8)
        XCTAssertEqual(audits[2].chromaFormatIdc, 3)
        XCTAssertEqual(audits[2].lumaBitDepth, 10)
        XCTAssertEqual(audits[2].chromaBitDepth, 10)
        XCTAssertTrue(audits.allSatisfy { $0.conversionCount == 0 })
        XCTAssertEqual(audits[2].colorPrimaries, "ITU_R_2020")
        XCTAssertEqual(audits[2].transferFunction, "SMPTE_ST_2084_PQ")
        XCTAssertEqual(audits[2].yCbCrMatrix, "ITU_R_2020")
    }

    private func makeConfiguration(
        codec: LumenCaptureCodec,
        profile: LumenCaptureVideoProfile,
        bitDepth: Int = 8,
        dynamicRange: LumenCaptureDynamicRange = .sdr,
        colorRange: LumenCaptureColorRange = .full,
        targetFrameRate: Int = 120
    ) -> LumenMacCaptureConfiguration {
        LumenMacCaptureConfiguration(
            displayID: CGMainDisplayID(),
            codec: codec,
            videoProfile: profile,
            chromaSubsampling: .yuv444,
            bitDepth: bitDepth,
            dynamicRange: dynamicRange,
            colorRange: colorRange,
            targetFrameRate: targetFrameRate,
            targetVideoBitRateKbps: 20_000,
            requestedWidth: 192,
            requestedHeight: 108,
            sinkRequest: LumenBridgeSinkRequest(
                capability: LumenBridgeSinkCapability(
                    gamut: dynamicRange == .hdr10 ? .rec2020 : .srgb,
                    transfer: dynamicRange == .hdr10 ? .pq : .sdr,
                    supportsFrameGatedHDR: dynamicRange == .hdr10,
                    supportsPerFrameHDRMetadata: dynamicRange == .hdr10
                ),
                dynamicRangeTransport: dynamicRange == .hdr10
                    ? LumenMacDynamicRangeTransportFullFrameHDR
                    : LumenMacDynamicRangeTransportSDR
            ),
            effectiveDisplayState: LumenBridgeEffectiveDisplayState(
                gamut: dynamicRange == .hdr10 ? .rec2020 : .srgb,
                transfer: dynamicRange == .hdr10 ? .pq : .sdr
            )
        )
    }

    private func captureAudit(
        configuration: LumenMacCaptureConfiguration
    ) async throws -> LumenExactCaptureAuditSnapshot {
        let session = LumenEncodedCaptureSession(
            configuration: configuration,
            runtimeFactory:
                LumenProductionCaptureRuntimeFactory()
        )
        let gate = LumenFirstEncodedFrameGate()
        let generation = await gate.beginCapture()
        try await session.start(
            callbacks: LumenEncodedCaptureCallbacks(
                frameHandler: { frame in
                    Task {
                        await gate.resolve(
                            generation: generation,
                            sequenceNumber: frame.sourceSequenceNumber
                        )
                    }
                },
                eventHandler: nil
            )
        )
        do {
            try await gate.wait(for: generation, timeoutNanoseconds: 5_000_000_000)
            var audit = await session.statisticsSnapshot().exactCaptureAudit
            for _ in 0 ..< 100 {
                if audit.configurationAtom != nil { break }
                try await Task.sleep(nanoseconds: 10_000_000)
                audit = await session.statisticsSnapshot().exactCaptureAudit
            }
            await session.stop()
            return audit
        } catch {
            let statistics = await session.statisticsSnapshot()
            await session.stop()
            if let lastErrorDescription = statistics.lastErrorDescription {
                throw NSError(
                    domain: "LumenMac444CaptureTests.LiveCapture",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: lastErrorDescription]
                )
            }
            throw error
        }
    }

}
