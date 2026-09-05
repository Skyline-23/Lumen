import CoreMedia
import CoreVideo
import Darwin
import Foundation
import VideoToolbox

/// Entry point used only by the existing isolated screen-measurement tool.
/// The fixture is immutable; orchestration is actor-isolated and encoding uses
/// the product runtime, including its two-slot/latest-pending admission policy.
@objc(LumenEncoderReplayProbe)
public final class LumenEncoderReplayProbe: NSObject {
    @objc(runWithFrames:width:height:hdr:bitrate:duration:comparePeriodic:compareOverlap:compareDecoderLoad:compareSourceCadence:compareMetalStaging:compareForwarder:initialBitrateForUpdate:sourceArrivalNanos:sourcePresentationNanos:sourceLoadController:completion:)
    public static func run(
        frames: NSArray, width: Int, height: Int, hdr: Bool, bitrate: Int,
        duration: Double, comparePeriodic: Bool, compareOverlap: Bool, compareDecoderLoad: Bool,
        compareSourceCadence: Bool,
        compareMetalStaging: Bool,
        compareForwarder: Bool,
        initialBitrateForUpdate: Int,
        sourceArrivalNanos: [NSNumber]?,
        sourcePresentationNanos: [NSNumber]?,
        sourceLoadController: (@Sendable (Bool) -> NSDictionary)?,
        completion: @escaping @Sendable (String) -> Void
    ) {
        guard frames.count > 0, frames.count <= 32, width > 0, height > 0,
              duration.isFinite, (1 ... 60).contains(duration), bitrate > 0 else {
            completion("{\"error\":\"invalid-production-replay-arguments\"}")
            return
        }
        let buffers = frames.map { $0 as! CVPixelBuffer }
        let fixture = LumenEncoderReplayFixture(buffers: buffers)
        let arrivals = sourceArrivalNanos?.map(\.int64Value)
        let presentations = sourcePresentationNanos?.map(\.int64Value)
        Task {
            let runner = LumenEncoderReplayRunner()
            if initialBitrateForUpdate > 0 {
                guard duration >= 8, initialBitrateForUpdate >= bitrate else {
                    completion("{\"error\":\"invalid-rate-update-comparison\"}")
                    return
                }
                var results: [String] = []
                for initial in [bitrate, initialBitrateForUpdate, bitrate] {
                    results.append(await runner.run(
                        fixture: fixture, width: width, height: height, hdr: hdr,
                        bitrate: bitrate, duration: duration, periodicSeconds: 1,
                        initialBitrateForUpdate: initial
                    ))
                }
                completion("{\"mode\":\"production-rate-update-aba\",\"comparisons\":[" + results.joined(separator: ",") + "]}")
            } else if compareForwarder {
                var results: [String] = []
                for enabled in [false, true, false] {
                    results.append(await runner.run(
                        fixture: fixture, width: width, height: height, hdr: hdr,
                        bitrate: bitrate, duration: duration, periodicSeconds: 1,
                        forwarderRetention: enabled
                    ))
                }
                completion("{\"mode\":\"production-forwarder-retention-aba\",\"comparisons\":[" + results.joined(separator: ",") + "]}")
            } else if compareMetalStaging {
                var results: [String] = []
                for enabled in [false, true, false] {
                    results.append(await runner.run(
                        fixture: fixture, width: width, height: height, hdr: hdr,
                        bitrate: bitrate, duration: duration, periodicSeconds: 1,
                        metalStaging: enabled
                    ))
                }
                completion("{\"mode\":\"production-metal-staging-aba\",\"comparisons\":[" + results.joined(separator: ",") + "]}")
            } else if let arrivals {
                guard arrivals.count >= 120, arrivals.count <= 10_000,
                      zip(arrivals, arrivals.dropFirst()).allSatisfy({ $1 > $0 }),
                      let first = arrivals.first, let last = arrivals.last,
                      last - first >= 5_000_000_000 else {
                    completion("{\"error\":\"source-arrival-trace-invalid\"}")
                    return
                }
                let offsets = arrivals.map { $0 - first }
                let intervals = zip(offsets, offsets.dropFirst()).map { $1 - $0 }.sorted()
                let period = offsets.last! + intervals[intervals.count / 2]
                let count = offsets.count
                if let presentations {
                    guard presentations.count == count, presentations.first == 0,
                          presentations.allSatisfy({ (0 ... 60_000_000_000).contains($0) }),
                          zip(presentations, presentations.dropFirst()).allSatisfy({ $1 > $0 }) else {
                        completion("{\"error\":\"source-presentation-trace-invalid\"}")
                        return
                    }
                    // A single measured cycle avoids manufacturing a PTS seam
                    // when actual display time leads/lags source arrival time.
                    let matchedDuration = min(duration, Double(period) / 1e9)
                    var results: [String] = []
                    for actualPTS in [false, true, false] {
                        results.append(await runner.run(
                            fixture: fixture, width: width, height: height, hdr: hdr,
                            bitrate: bitrate, duration: matchedDuration, periodicSeconds: 1,
                            arrivalPattern: offsets, arrivalPeriod: period, arrivalKind: "measured",
                            presentationPattern: actualPTS ? presentations : offsets
                        ))
                    }
                    completion("{\"mode\":\"production-live-presentation-aba\",\"comparisons\":[" + results.joined(separator: ",") + "]}")
                    return
                }
                let uniform = (0 ..< count).map { Int64($0) * period / Int64(count) }
                var results: [String] = []
                for (kind, pattern) in [("uniform", uniform), ("measured", offsets), ("uniform", uniform)] {
                    results.append(await runner.run(
                        fixture: fixture, width: width, height: height, hdr: hdr,
                        bitrate: bitrate, duration: duration, periodicSeconds: 1,
                        arrivalPattern: pattern, arrivalPeriod: period, arrivalKind: kind
                    ))
                }
                completion("{\"mode\":\"production-source-jitter-aba\",\"arrivalOffsetsNanos\":[" +
                    offsets.map(String.init).joined(separator: ",") +
                    "],\"arrivalPeriodNanos\":\(period),\"comparisons\":[" + results.joined(separator: ",") + "]}")
            } else if let sourceLoadController {
                var results: [[String: Any]] = []
                for enabled in [false, true, false] {
                    let start = sourceLoadController(enabled)
                    guard start["success"] as? Bool == true else {
                        _ = sourceLoadController(false)
                        completion("{\"error\":\"raw-source-load-start-failed\"}")
                        return
                    }
                    let result = await runner.run(
                        fixture: fixture, width: width, height: height, hdr: hdr,
                        bitrate: bitrate, duration: duration, periodicSeconds: 1,
                        decoderLoad: enabled && start["combinedLoad"] as? Bool == true,
                        sourceFrameRate: start["sourceFrameRate"] as? Int ?? 120,
                        metalStaging: start["combinedLoad"] as? Bool == true ? enabled : nil,
                        forwarderRetention: start["liveDisplayID"] != nil || (enabled && start["combinedLoad"] as? Bool == true),
                        liveDisplayID: (start["liveDisplayID"] as? NSNumber)?.uint32Value
                    )
                    let sourceResult = sourceLoadController(false)
                    guard var row = (try? JSONSerialization.jsonObject(
                        with: Data(result.utf8)
                    )) as? [String: Any] else {
                        completion("{\"error\":\"raw-source-load-result-invalid\"}")
                        return
                    }
                    row["rawSourceLoad"] = enabled
                    row["combinedLoadComparison"] = start["combinedLoad"] as? Bool == true
                    row["rawSourceMetrics"] = sourceResult
                    row["rawSourceValid"] = sourceResult["success"] as? Bool == true
                        && (start["liveDisplayID"] != nil
                            ? (row["actualSourceFrames"] as? Int ?? 0) > 0
                            : (!enabled || (sourceResult["completeFrames"] as? Int ?? 0) > 0))
                    results.append(row)
                }
                let result: [String: Any] = [
                    "mode": "production-raw-source-load-aba", "comparisons": results
                ]
                let data = try? JSONSerialization.data(withJSONObject: result, options: .sortedKeys)
                completion(String(decoding: data ?? Data("{\"error\":\"result-encoding-failed\"}".utf8), as: UTF8.self))
            } else if compareSourceCadence {
                var results: [String] = []
                for sourceFrameRate in [120, 60, 120] {
                    results.append(await runner.run(
                        fixture: fixture, width: width, height: height, hdr: hdr,
                        bitrate: bitrate, duration: duration, periodicSeconds: 1,
                        sourceFrameRate: sourceFrameRate
                    ))
                }
                completion("{\"mode\":\"production-source-cadence-aba\",\"comparisons\":[" + results.joined(separator: ",") + "]}")
            } else if compareDecoderLoad {
                var results: [String] = []
                for enabled in [false, true, false] {
                    results.append(await runner.run(
                        fixture: fixture, width: width, height: height, hdr: hdr,
                        bitrate: bitrate, duration: duration, periodicSeconds: 1,
                        decoderLoad: enabled
                    ))
                }
                completion("{\"mode\":\"production-decoder-load-aba\",\"comparisons\":[" + results.joined(separator: ",") + "]}")
            } else if compareOverlap {
                var results: [String] = []
                for enabled in [false, true, false] {
                    results.append(await runner.run(
                        fixture: fixture, width: width, height: height, hdr: hdr,
                        bitrate: bitrate, duration: duration, periodicSeconds: 1,
                        overlapEnabled: enabled
                    ))
                }
                completion("{\"mode\":\"production-overlap-aba\",\"comparisons\":[" + results.joined(separator: ",") + "]}")
            } else if comparePeriodic {
                var results: [String] = []
                for interval in [1, 4, 1] {
                    results.append(await runner.run(
                        fixture: fixture, width: width, height: height, hdr: hdr,
                        bitrate: bitrate, duration: duration, periodicSeconds: interval
                    ))
                }
                completion("{\"mode\":\"production-periodic-aba\",\"comparisons\":[" + results.joined(separator: ",") + "]}")
            } else {
                completion(await runner.run(
                    fixture: fixture, width: width, height: height,
                    hdr: hdr, bitrate: bitrate, duration: duration, periodicSeconds: 1
                ))
            }
        }
    }
}

