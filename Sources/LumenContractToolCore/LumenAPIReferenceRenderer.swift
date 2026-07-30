import CoreFoundation
import Foundation
import SwiftProtobuf

struct LumenAPIReferenceInventory: Equatable {
  let enumNames: [String]
  let enumValueNames: [String]
  let messageNames: [String]
  let fieldNames: [String]
  let serviceNames: [String]
  let explicitOneofNames: [String]
  let syntheticOneofNames: [String]
}

enum LumenAPIReferenceRenderer {
  static func render(
    contract: [String: Any],
    descriptor: Google_Protobuf_FileDescriptorProto,
    digest: String
  ) throws -> String {
    let identity = try object(contract["identity"], label: "identity")
    let nativeTransport = try object(contract["nativeTransport"], label: "nativeTransport")
    let https = try object(contract["https"], label: "https")
    let authentication = try object(https["authentication"], label: "https.authentication")
    let settings = try object(https["settings"], label: "https.settings")
    let lifecycle = try object(contract["lifecycle"], label: "lifecycle")
    let schemaVersion = try integer(contract["schemaVersion"], label: "schemaVersion")

    var lines = [
      "# Lumen v4 API reference",
      "",
      "> Generated file. Do not edit it directly. Change `docs/protocol/lumen-contract-v4.json` and run `lumen-contract-tool generate`.",
      "",
      "- Contract SHA-256: `\(digest)`",
      "- Contract schema version: `\(schemaVersion)`",
      "- Protobuf source: `docs/protocol/lumen-streaming-v4.proto`",
      "- Descriptor source name: `\(descriptor.name)`",
      "- Swift module: `LumenClientContracts`",
      "",
      "## Identity",
      "",
      "| Authority | Value |",
      "| --- | --- |",
      "| Protocol | \(code(try string(identity["name"], label: "identity.name"))) |",
      "| Version | \(code(try integer(identity["version"], label: "identity.version"))) |",
      "| Protobuf package | \(code(try string(identity["package"], label: "identity.package"))) |",
      "| QUIC ALPN | \(code(try string(identity["alpn"], label: "identity.alpn"))) |",
      "",
      "## Swift package consumption",
      "",
      "`LumenClientContracts` publishes the generated SwiftProtobuf enums and value-type message structs listed below, together with the bundled contract authority. Applications construct their transport, authentication, settings, and session services in their composition root and pass those services through initializer injection. The generated package defines the wire contract; it does not hide or globally construct a QUIC runtime.",
      "",
    ]

    renderProtobuf(descriptor, into: &lines)
    try renderNativeTransport(nativeTransport, into: &lines)
    try renderAuthentication(authentication, into: &lines)
    try renderSettings(settings, into: &lines)
    try renderLifecycle(lifecycle, into: &lines)
    renderLimitations(into: &lines)
    renderImplementationChecklist(into: &lines)
    return lines.joined(separator: "\n")
  }

  static func inventory(
    _ descriptor: Google_Protobuf_FileDescriptorProto
  ) -> LumenAPIReferenceInventory {
    var enumNames: [String] = []
    var enumValueNames: [String] = []
    var messageNames: [String] = []
    var fieldNames: [String] = []
    var explicitOneofNames: [String] = []
    var syntheticOneofNames: [String] = []

    func visitEnum(_ enumeration: Google_Protobuf_EnumDescriptorProto, scope: String) {
      let name = qualified(scope, enumeration.name)
      enumNames.append(name)
      enumValueNames.append(contentsOf: enumeration.value.map { "\(name).\($0.name)" })
    }

    func visitMessage(_ message: Google_Protobuf_DescriptorProto, scope: String) {
      let name = qualified(scope, message.name)
      messageNames.append(name)
      fieldNames.append(contentsOf: message.field.map { "\(name).\($0.name)" })
      for (index, oneof) in message.oneofDecl.enumerated() {
        let oneofName = "\(name).\(oneof.name)"
        if isSyntheticOneof(index: index, in: message) {
          syntheticOneofNames.append(oneofName)
        } else {
          explicitOneofNames.append(oneofName)
        }
      }
      for enumeration in message.enumType {
        visitEnum(enumeration, scope: name)
      }
      for nested in message.nestedType {
        visitMessage(nested, scope: name)
      }
    }

    for enumeration in descriptor.enumType {
      visitEnum(enumeration, scope: descriptor.package)
    }
    for message in descriptor.messageType {
      visitMessage(message, scope: descriptor.package)
    }
    return LumenAPIReferenceInventory(
      enumNames: enumNames,
      enumValueNames: enumValueNames,
      messageNames: messageNames,
      fieldNames: fieldNames,
      serviceNames: descriptor.service.map { qualified(descriptor.package, $0.name) },
      explicitOneofNames: explicitOneofNames,
      syntheticOneofNames: syntheticOneofNames
    )
  }

