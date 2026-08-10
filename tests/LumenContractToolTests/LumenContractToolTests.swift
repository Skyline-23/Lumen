import Foundation
import Testing

@testable import LumenContractToolCore

@Test
func validatesCurrentContract() throws {
  let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  _ = try LumenContractTool.loadValidatedContract(root: root)
}

@Test
func rejectsIdentityMutation() throws {
  let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  var contract = try LumenContractTool.loadValidatedContract(root: root)
  var identity = try #require(contract["identity"] as? [String: Any])
  identity["version"] = 5
  contract["identity"] = identity
  #expect(throws: LumenContractToolError.self) {
    try LumenContractTool.validate(contract)
  }
}

@Test
func preservesPublishedV4Authority() throws {
  let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  let contract = try LumenContractTool.loadValidatedContract(root: root)
  let native = try #require(contract["nativeTransport"] as? [String: Any])
  let telemetry = try #require(native["telemetry"] as? [String: Any])
  let parityRange = try #require(telemetry["parityRangePercentage"] as? [NSNumber])
  #expect(parityRange.map(\.intValue) == [5, 50])

  let https = try #require(contract["https"] as? [String: Any])
  let authentication = try #require(https["authentication"] as? [String: Any])
  let routes = try #require(authentication["protectedRoutes"] as? [String: [String: String]])
  #expect(routes.count == 6)
  #expect(routes.values.contains(["method": "GET", "path": "/launch"]))
  #expect(routes.values.contains(["method": "GET", "path": "/resume"]))
  #expect(routes.values.contains(["method": "GET", "path": "/cancel"]))
  #expect(routes.values.contains(["method": "GET", "path": "/actions/clipboard"]))
  #expect(routes.values.contains(["method": "POST", "path": "/actions/clipboard"]))
}

@Test
func orderedRendererPreservesPublishedConformanceBytes() throws {
  let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  let authority = try Data(contentsOf: root.appending(path: "docs/protocol/lumen-contract-v4.json"))
  #expect(
    try LumenContractTool.renderedSection(data: authority, path: ["nativeTransport"])
      == Data(
        contentsOf: root.appending(path: "docs/protocol/lumen-native-transport-conformance.json"))
  )
  #expect(
    try LumenContractTool.renderedSection(data: authority, path: ["https", "authentication"])
      == Data(contentsOf: root.appending(path: "docs/protocol/lumen-auth-conformance.json"))
  )
}

@Test
func generatedAPIReferenceMatchesCommittedArtifact() throws {
  let root = repositoryRoot()
  let generated = try LumenContractTool.renderedAPIReference(root: root)
  let committed = try Data(
    contentsOf: root.appending(path: "docs/protocol/lumen-api-reference.md"))

  #expect(generated == committed)
  #expect(generated.last == 0x0A)
  #expect(
    String(decoding: generated, as: UTF8.self)
      .contains("- Descriptor source name: `lumen-streaming-v4.proto`")
  )
}

@Test
func generatedAPIReferenceCoversEveryProtobufDeclaration() throws {
  let root = repositoryRoot()
  let reference = try apiReference(root: root)
  let inventory = try LumenContractTool.apiReferenceInventory(root: root)

  #expect(inventory.enumNames.count == 22)
  #expect(inventory.messageNames.count == 42)
  #expect(inventory.fieldNames.count == 286)
  #expect(inventory.serviceNames.isEmpty)
  #expect(inventory.explicitOneofNames.count == 6)
  #expect(inventory.syntheticOneofNames.count == 3)

  for name in inventory.enumNames + inventory.enumValueNames + inventory.messageNames
    + inventory.fieldNames + inventory.serviceNames + inventory.explicitOneofNames
    + inventory.syntheticOneofNames
  {
    #expect(reference.contains(name), "Missing protobuf declaration: \(name)")
  }
}

