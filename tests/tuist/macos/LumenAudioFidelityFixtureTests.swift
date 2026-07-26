import Foundation
import LumenMacBridge
import XCTest

final class LumenAudioFidelityFixtureTests: XCTestCase {
    private static let sampleRate = 48_000
    private static let channelCount = 2
    private static let framesPerPacket = 240
    private static let durationSeconds = 10
    private static let packetCount =
        sampleRate * durationSeconds / framesPerPacket
    private static let outputPathPointer =
        "/private/tmp/lumen-audio-fidelity-output-path"

    // The fixture intentionally keeps one linear encoder-to-artifact flow visible.
    // swiftlint:disable:next function_body_length
    func testWritesTenSecondRealOpusFixture() throws {
        let environmentPath = ProcessInfo.processInfo.environment[
            "LUMEN_AUDIO_FIDELITY_OUTPUT_DIR"
        ]
        let pointerPath = try? String(
            contentsOfFile: Self.outputPathPointer,
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let outputPath = [environmentPath, pointerPath]
            .compactMap({ $0 })
            .first(where: { !$0.isEmpty }) else {
            throw XCTSkip(
                "Set LUMEN_AUDIO_FIDELITY_OUTPUT_DIR or write the output path pointer."
            )
        }
        let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let source = Self.makeDeterministicSource()
        let mapping: [UInt8] = [0, 1]
        var error = [CChar](repeating: 0, count: 512)
        let createdEncoder = mapping.withUnsafeBufferPointer { mappingBuffer in
            LumenMacOpusEncoderCreate(
                Int32(Self.sampleRate),
                Int32(Self.channelCount),
                1,
                1,
                mappingBuffer.baseAddress,
                96_000,
                false,
                &error,
                error.count
            )
        }
        let encoder = try XCTUnwrap(createdEncoder, Self.errorMessage(error))
        defer { LumenMacOpusEncoderDestroy(encoder) }

        var fixture = Data("LAF1".utf8)
        fixture.appendLittleEndian(UInt32(Self.sampleRate))
        fixture.appendLittleEndian(UInt16(Self.channelCount))
        fixture.appendLittleEndian(UInt16(Self.framesPerPacket))
        fixture.appendLittleEndian(UInt32(Self.packetCount))
        var packet = [UInt8](repeating: 0, count: 1_400)
        for packetIndex in 0 ..< Self.packetCount {
            let frameStart = packetIndex * Self.framesPerPacket
            let sampleStart = frameStart * Self.channelCount
            let sampleEnd = sampleStart + Self.framesPerPacket * Self.channelCount
            var packetSize = 0
            let encoded = source[sampleStart ..< sampleEnd].withContiguousStorageIfAvailable { samples in
                packet.withUnsafeMutableBufferPointer { packetBuffer in
                    LumenMacOpusEncoderEncodeFloat32(
                        encoder,
                        samples.baseAddress,
                        Int32(Self.framesPerPacket),
                        packetBuffer.baseAddress,
                        packetBuffer.count,
                        &packetSize,
                        &error,
                        error.count
                    )
                }
            } ?? false
            XCTAssertTrue(encoded, Self.errorMessage(error))
            XCTAssertGreaterThan(packetSize, 0)
            XCTAssertLessThanOrEqual(packetSize, packet.count)

            fixture.appendLittleEndian(UInt32(packetIndex + 1))
            fixture.appendLittleEndian(UInt64(frameStart))
            fixture.appendLittleEndian(UInt32(Self.framesPerPacket))
            fixture.appendLittleEndian(UInt32(packetSize))
            fixture.append(contentsOf: packet.prefix(packetSize))
        }

        let sourceURL = outputDirectory.appendingPathComponent("source-f32le.pcm")
        let packetsURL = outputDirectory.appendingPathComponent("opus-packets.laf")
        let manifestURL = outputDirectory.appendingPathComponent("lumen-fixture.json")
        let sourceData = source.withUnsafeBytes { Data($0) }
        try sourceData.write(to: sourceURL, options: .atomic)
        try fixture.write(to: packetsURL, options: .atomic)
        let manifest = LumenAudioFidelityFixtureManifest(
            schemaVersion: 1,
            sampleRate: Self.sampleRate,
            channelCount: Self.channelCount,
            framesPerPacket: Self.framesPerPacket,
            packetCount: Self.packetCount,
            durationSeconds: Self.durationSeconds,
            sourceFrames: source.count / Self.channelCount,
            sourceFile: sourceURL.lastPathComponent,
            packetFile: packetsURL.lastPathComponent,
            opusApplication: "restricted-low-delay",
            bitrateBitsPerSecond: 96_000,
            variableBitrate: false
        )
        let manifestEncoder = JSONEncoder()
        manifestEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try manifestEncoder.encode(manifest).write(
            to: manifestURL,
            options: .atomic
        )
    }

    private static func makeDeterministicSource() -> [Float] {
        let frameCount = sampleRate * durationSeconds
        var samples = [Float]()
        samples.reserveCapacity(frameCount * channelCount)
        for frame in 0 ..< frameCount {
            let time = Double(frame) / Double(sampleRate)
            let edgeFrames = min(frame, frameCount - 1 - frame)
            let envelope = min(1, Double(max(0, edgeFrames)) / 960)
            let modulation = 0.78 + 0.22 * sin(2 * .pi * 1.7 * time)
            let left = envelope * modulation * (
                0.34 * sin(2 * .pi * (220 * time + 4.5 * time * time))
                    + 0.16 * sin(2 * .pi * 997 * time)
            )
            let right = envelope * modulation * (
                0.32 * sin(2 * .pi * (311 * time + 6.25 * time * time))
                    + 0.18 * sin(2 * .pi * 1_237 * time)
            )
            samples.append(Float(left))
            samples.append(Float(right))
        }
        return samples
    }

    private static func errorMessage(_ buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }
}

private struct LumenAudioFidelityFixtureManifest: Encodable {
    let schemaVersion: Int
    let sampleRate: Int
    let channelCount: Int
    let framesPerPacket: Int
    let packetCount: Int
    let durationSeconds: Int
    let sourceFrames: Int
    let sourceFile: String
    let packetFile: String
    let opusApplication: String
    let bitrateBitsPerSecond: Int
    let variableBitrate: Bool
}

private extension Data {
    mutating func appendLittleEndian<Value: FixedWidthInteger>(_ value: Value) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
