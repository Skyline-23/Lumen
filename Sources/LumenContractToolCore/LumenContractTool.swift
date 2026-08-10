import CoreFoundation
import CryptoKit
import Foundation
import SwiftProtobuf

public enum LumenContractToolError: Error, CustomStringConvertible {
  case invalid(String)
  case process(String)
  case usage

  public var description: String {
    switch self {
    case .invalid(let message), .process(let message):
      message
    case .usage:
      "usage: lumen-contract-tool <validate|generate|check|compatibility [OPTIONS]>"
    }
  }
}

public enum LumenContractTool {
  public static func run(
    arguments: [String],
    root: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  ) throws {
    guard let command = arguments.first else { throw LumenContractToolError.usage }
    switch command {
    case "validate":
      _ = try loadValidatedContract(root: root)
    case "generate":
      try publish(document: loadValidatedDocument(root: root), root: root, check: false)
    case "check":
      try publish(document: loadValidatedDocument(root: root), root: root, check: true)
    case "compatibility":
      try runCompatibility(arguments: Array(arguments.dropFirst()), root: root)
    default:
      throw LumenContractToolError.usage
    }
  }

  public static func loadValidatedContract(root: URL) throws -> [String: Any] {
    try loadValidatedDocument(root: root).object
  }

  public static func validate(_ contract: [String: Any]) throws {
    _ = try requireKeys(
      contract,
      ["$schema", "schemaVersion", "identity", "protobuf", "nativeTransport", "https", "lifecycle", "rendering"],
      "contract"
    )
    try require(number(contract["schemaVersion"]) == 1, "schemaVersion must be 1")
    try require(
      string(contract["$schema"]) == "https://lumen.skyline23.com/schemas/contract-v1.json",
      "contract must reference the committed meta-schema"
    )
    let identity = try dictionary(contract["identity"], "identity")
    try require(
      jsonEqual(
        identity,
        [
          "name": "lumen-stream",
          "version": 4,
          "package": "lumen.streaming.v4",
          "alpn": "lumen-stream/4",
        ]),
      "invalid protocol identity"
    )

    let protobuf = try dictionary(contract["protobuf"], "protobuf")
    try require(string(protobuf["syntax"]) == "proto3", "protobuf syntax must be proto3")
    try require(string(protobuf["package"]) == "lumen.streaming.v4", "invalid protobuf package")
    let source = try requiredString(protobuf["source"], "protobuf.source")
    for fragment in [
      "syntax = \"proto3\";", "package lumen.streaming.v4;", "reserved 3;", "reserved 8;",
      "reserved 7, 8, 9;", "uint64 media_capabilities = 46;",
      "StopSession stop_session = 13;", "SessionStopped session_stopped = 12;",
      "MediaParkRequest media_park = 18;", "MediaParkResult media_park = 17;",
    ] {
      try require(
        source.contains(fragment), "protobuf source is missing required boundary: \(fragment)")
    }

    let native = try dictionary(contract["nativeTransport"], "nativeTransport")
    let flags = try dictionary(native["flags"], "nativeTransport.flags")
    try require(number(flags["keyframe"]) == 1, "keyframe flag must be 0x01")
    let bootstrap = try dictionary(native["videoBootstrap"], "nativeTransport.videoBootstrap")
    try require(
      bootstrap["periodicByDefault"] as? Bool == true,
      "periodic keyframe scheduling must preserve v4 authority"
    )
    let telemetry = try dictionary(native["telemetry"], "nativeTransport.telemetry")
    try require(
      numbers(telemetry["parityRangePercentage"]) == [5, 50],
      "telemetry parity range must preserve v4 authority"
    )
    let capabilities = try dictionary(
      native["mediaCapabilities"], "nativeTransport.mediaCapabilities")
    _ = try requireKeys(
      capabilities,
      [
        "sameGenerationKeyframes", "fixedCadenceFeedback", "continuousScroll",
        "pairedFeedbackWindows", "packetArrivalFeedback", "requiredMask", "supportedMask",
        "mediaParkResume",
      ],
      "nativeTransport.mediaCapabilities"
    )
    try require(
      number(capabilities["requiredMask"]) == 15 && number(capabilities["supportedMask"]) == 63
        && number(capabilities["mediaParkResume"]) == 32,
      "media capability masks must match protocol v4"
    )
    let dynamicRange = try dictionary(
      native["dynamicRangeTransport"], "nativeTransport.dynamicRangeTransport")
    try require(
      jsonEqual(
        dynamicRange,
        [
          "unknown": 0, "sdr": 1, "fullFrameHdr": 2, "frameGatedHdr": 3,
          "sdrBaseHdrOverlay": 4,
        ]),
      "dynamic-range transport values must match the native ABI"
    )

    let https = try dictionary(contract["https"], "https")
    let authentication = try dictionary(https["authentication"], "https.authentication")
    let protectedRoutes = try dictionary(
      authentication["protectedRoutes"], "authentication.protectedRoutes")
    let actualProtectedRoutes = Set(try nestedRoutes(protectedRoutes).keys)
    try require(
      actualProtectedRoutes
        == Set([
          Route(method: "GET", path: "/api/discovery/apps"),
          Route(method: "GET", path: "/launch"),
          Route(method: "GET", path: "/resume"),
          Route(method: "GET", path: "/cancel"),
          Route(method: "GET", path: "/actions/clipboard"),
          Route(method: "POST", path: "/actions/clipboard"),
        ]),
      "authentication conformance must preserve every v4 protected route"
    )
    let settings = try dictionary(https["settings"], "https.settings")
    _ = try indexedFields(settings["fields"])
    let rendering = try dictionary(contract["rendering"], "rendering")
    try validateRendering(rendering["settingsConformance"], equals: settings, label: "settings")

    let lifecycle = try dictionary(contract["lifecycle"], "lifecycle")
    _ = try requireKeys(
      lifecycle,
      [
        "codecBootstrapSequence", "generation", "sessionStop", "displayReconfiguration",
        "mediaParkResume", "fallback",
      ],
      "lifecycle"
    )
    let bootstrapSequence = try requiredStringArray(
      lifecycle["codecBootstrapSequence"], "lifecycle.codecBootstrapSequence")
    try require(
      bootstrapSequence == [
        "host-codec-configuration",
        "client-codec-configuration-ack",
        "host-video-bootstrap",
        "client-hardware-decode",
        "client-video-bootstrap-result-decoded",
        "host-video-delta-admission",
      ],
      "lifecycle.codecBootstrapSequence must preserve the v4 ordering"
    )

    let generation = try dictionary(lifecycle["generation"], "lifecycle.generation")
    _ = try requireKeys(
      generation,
      [
        "initial", "configurationChangeCreatesGeneration", "explicitRepairCreatesGeneration",
        "periodicKeyframeRetainsGeneration", "staleRepairRequest",
      ],
      "lifecycle.generation"
    )
    try require(
      number(generation["initial"]) == 1,
      "lifecycle.generation.initial must be 1"
    )
    let configurationChangeCreatesGeneration = try requiredBool(
      generation["configurationChangeCreatesGeneration"],
      "lifecycle.generation.configurationChangeCreatesGeneration"
    )
    try require(configurationChangeCreatesGeneration, "configuration changes must create a generation")
    let explicitRepairCreatesGeneration = try requiredBool(
      generation["explicitRepairCreatesGeneration"],
      "lifecycle.generation.explicitRepairCreatesGeneration"
    )
    try require(explicitRepairCreatesGeneration, "explicit repairs must create a generation")
    let periodicKeyframeRetainsGeneration = try requiredBool(
      generation["periodicKeyframeRetainsGeneration"],
      "lifecycle.generation.periodicKeyframeRetainsGeneration"
    )
    try require(periodicKeyframeRetainsGeneration, "periodic keyframes must retain their generation")
    let staleRepairRequest = try requiredString(
      generation["staleRepairRequest"],
      "lifecycle.generation.staleRepairRequest"
    )
    try require(staleRepairRequest == "ignore", "stale repair requests must be ignored")

    let sessionStop = try dictionary(lifecycle["sessionStop"], "lifecycle.sessionStop")
    _ = try requireKeys(
      sessionStop,
      [
        "request", "response", "matchingSessionEpochRequired",
        "responseRequiredBeforeClientCompletion",
      ],
      "lifecycle.sessionStop"
    )
    let sessionStopRequest = try requiredString(
      sessionStop["request"],
      "lifecycle.sessionStop.request"
    )
    try require(sessionStopRequest == "StopSession", "lifecycle.sessionStop.request must be StopSession")
    let sessionStopResponse = try requiredString(
      sessionStop["response"],
      "lifecycle.sessionStop.response"
    )
    try require(sessionStopResponse == "SessionStopped", "lifecycle.sessionStop.response must be SessionStopped")
    let matchingSessionEpochRequired = try requiredBool(
      sessionStop["matchingSessionEpochRequired"],
      "lifecycle.sessionStop.matchingSessionEpochRequired"
    )
    try require(matchingSessionEpochRequired, "StopSession must match the active session epoch")
    let responseRequiredBeforeClientCompletion = try requiredBool(
      sessionStop["responseRequiredBeforeClientCompletion"],
      "lifecycle.sessionStop.responseRequiredBeforeClientCompletion"
    )
    try require(responseRequiredBeforeClientCompletion, "StopSession completion requires SessionStopped")

    let displayReconfiguration = try dictionary(
      lifecycle["displayReconfiguration"], "lifecycle.displayReconfiguration")
    _ = try requireKeys(
      displayReconfiguration,
      ["request", "response", "strictlyIncreasingRevision", "resultCodes"],
      "lifecycle.displayReconfiguration"
    )
    let displayReconfigurationRequest = try requiredString(
      displayReconfiguration["request"],
      "lifecycle.displayReconfiguration.request"
    )
    try require(
      displayReconfigurationRequest == "DisplayReconfigurationRequest",
      "display reconfiguration request must be DisplayReconfigurationRequest"
    )
    let displayReconfigurationResponse = try requiredString(
      displayReconfiguration["response"],
      "lifecycle.displayReconfiguration.response"
    )
    try require(
      displayReconfigurationResponse == "DisplayReconfigurationResult",
      "display reconfiguration response must be DisplayReconfigurationResult"
    )
    let strictlyIncreasingDisplayRevision = try requiredBool(
      displayReconfiguration["strictlyIncreasingRevision"],
      "lifecycle.displayReconfiguration.strictlyIncreasingRevision"
    )
    try require(
      strictlyIncreasingDisplayRevision,
      "display reconfiguration revisions must be strictly increasing"
    )
    let displayReconfigurationResultCodes = try requiredStringArray(
      displayReconfiguration["resultCodes"],
      "lifecycle.displayReconfiguration.resultCodes"
    )
    try require(
      displayReconfigurationResultCodes == ["applied", "rejected", "superseded"],
      "display reconfiguration result codes must preserve the v4 values"
    )

    let fallback = try dictionary(lifecycle["fallback"], "lifecycle.fallback")
    _ = try requireKeys(
      fallback,
      ["legacyProtocol", "silentFormatDowngrade"],
      "lifecycle.fallback"
    )
    let legacyProtocol = try requiredBool(
      fallback["legacyProtocol"],
      "lifecycle.fallback.legacyProtocol"
    )
    let silentFormatDowngrade = try requiredBool(
      fallback["silentFormatDowngrade"],
      "lifecycle.fallback.silentFormatDowngrade"
    )
    try require(!legacyProtocol && !silentFormatDowngrade, "fallback is forbidden")
    let mediaPark = try dictionary(lifecycle["mediaParkResume"], "lifecycle.mediaParkResume")
    _ = try requireKeys(
      mediaPark,
      [
        "capabilityBit", "request", "response", "states", "strictlyIncreasingRevision",
        "idempotentCurrentTarget", "staleResult", "resumeRequiresFreshBootstrap", "stopFromParked",
      ],
      "lifecycle.mediaParkResume"
    )
    try require(
      number(mediaPark["capabilityBit"]) == 32,
      "media park capability bit must be 32"
    )
    let mediaParkRequest = try requiredString(
      mediaPark["request"],
      "lifecycle.mediaParkResume.request"
    )
    try require(mediaParkRequest == "MediaParkRequest", "media park request must remain additive")
    let mediaParkResponse = try requiredString(
      mediaPark["response"],
      "lifecycle.mediaParkResume.response"
    )
    try require(mediaParkResponse == "MediaParkResult", "media park response must remain additive")
    let mediaParkStates = try requiredStringArray(
      mediaPark["states"],
      "lifecycle.mediaParkResume.states"
    )
    try require(
      mediaParkStates == ["active", "parking", "parked", "resuming"],
      "media park states must preserve the v4 state machine"
    )
    let mediaParkStrictlyIncreasingRevision = try requiredBool(
      mediaPark["strictlyIncreasingRevision"],
      "lifecycle.mediaParkResume.strictlyIncreasingRevision"
    )
    let mediaParkIdempotentCurrentTarget = try requiredBool(
      mediaPark["idempotentCurrentTarget"],
      "lifecycle.mediaParkResume.idempotentCurrentTarget"
    )
    try require(
      mediaParkStrictlyIncreasingRevision && mediaParkIdempotentCurrentTarget,
      "media park revisions and idempotency must remain fenced"
    )
    let mediaParkStaleResult = try requiredString(
      mediaPark["staleResult"],
      "lifecycle.mediaParkResume.staleResult"
    )
    try require(mediaParkStaleResult == "superseded", "stale media park revisions must be superseded")
    let mediaParkFreshBootstrap = try requiredBool(
      mediaPark["resumeRequiresFreshBootstrap"],
      "lifecycle.mediaParkResume.resumeRequiresFreshBootstrap"
    )
    try require(mediaParkFreshBootstrap, "media park revisions and resume bootstrap must remain fenced")
    let mediaParkStopFromParked = try requiredString(
      mediaPark["stopFromParked"],
      "lifecycle.mediaParkResume.stopFromParked"
    )
    try require(
      mediaParkStopFromParked == "SessionStopped",
      "stopping from PARKED must use SessionStopped"
    )
  }