@Test
func generatedAPIReferenceCoversHTTPSAuthoritiesAndLimitations() throws {
  let root = repositoryRoot()
  let reference = try apiReference(root: root)
  let contract = try currentContract()
  let https = try #require(contract["https"] as? [String: Any])
  let authentication = try #require(https["authentication"] as? [String: Any])
  let settings = try #require(https["settings"] as? [String: Any])

  let authenticationNetwork = try #require(
    authentication["networkTransport"] as? [String: Any])
  let authenticationRoutes = try #require(
    authenticationNetwork["routes"] as? [String: String])
  for (name, path) in authenticationRoutes {
    #expect(reference.contains(name), "Missing authentication route: \(name)")
    #expect(reference.contains(path), "Missing authentication path: \(path)")
  }
  for sectionName in ["conditionalRoutes", "protectedRoutes"] {
    let routes = try #require(authentication[sectionName] as? [String: [String: Any]])
    for (name, route) in routes {
      let path = try #require(route["path"] as? String)
      #expect(reference.contains(name), "Missing authentication route: \(name)")
      #expect(reference.contains(path), "Missing authentication path: \(path)")
    }
  }

  let operations = try #require(authentication["operations"] as? [String: Any])
  for name in operations.keys {
    #expect(
      reference.contains("### authentication operation `\(name)`"),
      "Missing authentication operation: \(name)"
    )
  }
  for error in try #require(authentication["errorCodes"] as? [String]) {
    #expect(reference.contains("`\(error)`"), "Missing authentication error: \(error)")
  }

  let settingsNetwork = try #require(settings["networkTransport"] as? [String: Any])
  let settingsRoutes = try #require(settingsNetwork["routes"] as? [String: [String: Any]])
  for (name, route) in settingsRoutes {
    let path = try #require(route["path"] as? String)
    #expect(reference.contains("`\(name)`"), "Missing settings route: \(name)")
    #expect(reference.contains(path), "Missing settings path: \(path)")
  }
  for field in try #require(settings["fields"] as? [[String: Any]]) {
    let key = try #require(field["key"] as? String)
    #expect(reference.contains(key), "Missing settings field: \(key)")
  }
  for error in try #require(settings["errorCodes"] as? [String]) {
    #expect(reference.contains("`\(error)`"), "Missing settings error: \(error)")
  }

  for requiredText in [
    "ClientSessionHello",
    "HostSessionPlan",
    "StopSession",
    "SessionStopped",
    "capture_timestamp_us",
    "/api/v1/auth/enroll",
    "/launch",
    "/api/v1/settings",
    "general.name",
    "network.fecPercentage",
    #""legacyProtocol" : false"#,
    "## Contract limitations",
    "## Implementation checklist",
    "tokenExchange` and operation identifier `exchangeRefreshToken",
    "`verifyAccessToken` has no declared HTTP route",
    "do not declare required fields, nullability, or HTTP status codes",
    "must not infer route mappings",
    "b3efc3f6386599632c97bf25bf3b846c55d458e09a3a1f5fd5bf63dd58a6ac60",
  ] {
    #expect(reference.contains(requiredText), "Missing API reference text: \(requiredText)")
  }
}

@Test
func permitsAdditiveProtobufDeclaration() throws {
  let contract = try currentContract()
  var candidate = contract
  var protobuf = try #require(candidate["protobuf"] as? [String: Any])
  let source = try #require(protobuf["source"] as? String)
  protobuf["source"] =
    source + "\nmessage FutureExtension {\n  uint32 value = 1;\n}\n"
  candidate["protobuf"] = protobuf
  try LumenContractTool.checkCompatibility(baseline: contract, current: candidate)
}

@Test
func permitsAdditiveMediaCapabilityBit() throws {
  let current = try currentContract()
  var baseline = current
  var native = try #require(baseline["nativeTransport"] as? [String: Any])
  var capabilities = try #require(native["mediaCapabilities"] as? [String: Any])
  capabilities["supportedMask"] = 31
  capabilities.removeValue(forKey: "mediaParkResume")
  native["mediaCapabilities"] = capabilities
  baseline["nativeTransport"] = native

  try LumenContractTool.checkCompatibility(baseline: baseline, current: current)
}

@Test
func rejectsDocumentationMutationForProtobufCommentOnlyChange() throws {
  try assertStreamingDocumentationMutationIsRejected { current in
    var protobuf = try #require(current["protobuf"] as? [String: Any])
    protobuf["source"] = try #require(protobuf["source"] as? String)
      + "\n// source-only compatibility comment\n"
    current["protobuf"] = protobuf
  }
}