  private static func renderProtobuf(
    _ descriptor: Google_Protobuf_FileDescriptorProto,
    into lines: inout [String]
  ) {
    let inventory = inventory(descriptor)
    let dependencies =
      descriptor.dependency.isEmpty
      ? "none" : descriptor.dependency.map(code).joined(separator: ", ")
    lines.append(contentsOf: [
      "## Protobuf API",
      "",
      "The following declarations are read from the compiled descriptor, not parsed from source text.",
      "",
      "| File property | Value |",
      "| --- | --- |",
      "| Syntax | \(code(descriptor.syntax)) |",
      "| Package | \(code(descriptor.package)) |",
      "| Dependencies | \(dependencies) |",
      "",
      "| Declaration kind | Count |",
      "| --- | ---: |",
      "| Enums | \(inventory.enumNames.count) |",
      "| Enum values | \(inventory.enumValueNames.count) |",
      "| Messages | \(inventory.messageNames.count) |",
      "| Services | \(inventory.serviceNames.count) |",
      "| Message fields | \(inventory.fieldNames.count) |",
      "| Explicit oneofs | \(inventory.explicitOneofNames.count) |",
      "| Synthetic optional oneofs | \(inventory.syntheticOneofNames.count) |",
      "",
    ])

    for enumeration in descriptor.enumType {
      renderEnum(enumeration, scope: descriptor.package, into: &lines)
    }
    for message in descriptor.messageType {
      renderMessage(message, scope: descriptor.package, into: &lines)
    }
    for service in descriptor.service {
      renderService(service, scope: descriptor.package, into: &lines)
    }
  }

  private static func renderEnum(
    _ enumeration: Google_Protobuf_EnumDescriptorProto,
    scope: String,
    into lines: inout [String]
  ) {
    let name = qualified(scope, enumeration.name)
    lines.append(contentsOf: [
      "### enum `\(name)`",
      "",
      "| Name | Number |",
      "| --- | ---: |",
    ])
    for value in enumeration.value {
      lines.append("| \(code("\(name).\(value.name)")) | \(value.number) |")
    }
    if !enumeration.reservedRange.isEmpty || !enumeration.reservedName.isEmpty {
      lines.append("")
      let ranges = enumeration.reservedRange.map { "\($0.start)...\($0.end)" }
      if !ranges.isEmpty {
        lines.append("Reserved numbers: \(ranges.map(code).joined(separator: ", ")).")
      }
      if !enumeration.reservedName.isEmpty {
        lines.append(
          "Reserved names: \(enumeration.reservedName.map(code).joined(separator: ", ")).")
      }
    }
    lines.append("")
  }