  public static func checkCompatibility(baseline: [String: Any], current: [String: Any]) throws {
    try require(jsonEqual(baseline["identity"], current["identity"]), "v4 identity cannot change")
    let oldProto = try dictionary(baseline["protobuf"], "baseline.protobuf")
    let newProto = try dictionary(current["protobuf"], "current.protobuf")
    _ = try compareProtobuf(
      baseline: try requiredString(oldProto["source"], "baseline protobuf source"),
      current: try requiredString(newProto["source"], "current protobuf source")
    )

    let oldNative = try dictionary(baseline["nativeTransport"], "baseline.nativeTransport")
    let newNative = try dictionary(current["nativeTransport"], "current.nativeTransport")
    let additiveNativeLists = Set(["transportErrors", "packetArrivalFeedbackErrors"])
    for (key, value) in oldNative {
      guard let currentValue = newNative[key] else {
        throw LumenContractToolError.invalid("removed v4 native authority \(key)")
      }
      if additiveNativeLists.contains(key) {
        try requirePreservedList(value, in: currentValue, label: key)
      } else if key == "mediaCapabilities" {
        let oldCapabilities = try dictionary(value, "baseline.nativeTransport.mediaCapabilities")
        let newCapabilities = try dictionary(currentValue, "current.nativeTransport.mediaCapabilities")
        for (capabilityKey, capabilityValue) in oldCapabilities {
          guard let currentCapabilityValue = newCapabilities[capabilityKey] else {
            throw LumenContractToolError.invalid(
              "removed v4 native media capability \(capabilityKey)"
            )
          }
          if capabilityKey == "supportedMask" {
            let oldMask = try requiredInteger(
              capabilityValue,
              "baseline.nativeTransport.mediaCapabilities.supportedMask"
            )
            let newMask = try requiredInteger(
              currentCapabilityValue,
              "current.nativeTransport.mediaCapabilities.supportedMask"
            )
            try require(
              newMask & oldMask == oldMask,
              "v4 native media capability supportedMask removed a bit"
            )
          } else {
            try requirePreservedValue(
              capabilityValue,
              in: currentCapabilityValue,
              label: "v4 native media capability \(capabilityKey)"
            )
          }
        }
      } else {
        try requirePreservedValue(
          value, in: currentValue, label: "v4 native authority \(key)")
      }
    }

    if baseline["lifecycle"] != nil {
      try requirePreservedValue(
        baseline["lifecycle"], in: current["lifecycle"], label: "v4 lifecycle")
    }
    let oldHTTPS = try dictionary(baseline["https"], "baseline.https")
    let newHTTPS = try dictionary(current["https"], "current.https")
    let oldAuthentication = try dictionary(oldHTTPS["authentication"], "baseline.authentication")
    let newAuthentication = try dictionary(newHTTPS["authentication"], "current.authentication")
    try requirePreservedRoutes(
      oldAuthentication, in: newAuthentication, authority: "authentication")
    for (key, value) in oldAuthentication where key != "errorCodes" {
      try requirePreservedValue(value, in: newAuthentication[key], label: "authentication \(key)")
    }
    try requirePreservedList(
      oldAuthentication["errorCodes"] ?? [],
      in: newAuthentication["errorCodes"] ?? [],
      label: "authentication error code"
    )

    let oldSettings = try dictionary(oldHTTPS["settings"], "baseline.settings")
    let newSettings = try dictionary(newHTTPS["settings"], "current.settings")
    try requirePreservedRoutes(oldSettings, in: newSettings, authority: "settings")
    for (key, value) in oldSettings where key != "errorCodes" && key != "fields" {
      try requirePreservedValue(value, in: newSettings[key], label: "settings \(key)")
    }
    let oldFields = try indexedFields(oldSettings["fields"])
    let newFields = try indexedFields(newSettings["fields"])
    for (key, value) in oldFields {
      try requirePreservedValue(value, in: newFields[key], label: "settings field \(key)")
    }
    try requirePreservedList(
      oldSettings["errorCodes"] ?? [],
      in: newSettings["errorCodes"] ?? [],
      label: "settings error code"
    )
  }