private struct LumenEncoderReplayFixture: @unchecked Sendable {
    let buffers: [CVPixelBuffer]
}

// Only the existing runtime's capture/output queue mutates these metrics.
// VideoToolbox callback ordering must remain intact at this C boundary.
private final class LumenEncoderReplayMetrics: @unchecked Sendable {
    var latencies: [Double] = []
    var outputUptimeNanos: [UInt64] = []
    var frameAges: [Double] = []
    var bytes = 0
    var hdrValid = true
    var keyFrames = 0
    var decodeInputDrops = 0

    func record(_ frame: LumenEncodedFrame, requiresHDR: Bool) {
        if let latency = frame.outputCallbackLatencyMilliseconds {
            latencies.append(latency)
            outputUptimeNanos.append(DispatchTime.now().uptimeNanoseconds)
        }
        frameAges.append(LumenMachTime.milliseconds(
            from: frame.sourceDisplayTime, to: mach_absolute_time()
        ))
        bytes += CMSampleBufferGetTotalSampleSize(frame.sampleBuffer)
        if frame.isKeyFrame { keyFrames += 1 }
        if requiresHDR {
            let report = frame.hdrValidationReport
            hdrValid = hdrValid && frame.isHDRSignaled &&
                report.transferFunction == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) &&
                report.hasHDRDisplayMetadata && report.hasContentLightLevelInfo
        }
    }
}

private struct LumenReplayCompressedSample: @unchecked Sendable {
    let value: CMSampleBuffer
    let acknowledgeAfterDecode: Bool
    var decoded: (@Sendable (Bool) -> Void)? = nil
}

private struct LumenTileProbeSample: @unchecked Sendable {
    let sample: CMSampleBuffer?
    var status: Int32
    let flags: UInt32
    let x: Int32
    let y: Int32
    let width: Int32
    let height: Int32
    let sourceIndex: Int32
    let callbackNanos: UInt64
}

/// Bounded C-callback ingress for the existing screen harness. Mutable sample
/// collection and decoder coordination remain actor-owned, not in ObjC callbacks.
@objc(LumenTileOutputProbe)
public final class LumenTileOutputProbe: NSObject {
    private let continuation: AsyncStream<LumenTileProbeSample>.Continuation
    private let result: Task<String, Never>
    private let acknowledgements: AsyncStream<LumenTileProbeSample>
    private let acknowledge: AsyncStream<LumenTileProbeSample>.Continuation

    @objc public static var hdrProperties: NSDictionary {
        [kVTCompressionPropertyKey_HDRMetadataInsertionMode as String: kVTHDRMetadataInsertionMode_Auto,
         kVTCompressionPropertyKey_MasteringDisplayColorVolume as String: LumenVideoHDRDisplayMetadata.hdr10Default().encodedData,
         kVTCompressionPropertyKey_ContentLightLevelInfo as String: LumenVideoContentLightLevelInfo.hdr10Default().encodedData] as NSDictionary
    }

    @objc public override convenience init() { self.init(benchmark: false) }

    @objc(initWithBenchmark:)
    public init(benchmark: Bool) {
        let (stream, continuation) = AsyncStream<LumenTileProbeSample>.makeStream(bufferingPolicy: .bufferingOldest(4))
        let (acks, acknowledge) = AsyncStream<LumenTileProbeSample>.makeStream(bufferingPolicy: .bufferingOldest(4))
        self.continuation = continuation
        self.acknowledgements = acks
        self.acknowledge = acknowledge
        result = Task {
            await LumenTileOutputCollector().run(stream, benchmark: benchmark) { output, valid in
                var completed = output
                if !valid { completed.status = -1 }
                acknowledge.yield(completed)
            }
        }
        super.init()
    }

    @objc(recordSample:status:flags:x:y:width:height:sourceIndex:)
    public func record(sample: CMSampleBuffer?, status: Int32, flags: UInt32,
                       x: Int32, y: Int32, width: Int32, height: Int32, sourceIndex: Int32) {
        let output = LumenTileProbeSample(sample: sample, status: status, flags: flags,
            x: x, y: y, width: width, height: height, sourceIndex: sourceIndex,
            callbackNanos: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
        continuation.yield(output)
    }

    /// Saturated capacity screen, not a production/E2E score. The fixture is
    /// immutable and shared with the normal-session control. Two slots only.
    @objc(benchmarkWithFrames:duration:encode:drain:completion:)
    public func benchmark(frames: NSArray, duration: Double,
                          encode: @escaping @Sendable (CVPixelBuffer, Int32, Bool) -> Int32,
                          drain: @escaping @Sendable () -> Int32,
                          completion: @escaping @Sendable (String) -> Void) {
        guard frames.count == 16, duration.isFinite, (1 ... 30).contains(duration) else {
            completion("{\"error\":\"invalid-tile-benchmark-arguments\"}"); return
        }
        let fixture = LumenEncoderReplayFixture(buffers: frames.map { $0 as! CVPixelBuffer })
        let acks = acknowledgements
        let finish = continuation
        let pending = result
        Task {
            let timing = await LumenTileReplayDriver().run(fixture: fixture, duration: duration,
                outputs: acks, encode: encode, drain: drain)
            finish.finish()
            let validation = await pending.value
            completion("{\"timing\":" + timing + ",\"validation\":" + validation + "}")
        }
    }

    @objc(finishWithCompletion:)
    public func finish(completion: @escaping @Sendable (String) -> Void) {
        continuation.finish()
        let pending = result
        Task { completion(await pending.value) }
    }
}

private actor LumenTileReplayDriver {
    func run(fixture: LumenEncoderReplayFixture, duration: Double,
             outputs: AsyncStream<LumenTileProbeSample>,
             encode: @Sendable (CVPixelBuffer, Int32, Bool) -> Int32,
             drain: @Sendable () -> Int32) async -> String {
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let measureStart = start + 1_000_000_000
        let end = measureStart + UInt64(duration * 1e9)
        var submitted: Int32 = 0
        var received = 0
        var measured = 0
        var bytes = 0
        var failed = 0
        var lastKeyframe: UInt64 = 0
        var pending: [Int32: UInt64] = [:]
        var latencies: [Double] = []
        var calls: [Double] = []
        var gaps: [Double] = []
        var lastCallback: UInt64?
        var peak = 0
        func submit() {
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            guard now < end, failed == 0, submitted < 10_000 else { return }
            let force = lastKeyframe == 0 || now - lastKeyframe >= 1_000_000_000
            if force { lastKeyframe = now }
            let index = submitted
            pending[index] = now
            let status = encode(fixture.buffers[Int(index) % fixture.buffers.count], index, force)
            let after = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            if now >= measureStart { calls.append(Double(after - now) / 1e6) }
            if status == noErr { submitted += 1; peak = max(peak, pending.count) }
            else { failed += 1; pending.removeValue(forKey: index) }
        }
        submit(); submit()
        if !pending.isEmpty {
            for await output in outputs {
                guard let began = pending.removeValue(forKey: output.sourceIndex) else { failed += 1; continue }
                if output.sourceIndex != Int32(received) || output.status != noErr || output.sample == nil || output.flags & 2 != 0 { failed += 1 }
                received += 1
                let stamp = output.callbackNanos
                if stamp >= measureStart && stamp < end {
                    measured += 1
                    bytes += output.sample.map(CMSampleBufferGetTotalSampleSize) ?? 0
                    latencies.append(Double(stamp - began) / 1e6)
                    if let lastCallback { gaps.append(Double(stamp - lastCallback) / 1e6) }
                    lastCallback = stamp
                }
                submit()
                if pending.isEmpty { break }
            }
        }
        let drainStatus = drain()
        func percentile(_ input: [Double], _ p: Double) -> Double {
            let values = input.sorted()
            return values.isEmpty ? 0 : values[min(values.count - 1, Int(ceil(Double(values.count - 1) * p)))]
        }
        let value: [String: Any] = ["mode": "two-slot-saturated-capacity-screen", "warmupSeconds": 1,
            "durationSeconds": duration, "submitted": submitted, "received": received,
            "measuredOutputs": measured, "outputFPS": Double(measured) / duration, "encodedBytes": bytes,
            "callbackP50Milliseconds": percentile(latencies, 0.5), "callbackP95Milliseconds": percentile(latencies, 0.95),
            "outputGapP95Milliseconds": percentile(gaps, 0.95), "encodeCallP95Milliseconds": percentile(calls, 0.95),
            "peakInflight": peak, "failures": failed, "drainStatus": drainStatus,
            "valid": failed == 0 && received == submitted && measured > 0 && peak <= 2 && drainStatus == noErr,
            "productionAcceptance": false]
        return String(decoding: (try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys)) ?? Data(), as: UTF8.self)
    }
}