  private static func renderMessage(
    _ message: Google_Protobuf_DescriptorProto,
    scope: String,
    into lines: inout [String]
  ) {
    let name = qualified(scope, message.name)
    let kind = message.options.mapEntry ? "map-entry message" : "message"
    lines.append(contentsOf: [
      "### \(kind) `\(name)`",
      "",
      "| Tag | Protobuf field | JSON field | Label | Type kind | Type name | Oneof | Proto3 optional |",
      "| ---: | --- | --- | --- | --- | --- | --- | --- |",
    ])
    if message.field.isEmpty {
      lines.append("| — | — | — | — | — | — | — | — |")
    } else {
      for field in message.field {
        let oneof = fieldOneof(field, in: message).map(code) ?? "—"
        let typeName = field.hasTypeName ? code(trimmedTypeName(field.typeName)) : "—"
        lines.append(
          "| \(field.number) | \(code("\(name).\(field.name)")) | \(code(field.jsonName)) | \(fieldLabel(field)) | \(code(fieldTypeKind(field))) | \(typeName) | \(oneof) | \(field.proto3Optional ? "yes" : "no") |"
        )
      }
    }
    if !message.oneofDecl.isEmpty {
      lines.append(contentsOf: [
        "",
        "Oneof declarations:",
        "",
        "| Name | Kind | Members |",
        "| --- | --- | --- |",
      ])
      for (index, oneof) in message.oneofDecl.enumerated() {
        let members = message.field.compactMap { field -> String? in
          guard field.hasOneofIndex, Int(field.oneofIndex) == index else { return nil }
          return "\(name).\(field.name)"
        }
        let renderedMembers = members.isEmpty ? "—" : members.map(code).joined(separator: ", ")
        let oneofKind =
          isSyntheticOneof(index: index, in: message) ? "synthetic optional" : "explicit"
        lines.append("| \(code("\(name).\(oneof.name)")) | \(oneofKind) | \(renderedMembers) |")
      }
    }
    if !message.reservedRange.isEmpty || !message.reservedName.isEmpty {
      lines.append("")
      let ranges = message.reservedRange.map { "\($0.start)..<\($0.end)" }
      if !ranges.isEmpty {
        lines.append("Reserved tags: \(ranges.map(code).joined(separator: ", ")).")
      }
      if !message.reservedName.isEmpty {
        lines.append("Reserved names: \(message.reservedName.map(code).joined(separator: ", ")).")
      }
    }
    lines.append("")

    for enumeration in message.enumType {
      renderEnum(enumeration, scope: name, into: &lines)
    }
    for nested in message.nestedType {
      renderMessage(nested, scope: name, into: &lines)
    }
  }

  private static func renderService(
    _ service: Google_Protobuf_ServiceDescriptorProto,
    scope: String,
    into lines: inout [String]
  ) {
    lines.append(contentsOf: [
      "### service `\(qualified(scope, service.name))`",
      "",
      "| Method | Input | Output | Streaming |",
      "| --- | --- | --- | --- |",
    ])
    for method in service.method {
      let streaming: String
      switch (method.clientStreaming, method.serverStreaming) {
      case (true, true): streaming = "bidirectional"
      case (true, false): streaming = "client"
      case (false, true): streaming = "server"
      case (false, false): streaming = "unary"
      }
      lines.append(
        "| `\(method.name)` | `\(trimmedTypeName(method.inputType))` | `\(trimmedTypeName(method.outputType))` | \(streaming) |"
      )
    }
    lines.append("")
  }

