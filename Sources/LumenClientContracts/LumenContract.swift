import Foundation

public enum LumenContract {
    public static let schemaVersion: UInt32 = 1
    public static let protocolVersion: UInt32 = 4
    public static let protocolName = "lumen-stream"
    public static let protobufPackage = "lumen.streaming.v4"
    public static let alpn = "lumen-stream/4"
    public static let contractSHA256 = "99662b70c008cfecb2b4a5b58a0e0871bd5476f7b615e72ede41d07f4412460c"

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