private actor LumenTileOutputCollector {
    private let mastering = LumenVideoHDRDisplayMetadata.hdr10Default().encodedData
    private let contentLight = LumenVideoContentLightLevelInfo.hdr10Default().encodedData

    private func hdrSEIPrefix(headerLength: Int32) -> Data? {
        guard mastering.count == 24, contentLight.count == 4, [1, 2, 4].contains(headerLength) else { return nil }
        // CoreMedia defines these 24/4-byte values as the ISO HEVC SEI payloads.
        // Carry the exact configured bytes; do not infer new display luminance.
        var rbsp = Data([137, 24]); rbsp.append(mastering)
        rbsp.append(contentsOf: [144, 4]); rbsp.append(contentLight); rbsp.append(0x80)
        var nal = Data([39 << 1, 1])
        var zeroes = 0
        for byte in rbsp {
            if zeroes >= 2 && byte <= 3 { nal.append(3); zeroes = 0 }
            nal.append(byte)
            zeroes = byte == 0 ? zeroes + 1 : 0
        }
        guard nal.count < (UInt64(1) << (UInt64(headerLength) * 8)) else { return nil }
        // Independently unescape the generated payload before it enters the
        // sample. Header validation also rejects malformed length prefixes.
        var restored = Data(); zeroes = 0
        for byte in nal.dropFirst(2) {
            if zeroes == 2 && byte == 3 { zeroes = 0; continue }
            restored.append(byte); zeroes = byte == 0 ? zeroes + 1 : 0
        }
        guard restored == rbsp else { return nil }
        var result = Data()
        for shift in stride(from: (Int(headerLength) - 1) * 8, through: 0, by: -8) {
            result.append(UInt8(truncatingIfNeeded: nal.count >> shift))
        }
        result.append(nal)
        return result
    }

    func run(_ input: AsyncStream<LumenTileProbeSample>, benchmark: Bool,
             completed: @escaping @Sendable (LumenTileProbeSample, Bool) -> Void) async -> String {
        var rows: [[String: Any]] = []
        let (compressed, continuation) = AsyncStream<LumenReplayCompressedSample>.makeStream(bufferingPolicy: .bufferingOldest(4))
        let decoder = Task {
            await LumenReplayDecoderLoad().run(compressed,
                pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, requiresHDR4K: true,
                requiresStaticHDR: true, acknowledge: {})
        }
        var valid = true
        var count = 0
        var decoderIngressDrops = 0
        var hdrPrefixes = 0
        var staticMetadataValid = true
        for await output in input {
            count += 1
            guard let sample = output.sample, output.status == noErr, output.flags & 2 == 0,
                  let format = sample.formatDescription, let block = sample.dataBuffer else {
                valid = false
                completed(output, false)
                rows.append(["status": output.status, "flags": output.flags, "hasSample": output.sample != nil])
                continue
            }
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            var parameterSets: [String] = []
            var parameterPointers: [UnsafePointer<UInt8>] = []
            var parameterSizes: [Int] = []
            for index in 0 ... 2 {
                var pointer: UnsafePointer<UInt8>?
                var length = 0
                if CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &length,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                   let pointer, length > 0, length < 4096 {
                    parameterSets.append(Data(bytes: pointer, count: length).base64EncodedString())
                    parameterPointers.append(pointer)
                    parameterSizes.append(length)
                }
            }
            var headerLength: Int32 = 0
            let headerStatus = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format,
                parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: &headerLength)
            var nalTypes: [Int] = []
            var parsed = headerStatus == noErr && [1, 2, 4].contains(headerLength)
            var offset = 0
            let size = CMBlockBufferGetDataLength(block)
            var header = [UInt8](repeating: 0, count: 4)
            while parsed && offset < size {
                guard size - offset >= Int(headerLength),
                      CMBlockBufferCopyDataBytes(block, atOffset: offset, dataLength: Int(headerLength), destination: &header) == noErr else {
                    parsed = false; break
                }
                let length = header.prefix(Int(headerLength)).reduce(0) { ($0 << 8) | Int($1) }
                offset += Int(headerLength)
                guard length >= 2, length <= size - offset,
                      CMBlockBufferCopyDataBytes(block, atOffset: offset, dataLength: 2, destination: &header) == noErr else {
                    parsed = false; break
                }
                nalTypes.append(Int((header[0] >> 1) & 63))
                offset += length
            }
            let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction)
            let pq = (transfer as? String) == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
            // Ask CoreMedia to derive the container colour fields from the exact
            // encoder VPS/SPS/PPS. No colour extension or bitstream is invented.
            var rebuilt: CMFormatDescription?
            let rebuildStatus = parameterPointers.count == 3 ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: nil, parameterSetCount: parameterPointers.count,
                parameterSetPointers: parameterPointers, parameterSetSizes: parameterSizes,
                nalUnitHeaderLength: headerLength, extensions: [
                    kCMFormatDescriptionExtension_MasteringDisplayColorVolume: mastering,
                    kCMFormatDescriptionExtension_ContentLightLevelInfo: contentLight
                ] as CFDictionary, formatDescriptionOut: &rebuilt
            ) : kCMFormatDescriptionError_InvalidParameter
            let rebuiltPQ = rebuilt.map {
                (CMFormatDescriptionGetExtension($0, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String) ==
                    (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
            } ?? false
            var normalized: CMSampleBuffer?
            var normalizeStatus: OSStatus = -1
            var transportBlock = block
            var prefixBytes = 0
            let isIRAP = nalTypes.contains { (16 ... 23).contains($0) }
            if isIRAP {
                if let prefix = hdrSEIPrefix(headerLength: headerLength) {
                    var prefixed: CMBlockBuffer?
                    var status = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil,
                        blockLength: prefix.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                        offsetToData: 0, dataLength: prefix.count, flags: 0, blockBufferOut: &prefixed)
                    if status == noErr, let prefixed {
                        status = prefix.withUnsafeBytes { bytes in
                            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: prefixed,
                                offsetIntoDestination: 0, dataLength: prefix.count)
                        }
                        if status == noErr {
                            status = CMBlockBufferAppendBufferReference(prefixed, targetBBuf: block,
                                offsetToData: 0, dataLength: size, flags: 0)
                        }
                        if status == noErr { transportBlock = prefixed; prefixBytes = prefix.count; hdrPrefixes += 1 }
                    }
                    staticMetadataValid = staticMetadataValid && status == noErr
                } else { staticMetadataValid = false }
            }
            let formatMetadataValid = rebuilt.map {
                (CMFormatDescriptionGetExtension($0, extensionKey: kCMFormatDescriptionExtension_MasteringDisplayColorVolume) as? Data) == mastering &&
                (CMFormatDescriptionGetExtension($0, extensionKey: kCMFormatDescriptionExtension_ContentLightLevelInfo) as? Data) == contentLight
            } ?? false
            staticMetadataValid = staticMetadataValid && formatMetadataValid
            if let rebuilt, output.sourceIndex >= 0 && (benchmark || output.sourceIndex <= 2) {
                // These three synthetic inputs have explicit 120 Hz source
                // times. Restore the submitted index, never callback order.
                var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 120),
                    presentationTimeStamp: CMTime(value: Int64(output.sourceIndex), timescale: 120), decodeTimeStamp: .invalid)
                var sampleSize = CMBlockBufferGetDataLength(transportBlock)
                normalizeStatus = CMSampleBufferCreateReady(allocator: nil, dataBuffer: transportBlock,
                    formatDescription: rebuilt, sampleCount: 1, sampleTimingEntryCount: 1,
                    sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                    sampleSizeArray: &sampleSize, sampleBufferOut: &normalized)
            }
            let vcl = nalTypes.filter { $0 <= 31 }
            valid = valid && parsed && offset == size && !vcl.isEmpty && rebuiltPQ && normalizeStatus == noErr &&
                dimensions.width == 3840 && dimensions.height == 2160 &&
                output.x == 0 && output.y == 0 && output.width == 3840 && output.height == 2160
            if rows.count < 3 { rows.append(["status": output.status, "flags": output.flags, "bytes": size,
                "origin": [output.x, output.y], "tileSize": [output.width, output.height],
                "formatSize": [dimensions.width, dimensions.height], "nalTypes": nalTypes,
                "parameterSets": parameterSets,
                "sourceIndex": output.sourceIndex, "rebuildStatus": rebuildStatus,
                "rebuiltPQ": rebuiltPQ, "normalizeStatus": normalizeStatus,
                "hdrPrefixBytes": prefixBytes, "staticHDRInFormat": formatMetadataValid,
                "formatExtensionKeys": (CMFormatDescriptionGetExtensions(format) as? [String: Any])?.keys.sorted() ?? [],
                "nalValid": parsed, "pq": pq, "ptsValid": sample.presentationTimeStamp.isValid,
                "durationValid": sample.duration.isValid]) }
            if let normalized {
                let sample = LumenReplayCompressedSample(value: normalized, acknowledgeAfterDecode: false,
                    decoded: { valid in completed(output, valid) })
                if case .dropped = continuation.yield(sample) {
                    decoderIngressDrops += 1; valid = false; completed(output, false)
                }
            } else { completed(output, false) }
        }
        continuation.finish()
        let decoded = await decoder.value
        valid = valid && (benchmark ? count > 3 : count == 3) && decoded["hardware"] == 1 && decoded["decoded"] == count &&
            decoded["submitted"] == count && decoded["failures"] == 0 && decoded["invalidOutputs"] == 0
        let metadataEquivalent = staticMetadataValid && hdrPrefixes > 0 && valid
        let result: [String: Any] = ["mode": "hevc-tile-output-smoke", "valid": valid && metadataEquivalent,
            "hdrMetadataEquivalent": metadataEquivalent, "hdrPrefixCount": hdrPrefixes,
            "sampleCount": count, "decoderIngressDrops": decoderIngressDrops, "outputs": rows, "decoder": decoded]
        return String(decoding: (try? JSONSerialization.data(withJSONObject: result, options: .sortedKeys)) ?? Data(), as: UTF8.self)
    }
}

