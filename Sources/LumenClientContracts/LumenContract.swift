import Foundation

public enum LumenContract {
    public static let schemaVersion: UInt32 = 1
    public static let protocolVersion: UInt32 = 4
    public static let protocolName = "lumen-stream"
    public static let protobufPackage = "lumen.streaming.v4"
    public static let alpn = "lumen-stream/4"
    public static let contractSHA256 = "b3efc3f6386599632c97bf25bf3b846c55d458e09a3a1f5fd5bf63dd58a6ac60"

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