  public static func compareDocumentation(baseline: String, current: String, label: String) throws {
    try require(baseline == current, "changed handwritten \(label) authority")
  }

  static func renderedSection(data: Data, path: [String]) throws -> Data {
    var parser = OrderedJSONParser(data: data)
    var value = try parser.parse()
    for component in path {
      guard case .object(let entries) = value,
        let child = entries.first(where: { $0.key == component })?.value
      else {
        throw LumenContractToolError.invalid(
          "missing ordered JSON section: \(path.joined(separator: "."))")
      }
      value = child
    }
    return Data((try value.rendered() + "\n").utf8)
  }

  static func renderedAPIReference(root: URL) throws -> Data {
    try renderedAPIReference(document: loadValidatedDocument(root: root))
  }

  static func apiReferenceInventory(root: URL) throws -> LumenAPIReferenceInventory {
    let document = try loadValidatedDocument(root: root)
    let protobuf = try dictionary(document.object["protobuf"], "protobuf")
    let descriptor = try compileProtobufDescriptor(
      source: try requiredString(protobuf["source"], "protobuf.source"),
      label: "API reference inventory"
    )
    return LumenAPIReferenceRenderer.inventory(descriptor)
  }

  private static func loadValidatedDocument(root: URL) throws -> ContractDocument {
    let data = try Data(contentsOf: root.appending(path: "docs/protocol/lumen-contract-v4.json"))
    let contract = try object(from: data)
    let schemaData = try Data(
      contentsOf: root.appending(path: "docs/protocol/lumen-contract-v4.schema.json"))
    let schema = try object(from: schemaData)
    try validateSchemaDocument(schema)
    try validateSchema(instance: contract, schema: schema, path: "$")
    try validate(contract)
    return ContractDocument(data: data, object: contract)
  }

  private static func runCompatibility(arguments: [String], root: URL) throws {
    let options = try CompatibilityOptions(arguments: arguments, root: root)
    let currentData = try Data(contentsOf: options.current)
    let current = try object(from: currentData)
    let newSchema = try object(from: Data(contentsOf: options.currentSchema))
    try validateSchemaDocument(newSchema)
    try validateSchema(instance: current, schema: newSchema, path: "$")
    try validate(current)
    let baseline: [String: Any]
    if let baselineURL = options.baseline {
      guard options.baselineStreamingDoc != nil,
        options.baselineSettingsDoc != nil
      else {
        throw LumenContractToolError.invalid(
          "structured v4 baseline requires streaming and settings documentation"
        )
      }
      baseline = try object(from: Data(contentsOf: baselineURL))
      guard let baselineSchema = options.baselineSchema else {
        throw LumenContractToolError.invalid("missing v4 baseline meta-schema")
      }
      let oldSchema = try object(from: Data(contentsOf: baselineSchema))
      try require(jsonEqual(oldSchema, newSchema), "v4 meta-schema cannot change")
    } else {
      guard let proto = options.baselineProto,
        let native = options.baselineNative,
        let auth = options.baselineAuth,
        let settings = options.baselineSettings
      else {
        throw LumenContractToolError.invalid(
          "missing legacy baseline: protobuf, native transport, authentication, settings"
        )
      }
      let identity = try dictionary(current["identity"], "current.identity")
      baseline = [
        "identity": identity,
        "protobuf": ["source": try String(contentsOf: proto, encoding: .utf8)],
        "nativeTransport": try object(from: Data(contentsOf: native)),
        "https": [
          "authentication": try object(from: Data(contentsOf: auth)),
          "settings": try object(from: Data(contentsOf: settings)),
        ],
      ]
    }
    let baselineProto = try requiredString(
      (baseline["protobuf"] as? [String: Any])?["source"],
      "baseline protobuf source"
    )
    let currentProto = try requiredString(
      (current["protobuf"] as? [String: Any])?["source"],
      "current protobuf source"
    )
    let protobufAuthorityChanged = try compareProtobuf(
      baseline: baselineProto,
      current: currentProto
    )
    try checkCompatibility(baseline: baseline, current: current)
    // Lifecycle and transport prose is a handwritten expansion of the
    // structured authorities. An additive machine-contract change may need to
    // introduce or reconcile that prose in the same release; keep the strict
    // byte-equality guard for documentation-only changes.
    let baselineNative = baseline["nativeTransport"] as? [String: Any]
    let currentNative = current["nativeTransport"] as? [String: Any]
    let baselineLifecycle = baseline["lifecycle"] as? [String: Any]
    let currentLifecycle = current["lifecycle"] as? [String: Any]
    let baselineMediaCapabilities = baselineNative?["mediaCapabilities"] as? [String: Any]
    let currentMediaCapabilities = currentNative?["mediaCapabilities"] as? [String: Any]
    let streamingAuthorityChanged = protobufAuthorityChanged
      || !jsonEqual(
        baselineMediaCapabilities?["supportedMask"],
        currentMediaCapabilities?["supportedMask"]
      )
      || !jsonEqual(
        baselineMediaCapabilities?["mediaParkResume"],
        currentMediaCapabilities?["mediaParkResume"]
      )
      || !jsonEqual(
        baselineLifecycle?["mediaParkResume"],
        currentLifecycle?["mediaParkResume"]
      )
    let settingsAuthorityChanged = !jsonEqual(
      (baseline["https"] as? [String: Any])?["settings"],
      (current["https"] as? [String: Any])?["settings"]
    )
    if let baseline = options.baselineStreamingDoc {
      if !streamingAuthorityChanged {
        try compareDocumentation(
          baseline: try String(contentsOf: baseline, encoding: .utf8),
          current: try String(contentsOf: options.currentStreamingDoc, encoding: .utf8),
          label: "streaming documentation"
        )
      }
    }
    if let baseline = options.baselineSettingsDoc {
      if !settingsAuthorityChanged {
        try compareDocumentation(
          baseline: try String(contentsOf: baseline, encoding: .utf8),
          current: try String(contentsOf: options.currentSettingsDoc, encoding: .utf8),
          label: "settings documentation"
        )
      }
    }
  }