private final class LumenReplayDecodeAcknowledgement: Sendable {
    let acknowledge: @Sendable (Bool) -> Void
    init(_ acknowledge: @escaping @Sendable (Bool) -> Void) { self.acknowledge = acknowledge }
}

private final class LumenReplayDecodeCallback: Sendable {
    let output: AsyncStream<Bool>.Continuation
    let pixelFormat: OSType
    let requiresHDR4K: Bool
    let requiresStaticHDR: Bool
    let mastering = LumenVideoHDRDisplayMetadata.hdr10Default().encodedData
    let contentLight = LumenVideoContentLightLevelInfo.hdr10Default().encodedData
    init(output: AsyncStream<Bool>.Continuation, pixelFormat: OSType, requiresHDR4K: Bool, requiresStaticHDR: Bool) {
        self.output = output
        self.pixelFormat = pixelFormat
        self.requiresHDR4K = requiresHDR4K
        self.requiresStaticHDR = requiresStaticHDR
    }
}

/// Diagnostic only: feed each encoded frame to a hardware decoder without
/// retaining its output, network traffic, rendering, or a second capture path.
/// The actor serializes the VT API; its callback only yields a validation bit.
private actor LumenReplayDecoderLoad {
    func run(_ input: AsyncStream<LumenReplayCompressedSample>,
             pixelFormat: OSType,
             requiresHDR4K: Bool = false,
             requiresStaticHDR: Bool = false,
             acknowledge: @escaping @Sendable () -> Void) async -> [String: Int] {
        let (outputs, continuation) = AsyncStream<Bool>.makeStream()
        let callback = LumenReplayDecodeCallback(output: continuation, pixelFormat: pixelFormat,
            requiresHDR4K: requiresHDR4K, requiresStaticHDR: requiresStaticHDR)
        let collector = Task {
            var decoded = 0
            var invalid = 0
            for await valid in outputs {
                if valid { decoded += 1 } else { invalid += 1 }
            }
            return ["decoded": decoded, "invalidOutputs": invalid]
        }
        var session: VTDecompressionSession?
        var submitted = 0
        var failures = 0
        var hardware = false
        for await sample in input {
            if session == nil {
                guard let format = sample.value.formatDescription else {
                    failures += 1
                    sample.decoded?(false)
                    continue
                }
                var record = VTDecompressionOutputCallbackRecord(
                    decompressionOutputCallback: { refcon, frameRefcon, status, _, image, _, _ in
                        let acknowledgement = frameRefcon.map {
                            Unmanaged<LumenReplayDecodeAcknowledgement>
                                .fromOpaque($0).takeRetainedValue()
                        }
                        guard let refcon else { return }
                        let context = Unmanaged<LumenReplayDecodeCallback>
                            .fromOpaque(refcon).takeUnretainedValue()
                        let valid = status == noErr && image.map {
                            CVPixelBufferGetPixelFormatType($0) == context.pixelFormat &&
                            (!context.requiresHDR4K || (
                                CVPixelBufferGetWidth($0) == 3840 && CVPixelBufferGetHeight($0) == 2160 &&
                                (CVBufferCopyAttachment($0, kCVImageBufferTransferFunctionKey, nil) as? String) ==
                                    (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String) &&
                                (CVBufferCopyAttachment($0, kCVImageBufferColorPrimariesKey, nil) as? String) ==
                                    (kCVImageBufferColorPrimaries_ITU_R_2020 as String)
                            )) && (!context.requiresStaticHDR || (
                                (CVBufferCopyAttachment($0, kCVImageBufferMasteringDisplayColorVolumeKey, nil) as? Data) == context.mastering &&
                                (CVBufferCopyAttachment($0, kCVImageBufferContentLightLevelInfoKey, nil) as? Data) == context.contentLight
                            ))
                        } == true
                        context.output.yield(valid)
                        acknowledgement?.acknowledge(valid)
                    },
                    decompressionOutputRefCon: Unmanaged.passUnretained(callback).toOpaque()
                )
                let status = VTDecompressionSessionCreate(
                    allocator: kCFAllocatorDefault, formatDescription: format,
                    decoderSpecification: [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary,
                    imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: pixelFormat,
                                            kCVPixelBufferMetalCompatibilityKey: true,
                                            kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                    outputCallback: &record, decompressionSessionOut: &session
                )
                guard status == noErr, let session else { failures += 1; sample.decoded?(false); continue }
                var value: CFTypeRef?
                hardware = VTSessionCopyProperty(session,
                    key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                    allocator: nil, valueOut: &value) == noErr && value as? Bool == true
                if VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime,
                                        value: kCFBooleanTrue) != noErr { failures += 1 }
            }
            guard let session else { failures += 1; sample.decoded?(false); continue }
            let acknowledgement = sample.acknowledgeAfterDecode || sample.decoded != nil
                ? Unmanaged.passRetained(LumenReplayDecodeAcknowledgement { valid in
                    if valid && sample.acknowledgeAfterDecode { acknowledge() }
                    sample.decoded?(valid)
                }).toOpaque()
                : nil
            let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample.value,
                flags: [._EnableAsynchronousDecompression, ._1xRealTimePlayback],
                frameRefcon: acknowledgement, infoFlagsOut: nil)
            if status == noErr { submitted += 1 } else {
                failures += 1
                if let acknowledgement {
                    Unmanaged<LumenReplayDecodeAcknowledgement>.fromOpaque(acknowledgement).release()
                }
                sample.decoded?(false)
            }
        }
        if let session {
            if VTDecompressionSessionWaitForAsynchronousFrames(session) != noErr { failures += 1 }
            VTDecompressionSessionInvalidate(session)
        }
        continuation.finish()
        var result = await collector.value
        result["submitted"] = submitted
        result["failures"] = failures
        result["hardware"] = hardware ? 1 : 0
        _fixLifetime(callback)
        return result
    }
}