  private static func renderNativeTransport(
    _ native: [String: Any],
    into lines: inout [String]
  ) throws {
    lines.append(contentsOf: [
      "## Native QUIC transport",
      "",
      "This is the non-protobuf authority for the single QUIC v1/TLS 1.3 connection, fixed stream roles, QUIC DATAGRAM media plane, native headers, FEC, capabilities, validation, and typed transport failures.",
      "",
      "| Property | Value |",
      "| --- | --- |",
    ])
    for key in [
      "protocol", "transportName", "version", "alpn", "sessionProtocolVersion",
      "controlTransport", "mediaPlane", "applicationMediaEncryption", "directMediaUdp",
    ] {
      guard let value = native[key] else { continue }
      lines.append("| `\(key)` | \(code(try scalar(value, label: "nativeTransport.\(key)"))) |")
    }

    let clientStreams = try object(
      native["clientBidirectionalStreams"], label: "nativeTransport.clientBidirectionalStreams")
    let hostStreams = try object(
      native["hostUnidirectionalStreams"], label: "nativeTransport.hostUnidirectionalStreams")
    lines.append(contentsOf: [
      "",
      "### Fixed QUIC stream roles",
      "",
      "| Direction | Role | Raw stream ID or rule |",
      "| --- | --- | ---: |",
    ])
    for key in clientStreams.keys.sorted() {
      guard let value = clientStreams[key] else { continue }
      lines.append(
        "| client bidirectional | `\(key)` | \(code(try scalar(value, label: "client stream \(key)"))) |"
      )
    }
    for key in hostStreams.keys.sorted() {
      guard let value = hostStreams[key] else { continue }
      lines.append(
        "| host unidirectional | `\(key)` | \(code(try scalar(value, label: "host stream \(key)"))) |"
      )
    }

    for (heading, key) in [
      ("Message limits", "messageLimits"),
      ("HostSessionPlan field tags", "hostSessionPlan"),
      ("Video bootstrap", "videoBootstrap"),
    ] {
      let values = try object(native[key], label: "nativeTransport.\(key)")
      lines.append(contentsOf: [
        "",
        "### \(heading)",
        "",
        "| Property | Value |",
        "| --- | --- |",
      ])
      for name in values.keys.sorted() {
        guard let value = values[name] else { continue }
        let renderedValue: String
        if value is [Any] || value is [String: Any] {
          renderedValue = try compactJSON(
            value,
            label: "nativeTransport.\(key).\(name)"
          )
        } else {
          renderedValue = try scalar(value, label: "nativeTransport.\(key).\(name)")
        }
        lines.append(
          "| \(code(name)) | \(code(renderedValue)) |"
        )
      }
    }

    let header = try object(
      native["mediaDatagramHeader"], label: "nativeTransport.mediaDatagramHeader")
    let headerFields = try objectArray(
      header["fields"], label: "nativeTransport.mediaDatagramHeader.fields")
    lines.append(contentsOf: [
      "",
      "### QUIC DATAGRAM media header",
      "",
      "Base header bytes: \(code(try scalar(header["bytes"], label: "mediaDatagramHeader.bytes"))). Byte order: \(code(try scalar(header["byteOrder"], label: "mediaDatagramHeader.byteOrder"))).",
      "",
      "| Field | Offset | Bytes |",
      "| --- | ---: | ---: |",
    ])
    for field in headerFields {
      lines.append(
        "| `\(try string(field["name"], label: "header field name"))` | \(try integer(field["offset"], label: "header field offset")) | \(try integer(field["bytes"], label: "header field bytes")) |"
      )
    }

    let fecExtension = try object(
      native["fecBlockExtension"], label: "nativeTransport.fecBlockExtension")
    let fecFields = try objectArray(
      fecExtension["fields"], label: "nativeTransport.fecBlockExtension.fields")
    lines.append(contentsOf: [
      "",
      "### FEC block extension",
      "",
      "Extension bytes: \(code(try scalar(fecExtension["bytes"], label: "fecBlockExtension.bytes"))).",
      "",
      "| Field | Offset | Bytes |",
      "| --- | ---: | ---: |",
    ])
    for field in fecFields {
      lines.append(
        "| \(code(try string(field["name"], label: "FEC extension field name"))) | \(try integer(field["offset"], label: "FEC extension field offset")) | \(try integer(field["bytes"], label: "FEC extension field bytes")) |"
      )
    }

    lines.append(contentsOf: [
      "",
      "### Media, FEC, telemetry, capabilities, and validation",
      "",
    ])
    for key in [
      "mediaKinds", "flags", "fec", "telemetry", "mediaCapabilities",
      "dynamicRangeTransport", "validation", "transportErrors",
      "packetArrivalFeedbackErrors", "forbiddenCompatibilityProtocols",
    ] {
      guard let value = native[key] else { continue }
      lines.append("#### `nativeTransport.\(key)`")
      lines.append("")
      try renderJSON(value, into: &lines, label: "nativeTransport.\(key)")
      lines.append("")
    }

    lines.append(contentsOf: [
      "",
      "### Complete native transport authority",
      "",
    ])
    try renderJSON(native, into: &lines, label: "nativeTransport")
    lines.append("")
  }