@Test
func rejectsDocumentationMutationForUnknownMediaCapability() throws {
  try assertStreamingDocumentationMutationIsRejected { current in
    var native = try #require(current["nativeTransport"] as? [String: Any])
    var mediaCapabilities = try #require(native["mediaCapabilities"] as? [String: Any])
    mediaCapabilities["futureMediaCapability"] = 64
    native["mediaCapabilities"] = mediaCapabilities
    current["nativeTransport"] = native
  }
}

private func assertStreamingDocumentationMutationIsRejected(
  _ mutate: (inout [String: Any]) throws -> Void
) throws {
  let sourceRoot = repositoryRoot()
  let fileManager = FileManager.default
  let temporaryRoot = fileManager.temporaryDirectory.appending(
    path: "lumen-contract-compatibility-\(UUID().uuidString)"
  )
  defer { try? fileManager.removeItem(at: temporaryRoot) }
  let currentProtocolRoot = temporaryRoot.appending(path: "docs/protocol")
  let baselineRoot = temporaryRoot.appending(path: "baseline")
  try fileManager.createDirectory(at: currentProtocolRoot, withIntermediateDirectories: true)
  try fileManager.createDirectory(at: baselineRoot, withIntermediateDirectories: true)

  let contractName = "lumen-contract-v4.json"
  let schemaName = "lumen-contract-v4.schema.json"
  let streamingName = "lumen-streaming-protocol.md"
  let settingsName = "lumen-settings-protocol.md"
  for name in [contractName, schemaName, streamingName, settingsName] {
    let source = sourceRoot.appending(path: "docs/protocol/\(name)")
    try fileManager.copyItem(
      at: source,
      to: baselineRoot.appending(path: name)
    )
    try fileManager.copyItem(
      at: source,
      to: currentProtocolRoot.appending(path: name)
    )
  }

  var current = try #require(
    JSONSerialization.jsonObject(
      with: Data(contentsOf: currentProtocolRoot.appending(path: contractName))
    ) as? [String: Any]
  )
  try mutate(&current)
  try JSONSerialization.data(
    withJSONObject: current,
    options: [.prettyPrinted, .sortedKeys]
  ).write(to: currentProtocolRoot.appending(path: contractName))
  let currentStreaming = currentProtocolRoot.appending(path: streamingName)
  try Data(
    (try String(contentsOf: currentStreaming, encoding: .utf8) + "\ncompatibility-only prose\n")
      .utf8
  ).write(to: currentStreaming)

  #expect(throws: LumenContractToolError.self) {
    try LumenContractTool.run(
      arguments: [
        "compatibility",
        "--baseline", baselineRoot.appending(path: contractName).path,
        "--baseline-schema", baselineRoot.appending(path: schemaName).path,
        "--baseline-streaming-doc", baselineRoot.appending(path: streamingName).path,
        "--baseline-settings-doc", baselineRoot.appending(path: settingsName).path,
      ],
      root: temporaryRoot
    )
  }
}

@Test
func rejectsChangedProtobufFieldNumber() throws {
  let contract = try currentContract()
  var candidate = contract
  var protobuf = try #require(candidate["protobuf"] as? [String: Any])
  let source = try #require(protobuf["source"] as? String)
  protobuf["source"] = source.replacingOccurrences(
    of: "uint32 protocol_version = 1;",
    with: "uint32 protocol_version = 99;"
  )
  candidate["protobuf"] = protobuf
  #expect(throws: LumenContractToolError.self) {
    try LumenContractTool.checkCompatibility(baseline: contract, current: candidate)
  }
}

@Test
func rejectsChangedProtobufFieldOptions() throws {
  let contract = try currentContract()
  var candidate = contract
  var protobuf = try #require(candidate["protobuf"] as? [String: Any])
  let source = try #require(protobuf["source"] as? String)
  protobuf["source"] = source.replacingOccurrences(
    of: "uint32 protocol_version = 1;",
    with: "uint32 protocol_version = 1 [deprecated = true];"
  )
  candidate["protobuf"] = protobuf
  #expect(throws: LumenContractToolError.self) {
    try LumenContractTool.checkCompatibility(baseline: contract, current: candidate)
  }
}