private actor LumenEncoderReplayRunner {
    private var runtime: LumenScreenCaptureVideoRuntime?

    private func acknowledge() async {
        _ = await runtime?.resumeVideoEncodingAfterCodecAck()
    }

    func run(fixture: LumenEncoderReplayFixture, width: Int, height: Int,
             hdr: Bool, bitrate: Int, duration: Double, periodicSeconds: Int,
             overlapEnabled: Bool = true, decoderLoad: Bool = false,
             sourceFrameRate: Int = 120, arrivalPattern: [Int64]? = nil,
             arrivalPeriod: Int64 = 0, arrivalKind: String = "constant",
             metalStaging: Bool? = nil, forwarderRetention: Bool = false,
             initialBitrateForUpdate: Int? = nil,
             presentationPattern: [Int64]? = nil,
             liveDisplayID: UInt32? = nil) async -> String {
        let metrics = LumenEncoderReplayMetrics()
        let forwarder = forwarderRetention ? LumenVideoCaptureForwarder() : nil
        let (decodeInput, decodeContinuation) = AsyncStream<LumenReplayCompressedSample>
            .makeStream(bufferingPolicy: .bufferingOldest(4))
        let decodeTask = decoderLoad ? Task {
            await LumenReplayDecoderLoad().run(decodeInput,
                pixelFormat: hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                acknowledge: { Task { await self.acknowledge() } })
        } : nil
        do {
            let configuration = LumenMacCaptureConfiguration(
                displayID: liveDisplayID ?? 0, codec: .hevc,
                videoProfile: hdr ? .hevcMain10 : .hevcMain,
                chromaSubsampling: .yuv420, bitDepth: hdr ? 10 : 8,
                dynamicRange: hdr ? .hdr10 : .sdr,
                targetFrameRate: 120, targetVideoBitRateKbps: initialBitrateForUpdate ?? bitrate,
                requestedWidth: width, requestedHeight: height,
                sinkRequest: .init(
                    capability: .init(gamut: hdr ? .rec2020 : .srgb,
                                      transfer: hdr ? .pq : .sdr,
                                      supportsFrameGatedHDR: true,
                                      supportsPerFrameHDRMetadata: true),
                    dynamicRangeTransport: hdr ? LumenMacDynamicRangeTransportFrameGatedHDR : LumenMacDynamicRangeTransportSDR
                ),
                effectiveDisplayState: .init(gamut: hdr ? .rec2020 : .srgb,
                                             transfer: hdr ? .pq : .sdr)
            )
            let runtime = try LumenScreenCaptureVideoRuntime(
                configuration: configuration,
                callbacks: .init(frameHandler: { [self] frame in
                    metrics.record(frame, requiresHDR: hdr)
                    if let forwarder {
                        _ = forwarder.consume(frame: frame)
                        _ = forwarder.popNextFrame()
                    }
                    if decoderLoad, case .dropped = decodeContinuation.yield(
                        LumenReplayCompressedSample(value: frame.sampleBuffer,
                            acknowledgeAfterDecode: frame.requiresBootstrapAcknowledgement)
                    ) { metrics.decodeInputDrops += 1 }
                    if frame.requiresBootstrapAcknowledgement && !decoderLoad {
                        Task { await acknowledge() }
                    }
                }, eventHandler: nil),
                statisticsHandler: { _ in }, terminationHandler: { _ in }
            )
            self.runtime = runtime
            if liveDisplayID != nil {
                try await runtime.start()
            } else {
                _ = try await runtime.prepareVideoCapture(sourceWidth: width, sourceHeight: height)
            }
            if metalStaging == true, liveDisplayID == nil {
                try runtime.prepareSkyLightMetalStaging(
                    width: width, height: height,
                    pixelFormat: hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                        : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                )
                // Diagnostic identity only: no additional capture stream is started.
                // Exercise the existing product lease/blit/completion/admission path.
                try runtime.queue.sync {
                    runtime.skyLightDisplayStreamIdentity = 1
                    runtime.outputOwnership.registerScreenOutput(streamIdentity: 1)
                    try runtime.outputOwnership.markCaptureStarted(streamIdentity: 1)
                }
            }
            let readEncoderProperties = { runtime.encoderQueue.sync { () -> [String: Any] in
                guard let session = runtime.compressionSession else { return [:] }
                var values: [String: Any] = [:]
                for key in ["ThroughputMode", "SupportedThroughputModes", "ConcurrentMode",
                            "PreemptiveLoadBalancing", "MaximizePowerEfficiency", "InputQueueMaxCount",
                            "EncoderUsage", "LookAheadFrames", "SVENum", "SVESchedMode",
                            "MaxFrameDelayCount", "RealTime", "MaximumRealTimeFrameRate",
                            "AverageBitRate", "DataRateLimits"] {
                    var value: CFTypeRef?
                    let status = VTSessionCopyProperty(session, key: key as CFString,
                                                       allocator: nil, valueOut: &value)
                    values[key] = ["status": status, "value": value ?? NSNull()]
                }
                return values
            } }
            let encoderProperties = readEncoderProperties()
            runtime.queue.sync {
                runtime.encoderOverlapEnabled = overlapEnabled
                runtime.statistics.isRunning = true
            }
            for buffer in fixture.buffers {
                guard CVPixelBufferGetWidth(buffer) == width,
                      CVPixelBufferGetHeight(buffer) == height,
                      CVPixelBufferGetPixelFormatType(buffer) == (hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) else {
                    throw LumenExactCaptureError.invalidFormat("Replay fixture dimensions or pixel format mismatch")
                }
            }
            let clock = ContinuousClock()
            let start = clock.now
            let startUptimeNanos = DispatchTime.now().uptimeNanoseconds
            var didApplyRateUpdate = false
            var rateUpdateSucceeded = initialBitrateForUpdate == nil
            var rateUpdateCompletedNanos: UInt64 = 0
            var propertiesAfterRateUpdate: [String: Any] = [:]
            var offered = 0
            var skippedProducerDeadlines = 0
            // Supply cadence is diagnostic input, not negotiated frame rate:
            // the product configuration above stays at 120 Hz in every run.
            var schedule: [Int64] = []
            if liveDisplayID != nil {
                // Only the periodic-control timer runs here. Source callbacks
                // and their original timestamps come from the real runtime.
                schedule = (1 ... Int(ceil(duration))).map {
                    Int64(min(Double($0), duration) * 1e9)
                }
            } else if let arrivalPattern {
                var cycle: Int64 = 0
                let limit = Int64(duration * 1e9)
                if presentationPattern != nil {
                    schedule = arrivalPattern.filter { $0 < limit }
                } else { while cycle < limit {
                    schedule.append(contentsOf: arrivalPattern.map { cycle + $0 }.filter { $0 < limit })
                    cycle += arrivalPeriod
                } }
            } else {
                schedule = (0 ..< Int(duration * Double(sourceFrameRate))).map {
                    Int64($0) * 1_000_000_000 / Int64(sourceFrameRate)
                }
            }
            let total = schedule.count
            var nextKeyFrameNanos = Int64(periodicSeconds) * 1_000_000_000
            while offered < total {
                let deadline = start.advanced(by: .nanoseconds(schedule[offered]))
                try await clock.sleep(until: deadline)
                // Do not burst old attempts after a producer scheduling stall.
                let elapsed = start.duration(to: clock.now)
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                var due = offered
                while due + 1 < total && schedule[due + 1] <= Int64(seconds * 1e9) { due += 1 }
                if due > offered + 1 {
                    skippedProducerDeadlines += due - offered
                    offered = due
                }
                let index = offered
                let presentationNanos = presentationPattern?[index] ?? schedule[index]
                if initialBitrateForUpdate != nil, !didApplyRateUpdate,
                   presentationNanos >= 1_000_000_000 {
                    // Apply the exact live policy after real frames have entered
                    // VT. Both controls issue the same call; unchanged bitrate
                    // is deduplicated by the production policy. Compare only
                    // outputs after a further one-second settling interval.
                    rateUpdateSucceeded = await runtime.setVideoDeliveryPolicy(
                        bitrateKbps: bitrate, admissionDivisor: 1
                    )
                    rateUpdateCompletedNanos = DispatchTime.now().uptimeNanoseconds
                    propertiesAfterRateUpdate = readEncoderProperties()
                    didApplyRateUpdate = true
                }
                let displayTime = mach_absolute_time()
                if liveDisplayID == nil { await withCheckedContinuation { continuation in
                    runtime.queue.async {
                        if metalStaging == true {
                            runtime.processSkyLightFrame(
                                status: .frameComplete, displayTime: displayTime,
                                pixelBuffer: fixture.buffers[index % fixture.buffers.count],
                                pixelBufferStatus: kCVReturnSuccess
                            )
                            continuation.resume()
                            return
                        }
                        let source = runtime.makePendingSource(
                            imageBuffer: fixture.buffers[index % fixture.buffers.count],
                            presentationTime: metalStaging == nil
                                ? CMTime(value: presentationNanos, timescale: 1_000_000_000)
                                : runtime.resolvedSkyLightPresentationTime(displayTime: displayTime),
                            sourceDisplayTime: displayTime
                        )
                        runtime.admitPendingSource(source)
                        continuation.resume()
                    }
                } }
                offered += 1
                if offered < total && schedule[offered] >= nextKeyFrameNanos {
                    _ = await runtime.requestPeriodicKeyFrame()
                    nextKeyFrameNanos = (schedule[offered] / (Int64(periodicSeconds) * 1_000_000_000) + 1)
                        * Int64(periodicSeconds) * 1_000_000_000
                }
            }
            await runtime.stop()
            let elapsed = start.duration(to: clock.now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            decodeContinuation.finish()
            let decodeResult = await decodeTask?.value ?? [:]
            let result: [String: Any] = runtime.queue.sync {
                func percentile(_ values: [Double], _ p: Double) -> Double {
                    guard !values.isEmpty else { return 0 }
                    let sorted = values.sorted()
                    return sorted[min(Int(ceil(Double(sorted.count - 1) * p)), sorted.count - 1)]
                }
                let settledStart = max(startUptimeNanos + 2_000_000_000,
                    rateUpdateCompletedNanos + 1_000_000_000)
                let settledIndices = metrics.outputUptimeNanos.indices.filter {
                    metrics.outputUptimeNanos[$0] >= settledStart
                }
                let settledSeconds = max(0, seconds - Double(settledStart - startUptimeNanos) / 1e9)
                return [
                    "mode": liveDisplayID == nil ? "production-encoder-immutable-replay" : "production-live-source",
                    "periodicSeconds": periodicSeconds,
                    "actualSourceFrames": runtime.statistics.sourceFrameCount,
                    "sourceFrameRate": liveDisplayID != nil ? Double(runtime.statistics.sourceFrameCount) / seconds
                        : arrivalPattern == nil ? Double(sourceFrameRate)
                        : Double(arrivalPattern!.count) * 1e9 / Double(arrivalPeriod),
                    "negotiatedFrameRate": 120, "arrivalKind": arrivalKind,
                    "presentationKind": presentationPattern == nil || presentationPattern == arrivalPattern
                        ? "arrival" : "captured-display-pts",
                    "forwarderRetention": forwarderRetention,
                    "initialBitrateKbps": initialBitrateForUpdate ?? bitrate,
                    "measuredBitrateKbps": bitrate,
                    "rateUpdateValid": rateUpdateSucceeded && (initialBitrateForUpdate == nil || didApplyRateUpdate),
                    "settledOutputFrames": settledIndices.count,
                    "settledSeconds": settledSeconds,
                    "settledOutputFPS": settledSeconds > 0 ? Double(settledIndices.count) / settledSeconds : 0,
                    "settledCallbackP95Milliseconds": percentile(settledIndices.map { metrics.latencies[$0] }, 0.95),
                    "encoderPropertiesAfterRateUpdate": propertiesAfterRateUpdate,
                    "forwarderFrames": forwarder?.snapshot().frameCount ?? 0,
                    "forwarderHasLastSample": forwarder?.snapshot().hasLastSampleBuffer ?? false,
                    "forwarderValid": forwarder == nil || (
                        forwarder!.snapshot().frameCount == metrics.latencies.count &&
                        forwarder!.snapshot().droppedFrameCount == 0 &&
                        forwarder!.snapshot().queuedFrameCount == 0 &&
                        forwarder!.snapshot().hasLastSampleBuffer
                    ),
                    "metalStaging": metalStaging == true || liveDisplayID != nil,
                    "metalSubmitted": runtime.skyLightMetalStageSubmissionCount,
                    "metalCompleted": runtime.skyLightMetalStageCompletionCount,
                    "metalBusyDrops": runtime.skyLightMetalStageBusyDropCount,
                    "metalPoolFailures": runtime.skyLightMetalStagePoolAllocationFailureCount,
                    "metalTextureFailures": runtime.skyLightMetalStageTextureFailureCount,
                    "metalCommandFailures": runtime.skyLightMetalStageCommandBufferFailureCount,
                    "metalValidationFailures": runtime.skyLightMetalStageValidationFailureCount,
                    "metalValid": (metalStaging != true && liveDisplayID == nil) || (
                        runtime.skyLightMetalStageSubmissionCount > 0 &&
                        runtime.skyLightMetalStageSubmissionCount == runtime.skyLightMetalStageCompletionCount &&
                        runtime.skyLightMetalStageBusyDropCount == 0 &&
                        runtime.skyLightMetalStagePoolAllocationFailureCount == 0 &&
                        runtime.skyLightMetalStageTextureFailureCount == 0 &&
                        runtime.skyLightMetalStageCommandBufferFailureCount == 0 &&
                        runtime.skyLightMetalStageValidationFailureCount == 0
                    ),
                    "overlapEnabled": overlapEnabled,
                    "decoderLoad": decoderLoad, "decoder": decodeResult,
                    "decodeInputDrops": metrics.decodeInputDrops,
                    "decoderValid": !decoderLoad || (
                        metrics.decodeInputDrops == 0 && decodeResult["hardware"] == 1 &&
                        decodeResult["failures"] == 0 && decodeResult["invalidOutputs"] == 0 &&
                        decodeResult["submitted"] == metrics.latencies.count &&
                        decodeResult["decoded"] == metrics.latencies.count
                    ),
                    "outputFPS": Double(metrics.latencies.count) / seconds,
                    "outputFrames": metrics.latencies.count,
                    "offeredFrames": liveDisplayID != nil ? Int(runtime.statistics.sourceFrameCount) : offered - skippedProducerDeadlines,
                    "producerSkippedDeadlines": skippedProducerDeadlines, "measurementSeconds": seconds,
                    "callbackP50Milliseconds": percentile(metrics.latencies, 0.5),
                    "callbackP95Milliseconds": percentile(metrics.latencies, 0.95),
                    "frameAgeP50Milliseconds": percentile(metrics.frameAges, 0.5),
                    "frameAgeP95Milliseconds": percentile(metrics.frameAges, 0.95),
                    "pendingDrops": runtime.encoderPendingDropCount,
                    "processingFailures": runtime.statistics.processingFailureCount,
                    "hdrValid": metrics.hdrValid && !metrics.latencies.isEmpty,
                    "keyFrames": metrics.keyFrames, "encodedBytes": metrics.bytes,
                    "encoderProperties": encoderProperties,
                    "diagnostics": runtime.makeStatisticsNotes(width: width, height: height)
                ]
            }
            self.runtime = nil
            return String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self)
        } catch {
            await runtime?.stop()
            decodeContinuation.finish()
            _ = await decodeTask?.value
            runtime = nil
            let result = ["error": error.localizedDescription]
            return String(decoding: (try? JSONSerialization.data(withJSONObject: result)) ?? Data(), as: UTF8.self)
        }
    }
}