  private static func renderAuthentication(
    _ authentication: [String: Any],
    into lines: inout [String]
  ) throws {
    lines.append(contentsOf: [
      "## HTTPS authentication API",
      "",
      "### Authentication routes",
      "",
      "| Route identifier | Method | Path | Authentication behavior |",
      "| --- | --- | --- | --- |",
    ])

    let network = try object(
      authentication["networkTransport"], label: "authentication.networkTransport")
    let networkMethod = try string(
      network["method"], label: "authentication.networkTransport.method")
    let networkRoutes = try object(
      network["routes"], label: "authentication.networkTransport.routes")
    for name in networkRoutes.keys.sorted() {
      lines.append(
        "| \(code(name)) | \(code(networkMethod)) | \(code(try string(networkRoutes[name], label: "authentication route \(name)"))) | declared authentication route |"
      )
    }
    for sectionName in ["conditionalRoutes", "protectedRoutes"] {
      let routes = try object(authentication[sectionName], label: "authentication.\(sectionName)")
      for name in routes.keys.sorted() {
        let route = try object(routes[name], label: "authentication.\(sectionName).\(name)")
        let behavior =
          sectionName == "protectedRoutes" ? "device authentication required" : "conditional"
        lines.append(
          "| \(code(name)) | \(code(try string(route["method"], label: "route method"))) | \(code(try string(route["path"], label: "route path"))) | \(behavior) |"
        )
      }
    }

    let operations = try object(authentication["operations"], label: "authentication.operations")
    for name in operations.keys.sorted() {
      let operation = try object(operations[name], label: "authentication.operations.\(name)")
      let request = try object(
        operation["request"], label: "authentication.operations.\(name).request")
      let response = try object(
        operation["response"], label: "authentication.operations.\(name).response")
      lines.append(contentsOf: [
        "",
        "### authentication operation `\(name)`",
        "",
        "Request shape:",
        "",
      ])
      try renderJSON(request, into: &lines, label: "authentication.operations.\(name).request")
      lines.append(contentsOf: ["", "Response shape:", ""])
      try renderJSON(response, into: &lines, label: "authentication.operations.\(name).response")
    }

    for key in [
      "accessRequestAuthentication", "credentialPolicy", "deviceEnrollmentPolicy", "idempotency",
      "possessionProof", "envelopes",
    ] {
      guard let value = authentication[key] else { continue }
      lines.append(contentsOf: ["", "### authentication authority `\(key)`", ""])
      try renderJSON(value, into: &lines, label: "authentication.\(key)")
    }

    let errors = try stringArray(authentication["errorCodes"], label: "authentication.errorCodes")
    lines.append(contentsOf: [
      "",
      "### Authentication error codes",
      "",
      errors.map { "- `\($0)`" }.joined(separator: "\n"),
      "",
      "### Complete authentication authority",
      "",
    ])
    try renderJSON(authentication, into: &lines, label: "https.authentication")
    lines.append("")
  }

