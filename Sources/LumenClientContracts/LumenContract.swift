import Foundation

public enum LumenContract {
    public static let schemaVersion: UInt32 = 1
    public static let protocolVersion: UInt32 = 4
    public static let protocolName = "lumen-stream"
    public static let protobufPackage = "lumen.streaming.v4"
    public static let alpn = "lumen-stream/4"
    public static let contractSHA256 = "0174a07ef5e32d4915842f8093095d7a51de3643167677d739564abb0698a00d"

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
