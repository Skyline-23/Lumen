# Lumen protocol contracts

This directory is the public authority for implementing a Lumen streaming
client. Consumer repositories do not own or synchronize changes back into this
directory.

## Contract authority

- `lumen-contract-v4.json` is the only editable machine-readable contract
  authority. Its committed meta-schema is `lumen-contract-v4.schema.json`.
- `lumen-contract-v4.manifest.json` records the authority digest, generated
  artifacts, and the remaining drift-gated handwritten boundaries.
- `lumen-streaming-v4.proto` is generated from the custom IDL and defines
  protobuf messages, field numbers, and enum values.
- `lumen-streaming-v4.descriptor.pb` is the generated protobuf descriptor set.
- `lumen-api-reference.md` is the generated implementation reference for the
  protobuf, native QUIC, authentication, settings, and lifecycle authorities.
- `lumen-streaming-v4.manifest.json` records protocol identity and SHA-256
  digests for the schema and descriptor.
- `lumen-streaming-v4.sha256` is the schema digest in `sha256sum` format.
- `lumen-native-transport-conformance.json` defines the compact QUIC DATAGRAM
  header and fixed transport constants outside protobuf.
- `lumen-streaming-protocol.md` defines ordering, lifecycle, validation, and
  failure semantics that are not expressible in protobuf.
- `lumen-auth-conformance.json` defines enrollment, possession proof, access
  token exchange, request authentication, revocation, and error envelopes.
- `lumen-settings-conformance.json` and `lumen-settings-protocol.md` define the
  revisioned remote settings API and its HTTPS routes.

An implementation must consume the protobuf schema and native transport
conformance from the same Lumen commit. A descriptor, manifest, or conformance
file from another commit is not a compatible authority bundle even when its
protocol version string is unchanged.

## Independent client implementation

An independent client needs no private source dependency. Implement against
the files in this directory in this order:

1. Use `lumen-auth-conformance.json` to enroll a device key, rotate its refresh
   token, and obtain the short-lived access token used by HTTPS and the native
   session hello.
2. Generate protobuf bindings from `lumen-streaming-v4.proto` or consume the
   equivalent `lumen-streaming-v4.descriptor.pb`. Verify both against
   `lumen-streaming-v4.manifest.json` before use.
3. Implement QUIC connection identity, fixed stream roles, codec/bootstrap
   ordering, generation fencing, telemetry, and StopSession behavior exactly
   as specified by `lumen-streaming-protocol.md`.
4. Implement the non-protobuf DATAGRAM header and FEC constants from
   `lumen-native-transport-conformance.json`.
5. If remote host settings are needed, derive routes, fields, revisions, and
   capabilities from `lumen-settings-conformance.json`; use
   `lumen-settings-protocol.md` for lifecycle and concurrency semantics.

Unknown enum values used by v4 semantic validators, stream roles, generations,
and lifecycle states fail with the typed behavior in the authority documents.
Unknown protobuf fields follow normal protobuf compatibility behavior: Prost
discards them and SwiftProtobuf preserves them in `unknownFields`; an unknown
field alone is not a typed protocol failure. There is no legacy transport,
protocol-version fallback, or silent format downgrade.

## Updating the contract

Edit only `lumen-contract-v4.json`, then regenerate and verify the public
package and artifacts:

```bash
swift run --quiet lumen-contract-tool validate
PROTOC_GEN_SWIFT="$(tools/protocol/build_protoc_gen_swift.sh)" \
  swift run --quiet lumen-contract-tool generate
PROTOC_GEN_SWIFT="$(tools/protocol/build_protoc_gen_swift.sh)" \
  swift run --quiet lumen-contract-tool check
swift test
```

The root Swift package publishes the `LumenClientContracts` library product.
Apple-platform clients may consume this repository at an exact release tag or
commit and import the generated `Lumen_Streaming_V4_*` SwiftProtobuf types.
The path-filtered protocol workflow rejects generated drift and breaking v4
changes, then compiles the public package. It never edits a consumer repository.

The Rust runtime models and the complete lifecycle prose are currently
handwritten drift-gated boundaries. The manifest reports these boundaries
explicitly; the repository does not claim they are generated until they move
into structured IDL sections.

Breaking changes must use a new protocol generation. Within v4, preserve field
numbers, enum values, stream roles, header layout, lifecycle ordering, and
typed failure meanings. Removed protobuf fields and enum values must remain
reserved.