  private static func publish(document: ContractDocument, root: URL, check: Bool) throws {
    let outputs = try expectedOutputs(document: document, root: root)
    if check {
      for (relative, expected) in outputs {
        let destination = root.appending(path: relative)
        try require(
          (try? Data(contentsOf: destination)) == expected,
          "generated contract drift: \(relative)"
        )
      }
      try runDescriptorGeneration(root: root, check: true)
      return
    }
    try publishWithRollback(outputs: outputs, root: root)
  }

  private static func expectedOutputs(document: ContractDocument, root: URL) throws -> [(
    String, Data
  )] {
    let contract = document.object
    let protobuf = try dictionary(contract["protobuf"], "protobuf")
    let proto = Data(try requiredString(protobuf["source"], "protobuf.source").utf8)
    let rendering = try dictionary(contract["rendering"], "rendering")
    let digest = SHA256.hash(data: document.data).map { String(format: "%02x", $0) }.joined()
    let generatedSwift = try generateSwiftProtobuf(proto: proto)
    return [
      ("docs/protocol/lumen-streaming-v4.proto", proto),
      ("docs/protocol/lumen-api-reference.md", try renderedAPIReference(document: document)),
      (
        "docs/protocol/lumen-native-transport-conformance.json",
        try renderedSection(data: document.data, path: ["nativeTransport"])
      ),
      (
        "docs/protocol/lumen-auth-conformance.json",
        try renderedSection(data: document.data, path: ["https", "authentication"])
      ),
      (
        "docs/protocol/lumen-settings-conformance.json",
        Data(try requiredString(rendering["settingsConformance"], "settings rendering").utf8)
      ),
      (
        "docs/protocol/lumen-contract-v4.manifest.json", Data(contractManifest(digest: digest).utf8)
      ),
      ("Sources/LumenClientContracts/LumenStreamingV4.pb.swift", generatedSwift),
      ("Sources/LumenClientContracts/Resources/lumen-contract-v4.json", document.data),
      (
        "Sources/LumenClientContracts/LumenContract.swift",
        Data(try swiftIdentitySource(contract: contract, digest: digest).utf8)
      ),
    ]
  }

  private static func renderedAPIReference(document: ContractDocument) throws -> Data {
    let protobuf = try dictionary(document.object["protobuf"], "protobuf")
    let descriptor = try compileProtobufDescriptor(
      source: try requiredString(protobuf["source"], "protobuf.source"),
      label: "API reference"
    )
    let digest = SHA256.hash(data: document.data).map { String(format: "%02x", $0) }.joined()
    return Data(
      try LumenAPIReferenceRenderer.render(
        contract: document.object,
        descriptor: descriptor,
        digest: digest
      ).utf8
    )
  }

  private static func publishWithRollback(outputs: [(String, Data)], root: URL) throws {
    let fileManager = FileManager.default
    let backupRoot = fileManager.temporaryDirectory.appending(
      path: "lumen-contract-backup-\(UUID().uuidString)")
    try fileManager.createDirectory(at: backupRoot, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: backupRoot) }

    var backups: [(destination: URL, backup: URL, existed: Bool)] = []
    for (index, output) in outputs.enumerated() {
      let destination = root.appending(path: output.0)
      let backup = backupRoot.appending(path: String(index))
      let existed = fileManager.fileExists(atPath: destination.path)
      if existed { try fileManager.copyItem(at: destination, to: backup) }
      backups.append((destination, backup, existed))
    }