@Test
func rejectsChangedProtobufEnumValueOptions() throws {
  let contract = try currentContract()
  var candidate = contract
  var protobuf = try #require(candidate["protobuf"] as? [String: Any])
  let source = try #require(protobuf["source"] as? String)
  protobuf["source"] = source.replacingOccurrences(
    of: "VIDEO_CODEC_H264 = 1;",
    with: "VIDEO_CODEC_H264 = 1 [deprecated = true];"
  )
  candidate["protobuf"] = protobuf
  #expect(throws: LumenContractToolError.self) {
    try LumenContractTool.checkCompatibility(baseline: contract, current: candidate)
  }
}

@Test
func rejectsChangedProtobufFileOptions() throws {
  let contract = try currentContract()
  var candidate = contract
  var protobuf = try #require(candidate["protobuf"] as? [String: Any])
  let source = try #require(protobuf["source"] as? String)
  protobuf["source"] = source.replacingOccurrences(
    of: "package lumen.streaming.v4;",
    with: "package lumen.streaming.v4;\n\noption swift_prefix = \"Break\";"
  )
  candidate["protobuf"] = protobuf
  #expect(throws: LumenContractToolError.self) {
    try LumenContractTool.checkCompatibility(baseline: contract, current: candidate)
  }
}

@Test
func rejectsChangedNativeAuthority() throws {
  let contract = try currentContract()
  var candidate = contract
  var native = try #require(candidate["nativeTransport"] as? [String: Any])
  var flags = try #require(native["flags"] as? [String: Any])
  flags["keyframe"] = 2
  native["flags"] = flags
  candidate["nativeTransport"] = native
  #expect(throws: LumenContractToolError.self) {
    try LumenContractTool.checkCompatibility(baseline: contract, current: candidate)
  }
}

@Test
func rejectsChangedNativeAuthorityOutsideLegacyAllowlist() throws {
  let contract = try currentContract()
  var candidate = contract
  var native = try #require(candidate["nativeTransport"] as? [String: Any])
  native["controlTransport"] = "tcp"
  candidate["nativeTransport"] = native
  #expect(throws: LumenContractToolError.self) {
    try LumenContractTool.checkCompatibility(baseline: contract, current: candidate)
  }
}

@Test
func permitsAdditiveAuthenticationError() throws {
  let contract = try currentContract()
  var candidate = contract
  var https = try #require(candidate["https"] as? [String: Any])
  var authentication = try #require(https["authentication"] as? [String: Any])
  var errors = try #require(authentication["errorCodes"] as? [Any])
  errors.append("future-error")
  authentication["errorCodes"] = errors
  https["authentication"] = authentication
  candidate["https"] = https
  try LumenContractTool.checkCompatibility(baseline: contract, current: candidate)
}

@Test
func rejectsDuplicateSettingsFieldKeysAndOrders() throws {
  let contract = try currentContract()
  for mutation in ["key", "order"] {
    var candidate = contract
    var https = try #require(candidate["https"] as? [String: Any])
    var settings = try #require(https["settings"] as? [String: Any])
    var fields = try #require(settings["fields"] as? [[String: Any]])
    var duplicate = try #require(fields.first)
    if mutation == "key" {
      duplicate["order"] = 999
    } else {
      duplicate["key"] = "future.duplicate-order"
    }
    fields.append(duplicate)
    settings["fields"] = fields
    https["settings"] = settings
    candidate["https"] = https

    #expect(throws: LumenContractToolError.self) {
      try LumenContractTool.validate(candidate)
    }
    #expect(throws: LumenContractToolError.self) {
      try LumenContractTool.checkCompatibility(baseline: contract, current: candidate)
    }
  }
}

@Test
func rejectsChangedHandwrittenProtocolAuthority() {
  let baseline = "A bootstrap must be acknowledged before the first delta.\n"
  let current = "A bootstrap need not be acknowledged before the first delta.\n"
  #expect(throws: LumenContractToolError.self) {
    try LumenContractTool.compareDocumentation(
      baseline: baseline,
      current: current,
      label: "streaming documentation"
    )
  }
}