public struct LumenVideoToolboxProbeEnvironment: Hashable, Codable, Sendable {
    public let osBuild: String
    public let hardwareIdentity: String

    public init(osBuild: String, hardwareIdentity: String) {
        self.osBuild = osBuild
        self.hardwareIdentity = hardwareIdentity
    }

    public static var current: Self {
        Self(
            osBuild: sysctlString("kern.osversion") ?? "unknown-os-build",
            hardwareIdentity: [
                sysctlString("hw.model"),
                sysctlString("hw.targettype")
            ]
            .compactMap { $0 }
            .joined(separator: "|")
            .nonEmpty ?? "unknown-hardware"
        )
    }
}

public enum LumenVideoToolboxProbeTarget: String, CaseIterable, Codable, Hashable, Sendable {
    case h264High444Predictive
    case hevcMain444
    case hevcMain44410

    fileprivate var codec: String {
        switch self {
        case .h264High444Predictive: "h264"
        case .hevcMain444, .hevcMain44410: "hevc"
        }
    }

    fileprivate var codecType: CMVideoCodecType {
        switch self {
        case .h264High444Predictive: kCMVideoCodecType_H264
        case .hevcMain444, .hevcMain44410: kCMVideoCodecType_HEVC
        }
    }

    fileprivate var profileFragment: String {
        switch self {
        case .h264High444Predictive: "High444Predictive"
        case .hevcMain444: "Main444_"
        case .hevcMain44410: "Main44410"
        }
    }

    fileprivate var pixelFormat: OSType {
        switch self {
        case .h264High444Predictive, .hevcMain444:
            kCVPixelFormatType_444YpCbCr8BiPlanarFullRange
        case .hevcMain44410:
            kCVPixelFormatType_444YpCbCr10BiPlanarFullRange
        }
    }

    fileprivate var inputFourCC: String {
        fourCCString(pixelFormat)
    }
}

public struct LumenVideoToolboxProbeStatuses: Equatable, Sendable {
    public let discoveryStatus: Int32?
    public let createStatus: Int32?
    public let setStatus: Int32?
    public let prepareStatus: Int32?
    public let encodeStatus: Int32?
    public let callbackStatus: Int32?

    public init(
        discoveryStatus: Int32?,
        createStatus: Int32?,
        setStatus: Int32?,
        prepareStatus: Int32?,
        encodeStatus: Int32?,
        callbackStatus: Int32?
    ) {
        self.discoveryStatus = discoveryStatus
        self.createStatus = createStatus
        self.setStatus = setStatus
        self.prepareStatus = prepareStatus
        self.encodeStatus = encodeStatus
        self.callbackStatus = callbackStatus
    }

    public static let allSuccessful = Self(
        discoveryStatus: noErr,
        createStatus: noErr,
        setStatus: noErr,
        prepareStatus: noErr,
        encodeStatus: noErr,
        callbackStatus: noErr
    )
}

public enum LumenVideoToolboxParsedConfiguration: Equatable, Sendable {
    case h264(profileIdc: Int)
    case hevc(chromaFormatIdc: Int, lumaBitDepth: Int, chromaBitDepth: Int)

    fileprivate var profileIdc: Int? {
        guard case let .h264(profileIdc) = self else { return nil }
        return profileIdc
    }

    fileprivate var chromaFormatIdc: Int? {
        guard case let .hevc(chromaFormatIdc, _, _) = self else { return nil }
        return chromaFormatIdc
    }

    fileprivate var lumaBitDepth: Int? {
        guard case let .hevc(_, lumaBitDepth, _) = self else { return nil }
        return lumaBitDepth
    }

    fileprivate var chromaBitDepth: Int? {
        guard case let .hevc(_, _, chromaBitDepth) = self else { return nil }
        return chromaBitDepth
    }
}

public struct LumenVideoToolboxProbeAssessment: Equatable, Sendable {
    public let advertised: Bool
    public let rejectionReason: String?

    public init(advertised: Bool, rejectionReason: String?) {
        self.advertised = advertised
        self.rejectionReason = rejectionReason
    }
}

public struct LumenVideoToolboxCapabilityProbeRow: Encodable, Equatable, Sendable {
    public let codec: String
    public let requestedProfileFamily: String
    public let profile: String?
    public let inputFourCC: String
    public let discoveryStatus: Int32?
    public let createStatus: Int32?
    public let setStatus: Int32?
    public let prepareStatus: Int32?
    public let encodeStatus: Int32?
    public let callbackStatus: Int32?
    public let hardwareUsed: Bool?
    public let profileIdc: Int?
    public let chromaFormatIdc: Int?
    public let lumaBitDepth: Int?
    public let chromaBitDepth: Int?
    public let osBuild: String
    public let hardwareIdentity: String
    public let advertised: Bool
    public let rejectionReason: String?