    do {
      for (relative, data) in outputs {
        let destination = root.appending(path: relative)
        try fileManager.createDirectory(
          at: destination.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .atomic)
      }
      try runDescriptorGeneration(root: root, check: false)
    } catch {
      var rollbackFailure: Error?
      for item in backups.reversed() {
        do {
          if item.existed {
            let data = try Data(contentsOf: item.backup)
            try data.write(to: item.destination, options: .atomic)
          } else if fileManager.fileExists(atPath: item.destination.path) {
            try fileManager.removeItem(at: item.destination)
          }
        } catch {
          rollbackFailure = rollbackFailure ?? error
        }
      }
      if let rollbackFailure {
        throw LumenContractToolError.process(
          "generation failed and rollback was incomplete: \(error); rollback: \(rollbackFailure)"
        )
      }
      throw error
    }
  }

  private static func generateSwiftProtobuf(proto: Data) throws -> Data {
    let environment = ProcessInfo.processInfo.environment
    guard let compiler = environment["PROTOC_GEN_SWIFT"], !compiler.isEmpty else {
      throw LumenContractToolError.invalid(
        "PROTOC_GEN_SWIFT must name the pinned protoc-gen-swift binary"
      )
    }
    let temporary = FileManager.default.temporaryDirectory.appending(
      path: "lumen-contract-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    try proto.write(to: temporary.appending(path: "lumen-streaming-v4.proto"))
    try runProcess(
      "/usr/bin/env",
      [
        "protoc", "--plugin=protoc-gen-swift=\(compiler)", "--proto_path=\(temporary.path)",
        "--swift_out=Visibility=Public:\(temporary.path)", "lumen-streaming-v4.proto",
      ], root: temporary)
    return try Data(contentsOf: temporary.appending(path: "lumen-streaming-v4.pb.swift"))
  }

  private static func runDescriptorGeneration(root: URL, check: Bool) throws {
    try runProcess(
      root.appending(path: "tools/protocol/generate_lumen_streaming_v4.sh").path,
      [check ? "--check" : "write"],
      root: root
    )
  }

  private static func contractManifest(digest: String) -> String {
    """
    {
      "schemaVersion": 1,
      "contract": {
        "path": "docs/protocol/lumen-contract-v4.json",
        "sha256": "\(digest)"
      },
      "identity": {
        "name": "lumen-stream",
        "version": 4,
        "package": "lumen.streaming.v4",
        "alpn": "lumen-stream/4"
      },
      "generatedArtifacts": [
        "docs/protocol/lumen-streaming-v4.proto",
        "docs/protocol/lumen-streaming-v4.descriptor.pb",
        "docs/protocol/lumen-streaming-v4.sha256",
        "docs/protocol/lumen-native-transport-conformance.json",
        "docs/protocol/lumen-auth-conformance.json",
        "docs/protocol/lumen-settings-conformance.json",
        "docs/protocol/lumen-api-reference.md",
        "Sources/LumenClientContracts/LumenStreamingV4.pb.swift"
      ],
      "handwrittenRuntimeBoundary": {
        "status": "drift-gated",
        "path": "engine/lumen-engine/src/protocol",
        "note": "Runtime policy and validators remain handwritten and must pass descriptor and source contract gates."
      },
      "handwrittenDocumentationBoundary": {
        "status": "drift-gated",
        "paths": [
          "docs/protocol/lumen-streaming-protocol.md",
          "docs/protocol/lumen-settings-protocol.md"
        ],
        "note": "Complete lifecycle and policy prose remains handwritten until every semantic rule is represented structurally in the IDL."
      }
    }
    """ + "\n"
  }

  private static func swiftIdentitySource(contract: [String: Any], digest: String) throws -> String
  {
    let schemaVersion = try requiredInteger(contract["schemaVersion"], "schemaVersion")
    let identity = try dictionary(contract["identity"], "identity")
    let protocolVersion = try requiredInteger(identity["version"], "identity.version")
    let protocolName = try swiftStringLiteral(requiredString(identity["name"], "identity.name"))
    let protobufPackage = try swiftStringLiteral(
      requiredString(identity["package"], "identity.package"))
    let alpn = try swiftStringLiteral(requiredString(identity["alpn"], "identity.alpn"))
    let contractDigest = try swiftStringLiteral(digest)
    return """
      import Foundation

      public enum LumenContract {
          public static let schemaVersion: UInt32 = \(schemaVersion)
          public static let protocolVersion: UInt32 = \(protocolVersion)
          public static let protocolName = \(protocolName)
          public static let protobufPackage = \(protobufPackage)
          public static let alpn = \(alpn)
          public static let contractSHA256 = \(contractDigest)

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
      """ + "\n"
  }

  @discardableResult
  private static func compareProtobuf(baseline: String, current: String) throws -> Bool {
    guard baseline != current else { return false }
    let old = try compileProtobufDescriptor(source: baseline, label: "baseline")
    let new = try compileProtobufDescriptor(source: current, label: "current")
    try require(old.syntax == new.syntax, "changed protobuf syntax")
    try require(old.package == new.package, "changed protobuf package")
    try require(
      old.hasOptions == new.hasOptions && old.options == new.options,
      "changed protobuf file options"
    )
    try compareMessages(old.messageType, with: new.messageType, scope: old.package)
    try compareEnums(old.enumType, with: new.enumType, scope: old.package)
    try compareServices(old.service, with: new.service, scope: old.package)
    return try old.serializedData() != new.serializedData()
  }

  private static func compileProtobufDescriptor(source: String, label: String) throws
    -> Google_Protobuf_FileDescriptorProto
  {
    let fileManager = FileManager.default
    let temporary = fileManager.temporaryDirectory.appending(
      path: "lumen-contract-descriptor-\(UUID().uuidString)")
    try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: temporary) }
    let sourceName = "lumen-streaming-v4.proto"
    let sourceURL = temporary.appending(path: sourceName)
    let descriptorURL = temporary.appending(path: "lumen-contract.descriptor.pb")
    try Data(source.utf8).write(to: sourceURL, options: .atomic)
    do {
      try runProcess(
        "/usr/bin/env",
        [
          "protoc", "--proto_path=\(temporary.path)", "--include_imports",
          "--descriptor_set_out=\(descriptorURL.path)", sourceName,
        ],
        root: temporary
      )
      let data = try Data(contentsOf: descriptorURL)
      let descriptorSet = try Google_Protobuf_FileDescriptorSet(serializedBytes: data)
      guard let descriptor = descriptorSet.file.first(where: { $0.name == sourceName }) else {
        throw LumenContractToolError.invalid("\(label) protobuf descriptor is missing its source")
      }
      return descriptor
    } catch let error as LumenContractToolError {
      throw error
    } catch {
      throw LumenContractToolError.invalid("failed to read \(label) protobuf descriptor: \(error)")
    }
  }

  private static func compareMessages(
    _ baseline: [Google_Protobuf_DescriptorProto],
    with current: [Google_Protobuf_DescriptorProto],
    scope: String
  ) throws {
    let currentMessages = Dictionary(uniqueKeysWithValues: current.map { ($0.name, $0) })
    for message in baseline {
      let path = qualifiedName(scope, message.name)
      guard let candidate = currentMessages[message.name] else {
        throw LumenContractToolError.invalid("removed protobuf message: \(path)")
      }
      try compareMessage(message, with: candidate, path: path)
    }
  }

  private static func compareMessage(
    _ baseline: Google_Protobuf_DescriptorProto,
    with current: Google_Protobuf_DescriptorProto,
    path: String
  ) throws {
    try require(
      baseline.options == current.options && baseline.hasOptions == current.hasOptions,
      "changed protobuf message options: \(path)"
    )
    let oldOneofs = baseline.oneofDecl.map(\.name)
    let newOneofs = current.oneofDecl.map(\.name)
    try require(
      Set(oldOneofs).isSubset(of: Set(newOneofs)),
      "removed protobuf oneof: \(path)"
    )
    let newOneofDefinitions = Dictionary(
      uniqueKeysWithValues: current.oneofDecl.map { ($0.name, $0) })
    for oneof in baseline.oneofDecl {
      guard let candidate = newOneofDefinitions[oneof.name] else {
        throw LumenContractToolError.invalid("removed protobuf oneof: \(path).\(oneof.name)")
      }
      try require(
        oneof.hasOptions == candidate.hasOptions && oneof.options == candidate.options,
        "changed protobuf oneof options: \(path).\(oneof.name)"
      )
    }
    let currentFields = Dictionary(uniqueKeysWithValues: current.field.map { ($0.number, $0) })
    for field in baseline.field {
      guard let candidate = currentFields[field.number] else {
        throw LumenContractToolError.invalid(
          "removed protobuf field: \(path).\(field.name)=\(field.number)")
      }
      let oldOneof = try oneofName(for: field, declarations: oldOneofs, path: path)
      let newOneof = try oneofName(for: candidate, declarations: newOneofs, path: path)
      try require(
        field.name == candidate.name
          && field.label == candidate.label
          && field.type == candidate.type
          && field.typeName == candidate.typeName
          && field.extendee == candidate.extendee
          && field.defaultValue == candidate.defaultValue
          && field.jsonName == candidate.jsonName
          && field.proto3Optional == candidate.proto3Optional
          && field.hasOptions == candidate.hasOptions
          && field.options == candidate.options
          && oldOneof == newOneof,
        "removed, reused, or changed protobuf field \(path).\(field.number)"
      )
    }
    try requireRangesPreserved(
      baseline.reservedRange.map { Int64($0.start)..<Int64($0.end) },
      in: current.reservedRange.map { Int64($0.start)..<Int64($0.end) },
      label: "protobuf message reservation \(path)"
    )
    try require(
      Set(baseline.reservedName).isSubset(of: Set(current.reservedName)),
      "removed protobuf reserved name: \(path)"
    )
    try compareMessages(baseline.nestedType, with: current.nestedType, scope: path)
    try compareEnums(baseline.enumType, with: current.enumType, scope: path)
  }

  private static func compareEnums(
    _ baseline: [Google_Protobuf_EnumDescriptorProto],
    with current: [Google_Protobuf_EnumDescriptorProto],
    scope: String
  ) throws {
    let currentEnums = Dictionary(uniqueKeysWithValues: current.map { ($0.name, $0) })
    for enumeration in baseline {
      let path = qualifiedName(scope, enumeration.name)
      guard let candidate = currentEnums[enumeration.name] else {
        throw LumenContractToolError.invalid("removed protobuf enum: \(path)")
      }
      try require(
        enumeration.options == candidate.options
          && enumeration.hasOptions == candidate.hasOptions,
        "changed protobuf enum options: \(path)"
      )
      for value in enumeration.value {
        guard
          let candidateValue = candidate.value.first(where: {
            $0.name == value.name && $0.number == value.number
          })
        else {
          throw LumenContractToolError.invalid(
            "removed or changed protobuf enum value \(path).\(value.name)=\(value.number)"
          )
        }
        try require(
          value.hasOptions == candidateValue.hasOptions && value.options == candidateValue.options,
          "changed protobuf enum value options \(path).\(value.name)=\(value.number)"
        )
      }
      try requireRangesPreserved(
        enumeration.reservedRange.map {
          Int64($0.start)..<Int64($0.end) + 1
        },
        in: candidate.reservedRange.map {
          Int64($0.start)..<Int64($0.end) + 1
        },
        label: "protobuf enum reservation \(path)"
      )
      try require(
        Set(enumeration.reservedName).isSubset(of: Set(candidate.reservedName)),
        "removed protobuf reserved enum name: \(path)"
      )
    }
  }

  private static func compareServices(
    _ baseline: [Google_Protobuf_ServiceDescriptorProto],
    with current: [Google_Protobuf_ServiceDescriptorProto],
    scope: String
  ) throws {
    let currentServices = Dictionary(uniqueKeysWithValues: current.map { ($0.name, $0) })
    for service in baseline {
      let path = qualifiedName(scope, service.name)
      guard let candidate = currentServices[service.name] else {
        throw LumenContractToolError.invalid("removed protobuf service: \(path)")
      }
      try require(
        service.options == candidate.options && service.hasOptions == candidate.hasOptions,
        "changed protobuf service options: \(path)"
      )
      let currentMethods = Dictionary(uniqueKeysWithValues: candidate.method.map { ($0.name, $0) })
      for method in service.method {
        guard let currentMethod = currentMethods[method.name] else {
          throw LumenContractToolError.invalid(
            "removed protobuf service method: \(path).\(method.name)")
        }
        try require(
          method.inputType == currentMethod.inputType
            && method.outputType == currentMethod.outputType
            && method.clientStreaming == currentMethod.clientStreaming
            && method.serverStreaming == currentMethod.serverStreaming
            && method.hasOptions == currentMethod.hasOptions
            && method.options == currentMethod.options,
          "changed protobuf service method: \(path).\(method.name)"
        )
      }
    }
  }

  private static func oneofName(
    for field: Google_Protobuf_FieldDescriptorProto,
    declarations: [String],
    path: String
  ) throws -> String? {
    guard field.hasOneofIndex else { return nil }
    let index = Int(field.oneofIndex)
    guard declarations.indices.contains(index) else {
      throw LumenContractToolError.invalid("invalid protobuf oneof index: \(path).\(field.name)")
    }
    return declarations[index]
  }

  private static func requireRangesPreserved(
    _ baseline: [Range<Int64>],
    in current: [Range<Int64>],
    label: String
  ) throws {
    for oldRange in baseline {
      try require(
        current.contains(where: {
          $0.lowerBound <= oldRange.lowerBound && $0.upperBound >= oldRange.upperBound
        }),
        "removed \(label): \(oldRange.lowerBound)..<\(oldRange.upperBound)"
      )
    }
  }

  private static func qualifiedName(_ scope: String, _ name: String) -> String {
    scope.isEmpty ? name : "\(scope).\(name)"
  }

  private static func requirePreservedRoutes(
    _ baseline: [String: Any],
    in current: [String: Any],
    authority: String
  ) throws {
    let oldRoutes = try nestedRoutes(baseline)
    let newRoutes = try nestedRoutes(current)
    for (route, definition) in oldRoutes {
      try require(
        jsonEqual(definition, newRoutes[route]),
        "removed or changed \(authority) route: \(route.method) \(route.path)"
      )
    }
  }

  private static func nestedRoutes(_ value: Any) throws -> [Route: Any] {
    var routes: [Route: Any] = [:]
    if let dictionary = value as? [String: Any] {
      if let method = dictionary["method"] as? String, let path = dictionary["path"] as? String {
        routes[Route(method: method, path: path)] = dictionary
      }
      for child in dictionary.values { routes.merge(try nestedRoutes(child)) { _, new in new } }
    } else if let array = value as? [Any] {
      for child in array { routes.merge(try nestedRoutes(child)) { _, new in new } }
    }
    return routes
  }

  private static func requirePreservedList(_ baseline: Any, in current: Any, label: String) throws {
    guard let old = baseline as? [Any], let new = current as? [Any] else {
      throw LumenContractToolError.invalid("\(label) must be a list")
    }
    for value in old {
      try require(new.contains(where: { jsonEqual(value, $0) }), "removed \(label)")
    }
  }

  private static func requirePreservedValue(_ baseline: Any?, in current: Any?, label: String)
    throws
  {
    guard let baseline, let current else {
      throw LumenContractToolError.invalid("removed \(label)")
    }
    if let old = baseline as? [String: Any] {
      guard let new = current as? [String: Any] else {
        throw LumenContractToolError.invalid("changed \(label) type")
      }
      for (key, value) in old {
        try requirePreservedValue(value, in: new[key], label: "\(label).\(key)")
      }
      return
    }
    try require(jsonEqual(baseline, current), "changed \(label)")
  }

  private static func indexedFields(_ value: Any?) throws -> [String: Any] {
    guard let values = value as? [[String: Any]] else {
      throw LumenContractToolError.invalid("settings fields must be a list of objects")
    }
    var result: [String: Any] = [:]
    var orders = Set<Int>()
    for field in values {
      let key = try requiredString(field["key"], "settings field key")
      try require(!key.isEmpty, "settings field key cannot be empty")
      try require(result[key] == nil, "duplicate settings field key: \(key)")
      let order = try requiredInteger(field["order"], "settings field order for \(key)")
      try require(orders.insert(order).inserted, "duplicate settings field order: \(order)")
      result[key] = field
    }
    return result
  }

  private static func validateRendering(
    _ raw: Any?, equals structured: [String: Any], label: String
  ) throws {
    let value = try requiredString(raw, "\(label) rendering")
    let rendered = try object(from: Data(value.utf8))
    try require(
      jsonEqual(rendered, structured), "\(label) rendering does not match structured authority")
  }

  static func validateSchema(instance: Any, schema: [String: Any], path: String) throws {
    if let constant = schema["const"] {
      try require(jsonEqual(instance, constant), "schema const mismatch at \(path)")
    }

    if let type = schema["type"] {
      let expected = try requiredString(type, "schema type at \(path)")
      try require(matchesJSONType(instance, expected), "schema type mismatch at \(path)")
    }

    if let minimumLength = schema["minLength"] {
      let minimum = try requiredInteger(minimumLength, "schema minLength at \(path)")
      guard let value = instance as? String else {
        throw LumenContractToolError.invalid("schema minLength requires a string at \(path)")
      }
      try require(value.unicodeScalars.count >= minimum, "schema minLength mismatch at \(path)")
    }

    guard let propertiesValue = schema["properties"] else { return }
    let properties = try dictionary(propertiesValue, "schema properties at \(path)")
    let object = try dictionary(instance, "contract value at \(path)")

    if let requiredValue = schema["required"] {
      guard let required = requiredValue as? [String] else {
        throw LumenContractToolError.invalid("schema required must be a string array at \(path)")
      }
      let missing = Set(required).subtracting(object.keys)
      try require(
        missing.isEmpty,
        "schema required property missing at \(path): \(missing.sorted().joined(separator: ", "))"
      )
    }

    if schema["additionalProperties"] as? Bool == false {
      let unexpected = Set(object.keys).subtracting(properties.keys)
      try require(
        unexpected.isEmpty,
        "schema additional property at \(path): \(unexpected.sorted().joined(separator: ", "))"
      )
    }

    for (key, childSchemaValue) in properties {
      guard let child = object[key] else { continue }
      let childSchema = try dictionary(childSchemaValue, "schema property \(path).\(key)")
      try validateSchema(instance: child, schema: childSchema, path: "\(path).\(key)")
    }
  }

  private static func validateSchemaDocument(_ schema: [String: Any]) throws {
    try require(
      string(schema["$schema"]) == "https://json-schema.org/draft/2020-12/schema",
      "unsupported contract meta-schema dialect"
    )
    try require(
      string(schema["$id"]) == "https://lumen.skyline23.com/schemas/contract-v1.json",
      "invalid contract meta-schema identity"
    )
    try validateSchemaDefinition(schema, path: "$")
  }

  private static func validateSchemaDefinition(_ schema: [String: Any], path: String) throws {
    let supportedKeywords = Set([
      "$schema", "$id", "title", "type", "additionalProperties", "required", "properties",
      "const", "minLength",
    ])
    let unsupported = Set(schema.keys).subtracting(supportedKeywords)
    try require(
      unsupported.isEmpty,
      "unsupported meta-schema keyword at \(path): \(unsupported.sorted().joined(separator: ", "))"
    )

    if let type = schema["type"] {
      let value = try requiredString(type, "schema type at \(path)")
      try require(
        ["object", "array", "string", "number", "integer", "boolean", "null"].contains(value),
        "unsupported schema type at \(path): \(value)"
      )
    }
    if let additionalProperties = schema["additionalProperties"] {
      try require(
        additionalProperties is Bool,
        "schema additionalProperties must be boolean at \(path)"
      )
    }
    if let required = schema["required"] {
      guard let values = required as? [String], Set(values).count == values.count else {
        throw LumenContractToolError.invalid(
          "schema required must contain unique strings at \(path)")
      }
    }
    if let minimumLength = schema["minLength"] {
      let value = try requiredInteger(minimumLength, "schema minLength at \(path)")
      try require(value >= 0, "schema minLength cannot be negative at \(path)")
    }
    if let propertiesValue = schema["properties"] {
      let properties = try dictionary(propertiesValue, "schema properties at \(path)")
      for (key, childValue) in properties {
        let child = try dictionary(childValue, "schema property \(path).\(key)")
        try validateSchemaDefinition(child, path: "\(path).\(key)")
      }
    }
  }

  private static func matchesJSONType(_ value: Any, _ type: String) -> Bool {
    switch type {
    case "object": return value is [String: Any]
    case "array": return value is [Any]
    case "string": return value is String
    case "integer": return number(value) != nil
    case "number":
      guard let value = value as? NSNumber else { return false }
      return CFGetTypeID(value) != CFBooleanGetTypeID()
    case "boolean": return value is Bool
    case "null": return value is NSNull
    default: return false
    }
  }

  private static func object(from data: Data) throws -> [String: Any] {
    var parser = OrderedJSONParser(data: data)
    _ = try parser.parse()
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw LumenContractToolError.invalid("contract must be a JSON object")
    }
    return value
  }

  private static func dictionary(_ value: Any?, _ label: String) throws -> [String: Any] {
    guard let value = value as? [String: Any] else {
      throw LumenContractToolError.invalid("\(label) must be an object")
    }
    return value
  }

  private static func requireKeys(_ value: [String: Any], _ keys: Set<String>, _ label: String)
    throws -> [String: Any]
  {
    let missing = keys.subtracting(value.keys)
    try require(missing.isEmpty, "\(label) is missing: \(missing.sorted().joined(separator: ", "))")
    let unexpected = Set(value.keys).subtracting(keys)
    try require(
      unexpected.isEmpty,
      "\(label) contains unknown keys: \(unexpected.sorted().joined(separator: ", "))"
    )
    return value
  }

  private static func string(_ value: Any?) -> String? { value as? String }

  private static func requiredString(_ value: Any?, _ label: String) throws -> String {
    guard let value = value as? String else {
      throw LumenContractToolError.invalid("\(label) must be a string")
    }
    return value
  }

  private static func requiredInteger(_ value: Any?, _ label: String) throws -> Int {
    guard let value = number(value) else {
      throw LumenContractToolError.invalid("\(label) must be an integer")
    }
    return value
  }

  private static func requiredBool(_ value: Any?, _ label: String) throws -> Bool {
    guard let value = value as? Bool else {
      throw LumenContractToolError.invalid("\(label) must be a boolean")
    }
    return value
  }

  private static func requiredStringArray(_ value: Any?, _ label: String) throws -> [String] {
    guard let values = value as? [Any] else {
      throw LumenContractToolError.invalid("\(label) must be an array of strings")
    }
    return try values.enumerated().map { index, value in
      try requiredString(value, "\(label)[\(index)]")
    }
  }

  private static func number(_ value: Any?) -> Int? {
    guard let value = value as? NSNumber,
      CFGetTypeID(value) != CFBooleanGetTypeID(),
      !CFNumberIsFloatType(value)
    else { return nil }
    return Int(exactly: value.int64Value)
  }

  private static func numbers(_ value: Any?) -> [Int]? {
    guard let values = value as? [Any] else { return nil }
    let result = values.compactMap(number)
    return result.count == values.count ? result : nil
  }

  private static func swiftStringLiteral(_ value: String) throws -> String {
    try OrderedJSON.string(value).rendered()
  }

  private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw LumenContractToolError.invalid(message) }
  }

  private static func jsonEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
    guard let lhs, let rhs,
      JSONSerialization.isValidJSONObject([lhs]), JSONSerialization.isValidJSONObject([rhs])
    else { return false }
    let options: JSONSerialization.WritingOptions = [.sortedKeys]
    return (try? JSONSerialization.data(withJSONObject: [lhs], options: options))
      == (try? JSONSerialization.data(withJSONObject: [rhs], options: options))
  }

  private static func runProcess(_ executable: String, _ arguments: [String], root: URL) throws {
    let fileManager = FileManager.default
    let outputURL = fileManager.temporaryDirectory.appending(
      path: "lumen-contract-process-\(UUID().uuidString).log")
    guard fileManager.createFile(atPath: outputURL.path, contents: nil),
      let output = try? FileHandle(forWritingTo: outputURL)
    else {
      throw LumenContractToolError.process("unable to create subprocess log")
    }
    defer {
      try? output.close()
      try? fileManager.removeItem(at: outputURL)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = root
    process.standardOutput = output
    process.standardError = output
    do {
      try process.run()
    } catch {
      throw LumenContractToolError.process(
        "failed to start process: \(executable) \(arguments.joined(separator: " ")): \(error)"
      )
    }
    process.waitUntilExit()
    try? output.synchronize()
    if process.terminationStatus != 0 {
      let captured = (try? String(contentsOf: outputURL, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let outcome =
        process.terminationReason == .uncaughtSignal
        ? "signal \(process.terminationStatus)" : "exit \(process.terminationStatus)"
      let details = captured.flatMap { $0.isEmpty ? nil : $0 }.map { "\n\($0)" } ?? ""
      throw LumenContractToolError.process(
        "process failed (\(outcome)): \(executable) \(arguments.joined(separator: " "))\(details)"
      )
    }
  }
}

private struct ContractDocument {
  let data: Data
  let object: [String: Any]
}

private struct CompatibilityOptions {
  var baseline: URL?
  var baselineSchema: URL?
  var baselineProto: URL?
  var baselineNative: URL?
  var baselineAuth: URL?
  var baselineSettings: URL?
  var baselineStreamingDoc: URL?
  var baselineSettingsDoc: URL?
  var current: URL
  var currentSchema: URL
  var currentStreamingDoc: URL
  var currentSettingsDoc: URL

  init(arguments: [String], root: URL) throws {
    current = root.appending(path: "docs/protocol/lumen-contract-v4.json")
    currentSchema = root.appending(path: "docs/protocol/lumen-contract-v4.schema.json")
    currentStreamingDoc = root.appending(path: "docs/protocol/lumen-streaming-protocol.md")
    currentSettingsDoc = root.appending(path: "docs/protocol/lumen-settings-protocol.md")
    var index = 0
    while index < arguments.count {
      guard index + 1 < arguments.count else { throw LumenContractToolError.usage }
      let value = URL(fileURLWithPath: arguments[index + 1], relativeTo: root).standardizedFileURL
      switch arguments[index] {
      case "--baseline": baseline = value
      case "--baseline-schema": baselineSchema = value
      case "--baseline-proto": baselineProto = value
      case "--baseline-native": baselineNative = value
      case "--baseline-auth": baselineAuth = value
      case "--baseline-settings": baselineSettings = value
      case "--baseline-streaming-doc": baselineStreamingDoc = value
      case "--baseline-settings-doc": baselineSettingsDoc = value
      case "--current": current = value
      case "--current-schema": currentSchema = value
      case "--current-streaming-doc": currentStreamingDoc = value
      case "--current-settings-doc": currentSettingsDoc = value
      default: throw LumenContractToolError.usage
      }
      index += 2
    }
    if baseline != nil
      && [baselineProto, baselineNative, baselineAuth, baselineSettings].contains(where: {
        $0 != nil
      })
    {
      throw LumenContractToolError.usage
    }
    if baseline == nil && baselineSchema != nil {
      throw LumenContractToolError.usage
    }
    if baseline != nil && baselineSchema == nil {
      throw LumenContractToolError.usage
    }
  }
}

private struct Route: Hashable {
  let method: String
  let path: String
}

private indirect enum OrderedJSON {
  case object([(key: String, value: OrderedJSON)])
  case array([OrderedJSON])
  case string(String)
  case number(String)
  case bool(Bool)
  case null

  func rendered(level: Int = 0) throws -> String {
    switch self {
    case .object(let entries):
      guard !entries.isEmpty else { return "{}" }
      let indent = String(repeating: " ", count: level + 2)
      let closing = String(repeating: " ", count: level)
      let body = try entries.map { entry in
        "\(indent)\(try OrderedJSON.string(entry.key).rendered()): \(try entry.value.rendered(level: level + 2))"
      }.joined(separator: ",\n")
      return "{\n\(body)\n\(closing)}"
    case .array(let values):
      guard !values.isEmpty else { return "[]" }
      let indent = String(repeating: " ", count: level + 2)
      let closing = String(repeating: " ", count: level)
      let body = try values.map { "\(indent)\(try $0.rendered(level: level + 2))" }
        .joined(separator: ",\n")
      return "[\n\(body)\n\(closing)]"
    case .string(let value):
      let data = try JSONSerialization.data(
        withJSONObject: value,
        options: [.fragmentsAllowed, .withoutEscapingSlashes]
      )
      return String(decoding: data, as: UTF8.self)
    case .number(let value): return value
    case .bool(let value): return value ? "true" : "false"
    case .null: return "null"
    }
  }
}

private struct OrderedJSONParser {
  let bytes: [UInt8]
  var index = 0

  init(data: Data) {
    bytes = Array(data)
  }

  mutating func parse() throws -> OrderedJSON {
    skipWhitespace()
    let value = try parseValue()
    skipWhitespace()
    guard index == bytes.count else { throw invalidJSON() }
    return value
  }

  private mutating func parseValue() throws -> OrderedJSON {
    guard index < bytes.count else { throw invalidJSON() }
    switch bytes[index] {
    case 0x7B: return try parseObject()
    case 0x5B: return try parseArray()
    case 0x22: return .string(try parseString())
    case 0x74:
      try consume("true")
      return .bool(true)
    case 0x66:
      try consume("false")
      return .bool(false)
    case 0x6E:
      try consume("null")
      return .null
    default: return try parseNumber()
    }
  }

  private mutating func parseObject() throws -> OrderedJSON {
    index += 1
    skipWhitespace()
    var entries: [(key: String, value: OrderedJSON)] = []
    if consumeIf(0x7D) { return .object(entries) }
    while true {
      guard index < bytes.count, bytes[index] == 0x22 else { throw invalidJSON() }
      let key = try parseString()
      guard !entries.contains(where: { $0.key == key }) else { throw invalidJSON() }
      skipWhitespace()
      guard consumeIf(0x3A) else { throw invalidJSON() }
      skipWhitespace()
      entries.append((key, try parseValue()))
      skipWhitespace()
      if consumeIf(0x7D) { return .object(entries) }
      guard consumeIf(0x2C) else { throw invalidJSON() }
      skipWhitespace()
    }
  }

  private mutating func parseArray() throws -> OrderedJSON {
    index += 1
    skipWhitespace()
    var values: [OrderedJSON] = []
    if consumeIf(0x5D) { return .array(values) }
    while true {
      values.append(try parseValue())
      skipWhitespace()
      if consumeIf(0x5D) { return .array(values) }
      guard consumeIf(0x2C) else { throw invalidJSON() }
      skipWhitespace()
    }
  }

  private mutating func parseString() throws -> String {
    let start = index
    index += 1
    while index < bytes.count {
      if bytes[index] == 0x5C {
        index += 2
        continue
      }
      if bytes[index] == 0x22 {
        index += 1
        let data = Data(bytes[start..<index])
        guard
          let value = try JSONSerialization.jsonObject(
            with: data,
            options: .fragmentsAllowed
          ) as? String
        else { throw invalidJSON() }
        return value
      }
      index += 1
    }
    throw invalidJSON()
  }

  private mutating func parseNumber() throws -> OrderedJSON {
    let start = index
    while index < bytes.count, "-+0123456789.eE".utf8.contains(bytes[index]) { index += 1 }
    guard index > start else { throw invalidJSON() }
    let value = String(decoding: bytes[start..<index], as: UTF8.self)
    guard
      value.range(
        of: #"^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$"#,
        options: .regularExpression
      ) != nil
    else { throw invalidJSON() }
    return .number(value)
  }

  private mutating func consume(_ value: String) throws {
    let expected = Array(value.utf8)
    guard index + expected.count <= bytes.count,
      Array(bytes[index..<index + expected.count]) == expected
    else { throw invalidJSON() }
    index += expected.count
  }

  private mutating func consumeIf(_ value: UInt8) -> Bool {
    guard index < bytes.count, bytes[index] == value else { return false }
    index += 1
    return true
  }

  private mutating func skipWhitespace() {
    while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
  }

  private func invalidJSON() -> LumenContractToolError {
    .invalid("invalid JSON near byte \(index)")
  }
}