@Test
func committedMetaSchemaRejectsAdditionalContractProperties() throws {
  let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  var contract = try currentContract()
  contract["unpublishedAuthority"] = true
  let schemaData = try Data(
    contentsOf: root.appending(path: "docs/protocol/lumen-contract-v4.schema.json"))
  let schema = try #require(
    JSONSerialization.jsonObject(with: schemaData) as? [String: Any]
  )
  #expect(throws: LumenContractToolError.self) {
    try LumenContractTool.validateSchema(instance: contract, schema: schema, path: "$")
  }
}

@Test
func rejectsAmbiguousOrderedJSON() {
  for source in [#"{"section": 1, "section": 2}"#, #"{"section": 01}"#] {
    #expect(throws: LumenContractToolError.self) {
      try LumenContractTool.renderedSection(data: Data(source.utf8), path: ["section"])
    }
  }
}

@Test
func rejectsBooleanIntegerAuthority() throws {
  var contract = try currentContract()
  contract["schemaVersion"] = true
  #expect(throws: LumenContractToolError.self) {
    try LumenContractTool.validate(contract)
  }
}

@Test
func rejectsUnknownLifecycleAuthorityKeys() throws {
  try assertContractValidationRejects { contract in
    contract["futureTopLevelAuthority"] = true
  }

  try assertContractValidationRejects { contract in
    var lifecycle = try #require(contract["lifecycle"] as? [String: Any])
    lifecycle["futureLifecycleAuthority"] = true
    contract["lifecycle"] = lifecycle
  }

  try assertContractValidationRejects { contract in
    var lifecycle = try #require(contract["lifecycle"] as? [String: Any])
    var mediaPark = try #require(lifecycle["mediaParkResume"] as? [String: Any])
    mediaPark["futureMediaParkAuthority"] = true
    lifecycle["mediaParkResume"] = mediaPark
    contract["lifecycle"] = lifecycle
  }

  try assertContractValidationRejects { contract in
    var native = try #require(contract["nativeTransport"] as? [String: Any])
    var capabilities = try #require(native["mediaCapabilities"] as? [String: Any])
    capabilities["futureMediaCapability"] = 64
    native["mediaCapabilities"] = capabilities
    contract["nativeTransport"] = native
  }
}

@Test
func rejectsUnknownNestedAuthorityDuringCompatibility() throws {
  let baseline = try currentContract()
  var candidate = baseline
  var native = try #require(candidate["nativeTransport"] as? [String: Any])
  var capabilities = try #require(native["mediaCapabilities"] as? [String: Any])
  capabilities["futureMediaCapability"] = 64
  native["mediaCapabilities"] = capabilities
  candidate["nativeTransport"] = native

  #expect(throws: LumenContractToolError.self) {
    try LumenContractTool.checkCompatibility(
      baseline: baseline,
      current: candidate
    )
  }
}

@Test
func rejectsInvalidMediaParkLifecycleSemantics() throws {
  try assertContractValidationRejects { contract in
    try mutateLifecycleSection(&contract, "mediaParkResume") { mediaPark in
      mediaPark["capabilityBit"] = 16
    }
  }
  try assertContractValidationRejects { contract in
    try mutateLifecycleSection(&contract, "mediaParkResume") { mediaPark in
      mediaPark["request"] = "StartSessionAck"
    }
  }
  try assertContractValidationRejects { contract in
    try mutateLifecycleSection(&contract, "mediaParkResume") { mediaPark in
      mediaPark["response"] = "SessionStarted"
    }
  }
  try assertContractValidationRejects { contract in
    try mutateLifecycleSection(&contract, "mediaParkResume") { mediaPark in
      mediaPark["states"] = ["active", "parked"]
    }
  }
  try assertContractValidationRejects { contract in
    try mutateLifecycleSection(&contract, "mediaParkResume") { mediaPark in
      mediaPark["strictlyIncreasingRevision"] = false
    }
  }
  try assertContractValidationRejects { contract in
    try mutateLifecycleSection(&contract, "mediaParkResume") { mediaPark in
      mediaPark["idempotentCurrentTarget"] = false
    }
  }
  try assertContractValidationRejects { contract in
    try mutateLifecycleSection(&contract, "mediaParkResume") { mediaPark in
      mediaPark["staleResult"] = "ignored"
    }
  }
  try assertContractValidationRejects { contract in
    try mutateLifecycleSection(&contract, "mediaParkResume") { mediaPark in
      mediaPark["resumeRequiresFreshBootstrap"] = false
    }
  }
  try assertContractValidationRejects { contract in
    try mutateLifecycleSection(&contract, "mediaParkResume") { mediaPark in
      mediaPark["stopFromParked"] = "MediaParkResult"
    }
  }
}