  private static func renderSettings(
    _ settings: [String: Any],
    into lines: inout [String]
  ) throws {
    let network = try object(settings["networkTransport"], label: "settings.networkTransport")
    let routes = try object(network["routes"], label: "settings.networkTransport.routes")
    lines.append(contentsOf: [
      "## HTTPS settings API",
      "",
      "### Settings routes",
      "",
      "| Operation | Method | Path |",
      "| --- | --- | --- |",
    ])
    for name in routes.keys.sorted() {
      let route = try object(routes[name], label: "settings.networkTransport.routes.\(name)")
      lines.append(
        "| `\(name)` | `\(try string(route["method"], label: "settings route method"))` | `\(try string(route["path"], label: "settings route path"))` |"
      )
    }

    let envelopes = try object(settings["envelopes"], label: "settings.envelopes")
    lines.append(contentsOf: [
      "",
      "### Settings envelope members",
      "",
      "| Envelope | Declared members |",
      "| --- | --- |",
    ])
    for name in envelopes.keys.sorted() {
      let members = try stringArray(envelopes[name], label: "settings.envelopes.\(name)")
      lines.append("| \(code(name)) | \(members.map(code).joined(separator: ", ")) |")
    }

    let fields = try objectArray(settings["fields"], label: "settings.fields")
      .sorted { lhs, rhs in
        (try? integer(lhs["order"], label: "settings field order")) ?? 0
          < (try? integer(rhs["order"], label: "settings field order")) ?? 0
      }
    lines.append(contentsOf: [
      "",
      "### Settings fields",
      "",
      "| Order | Key | Title | Section | Type | Editor | Apply class | Availability | Constraints |",
      "| ---: | --- | --- | --- | --- | --- | --- | --- | --- |",
    ])
    for field in fields {
      let constraints = try settingConstraints(field)
      lines.append(
        "| \(try integer(field["order"], label: "settings field order")) | \(code(try string(field["key"], label: "settings field key"))) | \(code(try string(field["title"], label: "settings field title"))) | \(code(try string(field["sectionId"], label: "settings field section"))) | \(code(try string(field["type"], label: "settings field type"))) | \(code(try string(field["editor"], label: "settings field editor"))) | \(code(try string(field["applyClass"], label: "settings field applyClass"))) | \(code(try string(field["availability"], label: "settings field availability"))) | \(code(constraints)) |"
      )
    }

    for key in [
      "applyStates", "applyClasses", "requires", "requestId", "retention", "commandContract",
      "forbiddenRemoteKeys", "platformCapabilities",
    ] {
      guard let value = settings[key] else { continue }
      lines.append(contentsOf: ["", "### settings authority `\(key)`", ""])
      try renderJSON(value, into: &lines, label: "settings.\(key)")
    }

    let errors = try stringArray(settings["errorCodes"], label: "settings.errorCodes")
    lines.append(contentsOf: [
      "",
      "### Settings error codes",
      "",
      errors.map { "- `\($0)`" }.joined(separator: "\n"),
      "",
      "### Complete settings authority",
      "",
    ])
    try renderJSON(settings, into: &lines, label: "https.settings")
    lines.append("")
  }

  private static func renderLifecycle(
    _ lifecycle: [String: Any],
    into lines: inout [String]
  ) throws {
    let sequence = try stringArray(
      lifecycle["codecBootstrapSequence"], label: "lifecycle.codecBootstrapSequence")
    lines.append(contentsOf: [
      "## Session lifecycle",
      "",
      "### Codec bootstrap sequence",
      "",
    ])
    for (index, step) in sequence.enumerated() {
      lines.append("\(index + 1). `\(step)`")
    }
    let generation = try object(lifecycle["generation"], label: "lifecycle.generation")
    let sessionStop = try object(lifecycle["sessionStop"], label: "lifecycle.sessionStop")
    let display = try object(
      lifecycle["displayReconfiguration"], label: "lifecycle.displayReconfiguration")
    let fallback = try object(lifecycle["fallback"], label: "lifecycle.fallback")
    lines.append(contentsOf: [
      "",
      "### Generation, stop, reconfiguration, and fallback",
      "",
      "- Initial generation: \(code(try scalar(generation["initial"], label: "lifecycle.generation.initial"))).",
      "- Stop handshake: \(code(try scalar(sessionStop["request"], label: "sessionStop.request"))) must complete with \(code(try scalar(sessionStop["response"], label: "sessionStop.response"))) for the matching session epoch.",
      "- Display reconfiguration: \(code(try scalar(display["request"], label: "displayReconfiguration.request"))) produces \(code(try scalar(display["response"], label: "displayReconfiguration.response"))) under a strictly increasing revision.",
      "- `legacyProtocol`: \(code(try scalar(fallback["legacyProtocol"], label: "fallback.legacyProtocol"))).",
      "- `silentFormatDowngrade`: \(code(try scalar(fallback["silentFormatDowngrade"], label: "fallback.silentFormatDowngrade"))).",
      "- An implementation must fail closed; it must not infer or introduce a fallback outside this authority.",
    ])
    lines.append(contentsOf: [
      "",
      "### Complete lifecycle authority",
      "",
    ])
    try renderJSON(lifecycle, into: &lines, label: "lifecycle")
    lines.append("")
  }

