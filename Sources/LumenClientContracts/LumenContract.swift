import Foundation

public enum LumenContract {
    public static let schemaVersion: UInt32 = 1
    public static let protocolVersion: UInt32 = 4
    public static let protocolName = "lumen-stream"
    public static let protobufPackage = "lumen.streaming.v4"
    public static let alpn = "lumen-stream/4"
    public static let contractSHA256 = "6bb33abf2aab138f6e14f1ab38a1fa1d3bfba391199ee85353dee90cf55fc225"

    public static func contractData() throws -> Data {
        guard let url = Bundle.module.url(forResource: "lumen-contract-v4", withExtension: "json") else {
            throw LumenContractResourceError.missingContract
        }
        return try Data(contentsOf: url)
    }
}

public enum LumenContractResourceError: Error {
    case missingContract
}
