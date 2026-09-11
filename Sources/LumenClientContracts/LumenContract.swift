import Foundation

public enum LumenContract {
    public static let schemaVersion: UInt32 = 1
    public static let protocolVersion: UInt32 = 4
    public static let protocolName = "lumen-stream"
    public static let protobufPackage = "lumen.streaming.v4"
    public static let alpn = "lumen-stream/4"
    public static let contractSHA256 = "2017be2b28b9b35b4b4287e5073dbfdcf80c68f1658a4288429669bfec1ee3f0"

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