  private static func fieldLabel(_ field: Google_Protobuf_FieldDescriptorProto) -> String {
    if field.label == .repeated { return "repeated" }
    if field.label == .required { return "required" }
    if field.proto3Optional { return "optional" }
    return "singular"
  }

  private static func fieldTypeKind(_ field: Google_Protobuf_FieldDescriptorProto) -> String {
    switch field.type {
    case .double: return "double"
    case .float: return "float"
    case .int64: return "int64"
    case .uint64: return "uint64"
    case .int32: return "int32"
    case .fixed64: return "fixed64"
    case .fixed32: return "fixed32"
    case .bool: return "bool"
    case .string: return "string"
    case .group: return "group"
    case .message: return "message"
    case .bytes: return "bytes"
    case .uint32: return "uint32"
    case .enum: return "enum"
    case .sfixed32: return "sfixed32"
    case .sfixed64: return "sfixed64"
    case .sint32: return "sint32"
    case .sint64: return "sint64"
    }
  }

  private static func fieldOneof(
    _ field: Google_Protobuf_FieldDescriptorProto,
    in message: Google_Protobuf_DescriptorProto
  ) -> String? {
    guard field.hasOneofIndex else { return nil }
    let index = Int(field.oneofIndex)
    guard message.oneofDecl.indices.contains(index) else { return "invalid-index-\(index)" }
    return message.oneofDecl[index].name
  }

  private static func isSyntheticOneof(
    index: Int,
    in message: Google_Protobuf_DescriptorProto
  ) -> Bool {
    let members = message.field.filter { field in
      field.hasOneofIndex && Int(field.oneofIndex) == index
    }
    return members.count == 1 && members[0].proto3Optional
  }

  private static func renderLimitations(into lines: inout [String]) {
    lines.append(contentsOf: [
      "## Contract limitations",
      "",
      "- The authentication route identifier `tokenExchange` and operation identifier `exchangeRefreshToken` are different declarations. This reference does not infer a mapping between them.",
      "- `verifyAccessToken` has no declared HTTP route.",
      "- Conditional and protected routes do not declare request or response schemas.",
      "- Authentication operation shapes do not declare required fields, nullability, or HTTP status codes.",
      "- Settings envelopes list member names but do not declare complete types, nesting, or HTTP status codes.",
      "- Raw media payload detail and timing or retry semantics remain in `lumen-streaming-protocol.md` and `lumen-settings-protocol.md` where the structured contract is not authoritative.",
      "- Implementations must not infer route mappings, field semantics, downgrade behavior, or fallback protocols that are absent from the contract.",
      "",
    ])
  }

  private static func renderImplementationChecklist(into lines: inout [String]) {
    lines.append(contentsOf: [
      "## Implementation checklist",
      "",
      "- Negotiate QUIC v1 with TLS 1.3 and ALPN `lumen-stream/4` only.",
      "- Generate protobuf bindings from `lumen-streaming-v4.proto`; preserve field tags, enum numbers, reservations, oneofs, and presence.",
      "- Enforce fixed stream roles, message limits, DATAGRAM layouts, FEC bounds, capability masks, and validation failures exactly.",
      "- Implement authentication routes and operation shapes as separate declared authorities; do not guess missing mappings or HTTP behavior.",
      "- Apply settings revisions, idempotency, availability, apply classes, command bounds, and forbidden keys before mutating host state.",
      "- Admit video deltas only after the codec configuration and decoded bootstrap sequence completes.",
      "- Complete `StopSession` only after the matching `SessionStopped` response.",
      "- Reject legacy protocols and silent format downgrade; fail closed when required authority is unavailable.",
      "- Run `lumen-contract-tool check` and the handwritten protocol gates before publishing an implementation.",
      "",
    ])
  }