    fileprivate init(
        target: LumenVideoToolboxProbeTarget,
        profile: String?,
        statuses: LumenVideoToolboxProbeStatuses,
        hardwareUsed: Bool?,
        parsedConfiguration: LumenVideoToolboxParsedConfiguration?,
        environment: LumenVideoToolboxProbeEnvironment,
        assessment: LumenVideoToolboxProbeAssessment
    ) {
        codec = target.codec
        requestedProfileFamily = target.rawValue
        self.profile = profile
        inputFourCC = target.inputFourCC
        discoveryStatus = statuses.discoveryStatus
        createStatus = statuses.createStatus
        setStatus = statuses.setStatus
        prepareStatus = statuses.prepareStatus
        encodeStatus = statuses.encodeStatus
        callbackStatus = statuses.callbackStatus
        self.hardwareUsed = hardwareUsed
        profileIdc = parsedConfiguration?.profileIdc
        chromaFormatIdc = parsedConfiguration?.chromaFormatIdc
        lumaBitDepth = parsedConfiguration?.lumaBitDepth
        chromaBitDepth = parsedConfiguration?.chromaBitDepth
        osBuild = environment.osBuild
        hardwareIdentity = environment.hardwareIdentity
        advertised = assessment.advertised
        rejectionReason = assessment.rejectionReason
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(codec, forKey: .codec)
        try container.encode(requestedProfileFamily, forKey: .requestedProfileFamily)
        try container.encodeIfPresent(profile, forKey: .profile)
        if profile == nil { try container.encodeNil(forKey: .profile) }
        try container.encode(inputFourCC, forKey: .inputFourCC)
        try container.encodeOptional(discoveryStatus, forKey: .discoveryStatus)
        try container.encodeOptional(createStatus, forKey: .createStatus)
        try container.encodeOptional(setStatus, forKey: .setStatus)
        try container.encodeOptional(prepareStatus, forKey: .prepareStatus)
        try container.encodeOptional(encodeStatus, forKey: .encodeStatus)
        try container.encodeOptional(callbackStatus, forKey: .callbackStatus)
        try container.encodeOptional(hardwareUsed, forKey: .hardwareUsed)
        try container.encodeOptional(profileIdc, forKey: .profileIdc)
        try container.encodeOptional(chromaFormatIdc, forKey: .chromaFormatIdc)
        try container.encodeOptional(lumaBitDepth, forKey: .lumaBitDepth)
        try container.encodeOptional(chromaBitDepth, forKey: .chromaBitDepth)
        try container.encode(osBuild, forKey: .osBuild)
        try container.encode(hardwareIdentity, forKey: .hardwareIdentity)
        try container.encode(advertised, forKey: .advertised)
        try container.encodeIfPresent(rejectionReason, forKey: .rejectionReason)
        if rejectionReason == nil { try container.encodeNil(forKey: .rejectionReason) }
    }

    private enum CodingKeys: String, CodingKey {
        case codec
        case requestedProfileFamily
        case profile
        case inputFourCC
        case discoveryStatus
        case createStatus
        case setStatus
        case prepareStatus
        case encodeStatus
        case callbackStatus
        case hardwareUsed
        case profileIdc
        case chromaFormatIdc
        case lumaBitDepth
        case chromaBitDepth
        case osBuild
        case hardwareIdentity
        case advertised
        case rejectionReason
    }
}

public enum LumenVideoToolboxCodecConfigurationParser {
    public struct AVCConfiguration: Equatable, Sendable {
        public let profileIdc: Int
    }

    public struct HEVCConfiguration: Equatable, Sendable {
        public let chromaFormatIdc: Int
        public let lumaBitDepth: Int
        public let chromaBitDepth: Int
    }

    public static func parseAVCC(_ data: Data) -> AVCConfiguration? {
        guard data.count >= 4, data[0] == 1 else { return nil }
        return AVCConfiguration(profileIdc: Int(data[1]))
    }

    public static func parseHVCC(_ data: Data) -> HEVCConfiguration? {
        guard data.count >= 23,
              data[0] == 1,
              data[16] & 0xFC == 0xFC,
              data[17] & 0xF8 == 0xF8,
              data[18] & 0xF8 == 0xF8 else {
            return nil
        }
        return HEVCConfiguration(
            chromaFormatIdc: Int(data[16] & 0x03),
            lumaBitDepth: Int(data[17] & 0x07) + 8,
            chromaBitDepth: Int(data[18] & 0x07) + 8
        )
    }
}

public actor LumenVideoToolboxCapabilityProbeCache {
    private var cachedRows: [LumenVideoToolboxProbeEnvironment: [LumenVideoToolboxCapabilityProbeRow]] = [:]

    public init() {}

    public func rows(
        for environment: LumenVideoToolboxProbeEnvironment,
        loader: @Sendable () async throws -> [LumenVideoToolboxCapabilityProbeRow]
    ) async rethrows -> [LumenVideoToolboxCapabilityProbeRow] {
        if let cached = cachedRows[environment] {
            return cached
        }
        let loaded = try await loader()
        if loaded.allSatisfy(\.isStableCacheResult) {
            cachedRows[environment] = loaded
        }
        return loaded
    }
}

private extension LumenVideoToolboxCapabilityProbeRow {
    var isStableCacheResult: Bool {
        advertised || rejectionReason == "required-profile-not-supported"
    }
}

public enum LumenVideoToolboxCapabilityProbe {
    public static let cache = LumenVideoToolboxCapabilityProbeCache()

    public static func discoveredProfile(
        containing fragment: String,
        supportedProfiles: [String]
    ) -> String? {
        supportedProfiles
            .filter { $0.contains(fragment) }
            .sorted()
            .first
    }

    public static func assess(
        target: LumenVideoToolboxProbeTarget,
        statuses: LumenVideoToolboxProbeStatuses,
        hardwareUsed: Bool?,
        parsedConfiguration: LumenVideoToolboxParsedConfiguration?
    ) -> LumenVideoToolboxProbeAssessment {
        let statusChecks: [(Int32?, String)] = [
            (statuses.discoveryStatus, "supported-property-discovery-failed"),
            (statuses.createStatus, "compression-session-create-failed"),
            (statuses.setStatus, "compression-session-property-set-failed"),
            (statuses.prepareStatus, "compression-session-prepare-failed"),
            (statuses.encodeStatus, "compression-session-encode-failed"),
            (statuses.callbackStatus, "compression-output-callback-failed")
        ]
        if let failure = statusChecks.first(where: { $0.0 != noErr }) {
            return .init(advertised: false, rejectionReason: failure.1)
        }
        guard hardwareUsed == true else {
            return .init(advertised: false, rejectionReason: "hardware-encoder-not-used")
        }
        guard let parsedConfiguration else {
            return .init(advertised: false, rejectionReason: "malformed-codec-configuration")
        }

        let matches: Bool
        switch (target, parsedConfiguration) {
        case let (.h264High444Predictive, .h264(profileIdc)):
            matches = profileIdc == 244
        case let (.hevcMain444, .hevc(chromaFormatIdc, lumaBitDepth, chromaBitDepth)):
            matches = chromaFormatIdc == 3 && lumaBitDepth == 8 && chromaBitDepth == 8
        case let (.hevcMain44410, .hevc(chromaFormatIdc, lumaBitDepth, chromaBitDepth)):
            matches = chromaFormatIdc == 3 && lumaBitDepth == 10 && chromaBitDepth == 10
        default:
            matches = false
        }
        return matches
            ? .init(advertised: true, rejectionReason: nil)
            : .init(advertised: false, rejectionReason: "codec-configuration-contract-mismatch")
    }

    public static func auditRequiredHardware444(
        environment: LumenVideoToolboxProbeEnvironment = .current,
        timeout: TimeInterval = 5
    ) async -> [LumenVideoToolboxCapabilityProbeRow] {
        var rows: [LumenVideoToolboxCapabilityProbeRow] = []
        for target in LumenVideoToolboxProbeTarget.allCases {
            let discovery = supportedProfiles(for: target.codecType)
            guard let profile = discoveredProfile(
                containing: target.profileFragment,
                supportedProfiles: discovery.profiles
            ) else {
                let statuses = LumenVideoToolboxProbeStatuses(
                    discoveryStatus: discovery.status,
                    createStatus: nil,
                    setStatus: nil,
                    prepareStatus: nil,
                    encodeStatus: nil,
                    callbackStatus: nil
                )
                rows.append(
                    .init(
                        target: target,
                        profile: nil,
                        statuses: statuses,
                        hardwareUsed: nil,
                        parsedConfiguration: nil,
                        environment: environment,
                        assessment: .init(
                            advertised: false,
                            rejectionReason: discovery.status == noErr
                                ? "required-profile-not-supported"
                                : "supported-property-discovery-failed"
                        )
                    )
                )
                continue
            }

            let attempt = LumenVideoToolboxProbeAttempt(
                target: target,
                profile: profile,
                discoveryStatus: discovery.status,
                environment: environment
            )
            rows.append(await attempt.run(timeout: timeout))
        }
        return rows
    }

    public static func cachedRequiredHardware444(
        environment: LumenVideoToolboxProbeEnvironment = .current,
        timeout: TimeInterval = 5
    ) async -> [LumenVideoToolboxCapabilityProbeRow] {
        await cache.rows(for: environment) {
            await auditRequiredHardware444(environment: environment, timeout: timeout)
        }
    }

    public static func advertisedRequiredHardware444(
        environment: LumenVideoToolboxProbeEnvironment = .current,
        timeout: TimeInterval = 5
    ) async -> [LumenVideoToolboxCapabilityProbeRow] {
        await cachedRequiredHardware444(environment: environment, timeout: timeout)
            .filter(\.advertised)
    }

    public static func writeArtifact(
        _ rows: [LumenVideoToolboxCapabilityProbeRow],
        to url: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(rows).write(to: url, options: .atomic)
    }

    private static func supportedProfiles(
        for codecType: CMVideoCodecType
    ) -> (status: OSStatus, profiles: [String]) {
        var encoderID: CFString?
        var supportedProperties: CFDictionary?
        let status = VTCopySupportedPropertyDictionaryForEncoder(
            width: 192,
            height: 108,
            codecType: codecType,
            encoderSpecification: [
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true
            ] as CFDictionary,
            encoderIDOut: &encoderID,
            supportedPropertiesOut: &supportedProperties
        )
        guard status == noErr,
              encoderID != nil,
              let properties = supportedProperties as? [CFString: Any],
              let profile = properties[kVTCompressionPropertyKey_ProfileLevel] as? [CFString: Any],
              let values = profile[kVTPropertySupportedValueListKey] as? [String] else {
            return (status, [])
        }
        return (status, values)
    }
}

