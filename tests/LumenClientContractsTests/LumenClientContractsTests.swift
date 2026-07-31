import Testing
@testable import LumenClientContracts

@Test
func exposesGeneratedProtocolIdentityAndResources() throws {
    #expect(LumenContract.protocolVersion == 4)
    #expect(LumenContract.protobufPackage == "lumen.streaming.v4")
    let contract = try LumenContract.contractData()
    #expect(!contract.isEmpty)

    let hello = Lumen_Streaming_V4_ClientSessionHello.with {
        $0.minimumProtocolVersion = LumenContract.protocolVersion
        $0.maximumProtocolVersion = LumenContract.protocolVersion
    }
    #expect(hello.minimumProtocolVersion == 4)
    #expect(hello.maximumProtocolVersion == 4)
}
