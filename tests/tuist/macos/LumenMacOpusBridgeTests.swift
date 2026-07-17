import LumenMacBridge
import XCTest

final class LumenMacOpusBridgeTests: XCTestCase {
    func testSPMCOpusProductCreatesAndEncodesThroughTheMacBridge() throws {
        let mapping: [UInt8] = [0, 1]
        var error = [CChar](repeating: 0, count: 512)
        let createdEncoder = mapping.withUnsafeBufferPointer { mappingBuffer in
            LumenMacOpusEncoderCreate(
                48_000,
                2,
                2,
                0,
                mappingBuffer.baseAddress,
                128_000,
                false,
                &error,
                error.count
            )
        }
        let encoder = try XCTUnwrap(createdEncoder, errorMessage(error))
        defer { LumenMacOpusEncoderDestroy(encoder) }

        let samples = [Float](repeating: 0, count: 240 * 2)
        var packet = [UInt8](repeating: 0, count: 1_275)
        var packetSize = 0
        let encoded = samples.withUnsafeBufferPointer { sampleBuffer in
            packet.withUnsafeMutableBufferPointer { packetBuffer in
                LumenMacOpusEncoderEncodeFloat32(
                    encoder,
                    sampleBuffer.baseAddress,
                    240,
                    packetBuffer.baseAddress,
                    packetBuffer.count,
                    &packetSize,
                    &error,
                    error.count
                )
            }
        }

        XCTAssertTrue(encoded, errorMessage(error))
        XCTAssertGreaterThan(packetSize, 0)
        XCTAssertLessThanOrEqual(packetSize, packet.count)
    }

    private func errorMessage(_ buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