  private static func renderJSON(
    _ value: Any,
    into lines: inout [String],
    label: String
  ) throws {
    guard JSONSerialization.isValidJSONObject(value) else {
      throw LumenContractToolError.invalid("\(label) is not valid JSON")
    }
    let data = try JSONSerialization.data(
      withJSONObject: value,
      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    guard let rendered = String(data: data, encoding: .utf8) else {
      throw LumenContractToolError.invalid("\(label) is not UTF-8 JSON")
    }
    lines.append("```json")
    lines.append(rendered)
    lines.append("```")
  }

  private static func settingConstraints(_ field: [String: Any]) throws -> String {
    let descriptiveKeys = Set([
      "key", "title", "sectionId", "sectionTitle", "order", "editor", "type", "applyClass",
      "availability",
    ])
    let constraints = Dictionary(
      uniqueKeysWithValues: field.compactMap { key, value in
        descriptiveKeys.contains(key) ? nil : (key, value)
      }
    )
    guard !constraints.isEmpty else { return "none" }
    return try compactJSON(constraints, label: "settings field constraints")
  }

  private static func compactJSON(_ value: Any, label: String) throws -> String {
    guard JSONSerialization.isValidJSONObject(value) else {
      throw LumenContractToolError.invalid("\(label) is not valid JSON")
    }
    let data = try JSONSerialization.data(
      withJSONObject: value,
      options: [.sortedKeys, .withoutEscapingSlashes]
    )
    guard let rendered = String(data: data, encoding: .utf8) else {
      throw LumenContractToolError.invalid("\(label) is not UTF-8 JSON")
    }
    return rendered
  }

  private static func qualified(_ scope: String, _ name: String) -> String {
    scope.isEmpty ? name : "\(scope).\(name)"
  }

  private static func trimmedTypeName(_ value: String) -> String {
    value.first == "." ? String(value.dropFirst()) : value
  }

  private static func object(_ value: Any?, label: String) throws -> [String: Any] {
    guard let value = value as? [String: Any] else {
      throw LumenContractToolError.invalid("\(label) must be an object")
    }
    return value
  }

  private static func objectArray(_ value: Any?, label: String) throws -> [[String: Any]] {
    guard let value = value as? [[String: Any]] else {
      throw LumenContractToolError.invalid("\(label) must be an array of objects")
    }
    return value
  }

  private static func stringArray(_ value: Any?, label: String) throws -> [String] {
    guard let value = value as? [String] else {
      throw LumenContractToolError.invalid("\(label) must be an array of strings")
    }
    return value
  }

  private static func string(_ value: Any?, label: String) throws -> String {
    guard let value = value as? String else {
      throw LumenContractToolError.invalid("\(label) must be a string")
    }
    return value
  }

  private static func integer(_ value: Any?, label: String) throws -> Int {
    guard let value = value as? NSNumber,
      CFGetTypeID(value) != CFBooleanGetTypeID(),
      !CFNumberIsFloatType(value),
      let integer = Int(exactly: value.int64Value)
    else {
      throw LumenContractToolError.invalid("\(label) must be an integer")
    }
    return integer
  }

  private static func scalar(_ value: Any?, label: String) throws -> String {
    guard let value else {
      throw LumenContractToolError.invalid("\(label) is missing")
    }
    if value is [Any] || value is [String: Any] {
      throw LumenContractToolError.invalid("\(label) must be a scalar")
    }
    return scalarDescription(value)
  }

  private static func scalarDescription(_ value: Any) -> String {
    if let value = value as? String { return value }
    if value is NSNull { return "null" }
    if let value = value as? NSNumber {
      if CFGetTypeID(value) == CFBooleanGetTypeID() {
        return value.boolValue ? "true" : "false"
      }
      return value.stringValue
    }
    return String(describing: value)
  }

  private static func code<T>(_ value: T) -> String {
    let escaped = String(describing: value)
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "`", with: "&#96;")
      .replacingOccurrences(of: "|", with: "&#124;")
      .replacingOccurrences(of: "\n", with: "&#10;")
    return "<code>\(escaped)</code>"
  }
}
