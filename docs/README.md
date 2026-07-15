# Lumen documentation

Start with the document that matches the work being performed.

## Users and operators

- [Installing Lumen](installing.md): macOS Homebrew and DMG installation,
  Windows installation, upgrades, uninstalling, permissions, and duplicate-app
  cleanup.
- [Releasing Lumen](releasing.md): required credentials, GitHub Actions
  secrets, stable-tag publication, verification, and failure recovery.

## Architecture and development

- [Native host architecture](native-host-app-architecture.md): Rust ownership
  and the macOS and Windows adapter boundaries.
- [MIT migration contract](mit-migration.md): provenance rules, mandatory
  removals, and the exit gate for the Lumen-native Rust host.
- [macOS Tuist project](tuist-bootstrap.md): supported project generation,
  build, and test entry points.

## Protocol contracts

- [Streaming protocol](protocol/lumen-streaming-protocol.md)
- [Settings protocol](protocol/lumen-settings-protocol.md)
- `protocol/*.json`: machine-readable conformance fixtures used by tests and
  generated protocol artifacts.

The repository [README](../README.md) contains the short project overview and
common validation commands. Keep operational detail in these documents rather
than duplicating release or installation instructions in multiple places.