private final class LumenVideoToolboxProbeCallbackBox: @unchecked Sendable {
    let callback: @Sendable (OSStatus, Data?) -> Void

    init(callback: @escaping @Sendable (OSStatus, Data?) -> Void) {
        self.callback = callback
    }
}

private let lumenVideoToolboxProbeOutputCallback: VTCompressionOutputCallback = {
    outputCallbackRefCon,
    _,
    status,
    _,
    sampleBuffer in
    guard let outputCallbackRefCon else { return }
    let callback = Unmanaged<LumenVideoToolboxProbeCallbackBox>
        .fromOpaque(outputCallbackRefCon)
        .takeUnretainedValue()
    let configurationData = sampleBuffer.flatMap(codecConfigurationData)
    callback.callback(status, configurationData)
}

private actor LumenVideoToolboxProbeCompletion {
    private var result: LumenVideoToolboxCapabilityProbeRow?
    private var waiter: CheckedContinuation<LumenVideoToolboxCapabilityProbeRow, Never>?

    func wait() async -> LumenVideoToolboxCapabilityProbeRow {
        if let result { return result }
        return await withCheckedContinuation { waiter = $0 }
    }

    func resolve(_ row: LumenVideoToolboxCapabilityProbeRow) {
        guard result == nil else { return }
        result = row
        waiter?.resume(returning: row)
        waiter = nil
    }
}

private final class LumenVideoToolboxProbeAttempt: @unchecked Sendable {
    private let target: LumenVideoToolboxProbeTarget
    private let profile: String
    private let discoveryStatus: OSStatus
    private let environment: LumenVideoToolboxProbeEnvironment
    private let queue: DispatchQueue
    private let completion = LumenVideoToolboxProbeCompletion()

    // All mutable attempt state below is isolated to `queue`. VideoToolbox's C
    // callback copies configuration data, then re-enters that queue.
    private var createStatus: OSStatus?
    private var setStatus: OSStatus?
    private var prepareStatus: OSStatus?
    private var encodeStatus: OSStatus?
    private var hardwareUsed: Bool?
    private var callbackBox: LumenVideoToolboxProbeCallbackBox?

    init(
        target: LumenVideoToolboxProbeTarget,
        profile: String,
        discoveryStatus: OSStatus,
        environment: LumenVideoToolboxProbeEnvironment
    ) {
        self.target = target
        self.profile = profile
        self.discoveryStatus = discoveryStatus
        self.environment = environment
        queue = DispatchQueue(label: "dev.skyline23.lumen.vt-capability.\(target.rawValue)")
    }

    func run(timeout: TimeInterval) async -> LumenVideoToolboxCapabilityProbeRow {
        queue.async { self.performEncode() }
        let timeoutTask = Task {
            let safeTimeout = timeout.isFinite ? max(timeout, 0.1) : 5
            let nanoseconds = UInt64(safeTimeout * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await completion.resolve(timeoutRow())
        }
        let row = await completion.wait()
        timeoutTask.cancel()
        return row
    }

    private func performEncode() {
        let imageAttributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: 192,
            kCVPixelBufferHeightKey: 108,
            kCVPixelBufferPixelFormatTypeKey: target.pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        callbackBox = LumenVideoToolboxProbeCallbackBox { [weak self] status, configurationData in
            guard let self else { return }
            queue.async {
                self.finish(callbackStatus: status, configurationData: configurationData)
            }
        }

        var session: VTCompressionSession?
        createStatus = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: 192,
            height: 108,
            codecType: target.codecType,
            encoderSpecification: [
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true
            ] as CFDictionary,
            imageBufferAttributes: imageAttributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: lumenVideoToolboxProbeOutputCallback,
            refcon: callbackBox.map { Unmanaged.passUnretained($0).toOpaque() },
            compressionSessionOut: &session
        )
        guard createStatus == noErr, let session else {
            finish(callbackStatus: nil, configurationData: nil)
            return
        }
        defer { VTCompressionSessionInvalidate(session) }

        setStatus = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_ProfileLevel,
            value: profile as CFString
        )
        guard setStatus == noErr else {
            finish(callbackStatus: nil, configurationData: nil)
            return
        }
        prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepareStatus == noErr else {
            finish(callbackStatus: nil, configurationData: nil)
            return
        }

        var hardwareValue: CFTypeRef?
        let hardwareStatus = withUnsafeMutablePointer(to: &hardwareValue) { pointer in
            VTSessionCopyProperty(
                session,
                key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                allocator: kCFAllocatorDefault,
                valueOut: UnsafeMutableRawPointer(pointer)
            )
        }
        if hardwareStatus == noErr {
            hardwareUsed = hardwareValue as? Bool
        }

        var pixelBuffer: CVPixelBuffer?
        let pixelStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            192,
            108,
            target.pixelFormat,
            imageAttributes as CFDictionary,
            &pixelBuffer
        )
        guard pixelStatus == kCVReturnSuccess, let pixelBuffer else {
            encodeStatus = pixelStatus
            finish(callbackStatus: nil, configurationData: nil)
            return
        }
        initialize(pixelBuffer, for: target.pixelFormat)

        var infoFlags: VTEncodeInfoFlags = []
        encodeStatus = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: .zero,
            duration: CMTime(value: 1, timescale: 60),
            frameProperties: [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary,
            sourceFrameRefcon: nil,
            infoFlagsOut: &infoFlags
        )
        guard encodeStatus == noErr else {
            finish(callbackStatus: nil, configurationData: nil)
            return
        }
        let completionStatus = VTCompressionSessionCompleteFrames(
            session,
            untilPresentationTimeStamp: .invalid
        )
        if completionStatus != noErr {
            encodeStatus = completionStatus
            finish(callbackStatus: nil, configurationData: nil)
        }
    }

    private func finish(callbackStatus: OSStatus?, configurationData: Data?) {
        let statuses = LumenVideoToolboxProbeStatuses(
            discoveryStatus: discoveryStatus,
            createStatus: createStatus,
            setStatus: setStatus,
            prepareStatus: prepareStatus,
            encodeStatus: encodeStatus,
            callbackStatus: callbackStatus
        )
        let parsedConfiguration: LumenVideoToolboxParsedConfiguration?
        switch target {
        case .h264High444Predictive:
            parsedConfiguration = configurationData
                .flatMap(LumenVideoToolboxCodecConfigurationParser.parseAVCC)
                .map { .h264(profileIdc: $0.profileIdc) }
        case .hevcMain444, .hevcMain44410:
            parsedConfiguration = configurationData
                .flatMap(LumenVideoToolboxCodecConfigurationParser.parseHVCC)
                .map {
                    .hevc(
                        chromaFormatIdc: $0.chromaFormatIdc,
                        lumaBitDepth: $0.lumaBitDepth,
                        chromaBitDepth: $0.chromaBitDepth
                    )
                }
        }
        let assessment = LumenVideoToolboxCapabilityProbe.assess(
            target: target,
            statuses: statuses,
            hardwareUsed: hardwareUsed,
            parsedConfiguration: parsedConfiguration
        )
        let row = LumenVideoToolboxCapabilityProbeRow(
            target: target,
            profile: profile,
            statuses: statuses,
            hardwareUsed: hardwareUsed,
            parsedConfiguration: parsedConfiguration,
            environment: environment,
            assessment: assessment
        )
        callbackBox = nil
        Task { await completion.resolve(row) }
    }

    private func timeoutRow() -> LumenVideoToolboxCapabilityProbeRow {
        .init(
            target: target,
            profile: profile,
            statuses: .init(
                discoveryStatus: discoveryStatus,
                createStatus: nil,
                setStatus: nil,
                prepareStatus: nil,
                encodeStatus: nil,
                callbackStatus: nil
            ),
            hardwareUsed: nil,
            parsedConfiguration: nil,
            environment: environment,
            assessment: .init(advertised: false, rejectionReason: "probe-timeout")
        )
    }
}

private func codecConfigurationData(from sampleBuffer: CMSampleBuffer) -> Data? {
    guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
          let extensions = CMFormatDescriptionGetExtensions(format) as? [CFString: Any],
          let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms]
            as? [String: Any] else {
        return nil
    }
    return (atoms["avcC"] as? Data) ?? (atoms["hvcC"] as? Data)
}

private func initialize(_ pixelBuffer: CVPixelBuffer, for pixelFormat: OSType) {
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard CVPixelBufferIsPlanar(pixelBuffer) else { return }
    for plane in 0 ..< CVPixelBufferGetPlaneCount(pixelBuffer) {
        guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else { continue }
        let byteCount = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
            * CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        if plane == 1, pixelFormat == kCVPixelFormatType_444YpCbCr8BiPlanarFullRange {
            memset(baseAddress, 128, byteCount)
        } else if plane == 1, pixelFormat == kCVPixelFormatType_444YpCbCr10BiPlanarFullRange {
            let sampleCount = byteCount / MemoryLayout<UInt16>.size
            baseAddress.bindMemory(to: UInt16.self, capacity: sampleCount)
                .update(repeating: UInt16(512 << 6), count: sampleCount)
        } else {
            memset(baseAddress, 0, byteCount)
        }
    }
}

private func fourCCString(_ value: OSType) -> String {
    String(bytes: [
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF)
    ], encoding: .ascii) ?? String(value)
}

private func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
    var value = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    let bytes = value.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

private extension KeyedEncodingContainer {
    mutating func encodeOptional<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if let value {
            try encode(value, forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }
}