@Test
func rejectsInvalidStopAndLifecycleValues() throws {
  try assertContractValidationRejects { contract in
    var lifecycle = try #require(contract["lifecycle"] as? [String: Any])
    lifecycle["codecBootstrapSequence"] = ["host-video-bootstrap"]
    contract["lifecycle"] = lifecycle
  }
  try assertContractValidationRejects { contract in
    try mutateLifecycleSection(&contract, "generation") { generation in
      generation["initial"] = 2
    }
  }
  try assertContractValidationRejects { contract in
    try mutateLifecycleSection(&contract, "generation") { generation in
      generation["staleRepairRequest"] = "reject"
    }
  }
  try assertContractValidationRejects { contract in
    try mutateLifecycleSection(&contract, "sessionStop") { sessionStop in
      sessionStop["request"] = "MediaParkRequest"
    }
  }
  try assertContractValidationRejects { contract in
    try mutateLifecycleSection(&contract, "sessionStop") { sessionStop in
      sessionStop["response"] = "MediaParkResult"
    }
  }
  try assertContractValidationRejects { contract in
    try mutateLifecycleSection(&contract, "sessionStop") { sessionStop in
      sessionStop["matchingSessionEpochRequired"] = false
    }
  }
  try assertContractValidationRejects { contract in
    try mutateLifecycleSection(&contract, "sessionStop") { sessionStop in
      sessionStop["responseRequiredBeforeClientCompletion"] = false
    }
  }
  try assertContractValidationRejects { contract in
    try mutateLifecycleSection(&contract, "displayReconfiguration") { display in
      display["resultCodes"] = ["applied", "superseded"]
    }
  }
  try assertContractValidationRejects { contract in
    try mutateLifecycleSection(&contract, "fallback") { fallback in
      fallback["legacyProtocol"] = "false"
    }
  }
}

@Test
func reportsProtobufCompilerFailure() throws {
  let contract = try currentContract()
  var candidate = contract
  var protobuf = try #require(candidate["protobuf"] as? [String: Any])
  let source = try #require(protobuf["source"] as? String)
  protobuf["source"] = source.replacingOccurrences(
    of: "syntax = \"proto3\";",
    with: "syntax = \"proto3\""
  )
  candidate["protobuf"] = protobuf

  do {
    try LumenContractTool.checkCompatibility(baseline: contract, current: candidate)
    Issue.record("Malformed protobuf was accepted")
  } catch let error as LumenContractToolError {
    #expect(error.description.contains("Expected \";\""))
  }
}

private func currentContract() throws -> [String: Any] {
  try LumenContractTool.loadValidatedContract(root: repositoryRoot())
}

private func assertContractValidationRejects(
  _ mutate: (inout [String: Any]) throws -> Void
) throws {
  var contract = try currentContract()
  try mutate(&contract)
  #expect(throws: LumenContractToolError.self) {
    try LumenContractTool.validate(contract)
  }
}

private func mutateLifecycleSection(
  _ contract: inout [String: Any],
  _ section: String,
  _ mutate: (inout [String: Any]) throws -> Void
) throws {
  var lifecycle = try #require(contract["lifecycle"] as? [String: Any])
  var value = try #require(lifecycle[section] as? [String: Any])
  try mutate(&value)
  lifecycle[section] = value
  contract["lifecycle"] = lifecycle
}

private func repositoryRoot() -> URL {
  URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
}

private func apiReference(root: URL) throws -> String {
  let data = try LumenContractTool.renderedAPIReference(root: root)
  return try #require(String(data: data, encoding: .utf8))
}
