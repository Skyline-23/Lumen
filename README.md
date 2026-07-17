# Lumen

Lumen is a self-hosted desktop streaming host for macOS and Windows. Shared
authentication, settings, application, session, protocol, network, and
transport behavior lives in Rust. Native code is limited to platform UI and
operating-system media boundaries.

Shadow is the first-party client. The current product codec contract is H.264,
HEVC, or AV1 video plus Opus audio.

## Repository layout

- `engine/lumen-engine`: shared typed policy, authorities, and protocol
  contracts.
- `engine/lumen-host`: authenticated control, media transport, discovery,
  UPnP, and application lifecycle. The active migration replaces its legacy
  transport with Lumen-native adaptive datagram v2.
- `src/platform/macos`: SwiftUI application and macOS capture, display, audio,
  encode, and input adapters.
- `src/platform/windows`: Windows-native capture, encode, audio, input, display,
  process, and tray adapters retained behind Rust-owned lifecycles.
- `docs/protocol`: human-readable contracts and machine-readable conformance
  fixtures.

See [Native host architecture](docs/native-host-app-architecture.md) for the
ownership boundaries.

The [documentation index](docs/README.md) links installation, release,
architecture, build, and protocol runbooks.

## Installation

Release artifacts include a signed macOS DMG and a signed Windows installer.
On Apple Silicon Macs, install the project cask with its fully qualified name:

```bash
brew tap Skyline-23/lumen
brew install --cask Skyline-23/lumen/lumen
```

The qualified name is required because Homebrew's default cask repository also
contains an unrelated cask named `lumen`. The project cask requires macOS 15 or
newer. Windows releases are distributed as an x86-64 NSIS installer from the
GitHub Releases page.

See [Installing Lumen](docs/installing.md) for upgrades, uninstalling, macOS
permissions, Windows installer behavior, and duplicate-app cleanup.

## Validation

Validate the Rust workspace from the repository root:

```bash
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
```

Validate the macOS project through Tuist without launching the app:

```bash
cd src/platform/macos
tuist test --no-selective-testing --no-binary-cache LumenTuistTests
tuist xcodebuild build -workspace Lumen.xcworkspace \
  -scheme LumenTuistTests -destination 'platform=macOS'
```

Do not use raw `xcodebuild` for project validation. See the
[Tuist project guide](docs/tuist-bootstrap.md) for target details.

## macOS packaging

The release workflow resolves SwiftOpus through SPM, builds the universal Rust
worker and app, signs `Lumen.app`, creates the DMG, notarizes it, and staples
the ticket. There is no separate local package wrapper. See
[Releasing Lumen](docs/releasing.md) for the complete release and local
smoke-test commands.

## Protocol maintenance

- [Streaming protocol](docs/protocol/lumen-streaming-protocol.md)
- [Settings protocol](docs/protocol/lumen-settings-protocol.md)
- [MIT migration contract](docs/mit-migration.md)
- `docs/protocol/lumen-streaming-v2.proto`: native v2 control authority

After editing the native protocol contract, run:

```bash
python3 tools/quality/run_lumen_quality_gate.py --fast
```

## Branching

Lumen uses Git Flow: feature branches target `develop`; releases move from
`develop` to `main`; hotfixes are merged into both. Pushes and pull requests to
`develop` run tests without producing distribution artifacts. A push to `main`
builds and publishes the signed release after both Rust product crate versions
are verified, then creates the matching stable semantic-version tag on that
`main` commit.

## License

Lumen is licensed under the [MIT License](LICENSE). See `NOTICE` and the
packaged third-party license texts for dependency attribution. Regenerate the
Rust dependency report with `scripts/licenses/generate_rust_licenses.sh`; use
`scripts/licenses/generate_rust_licenses.sh --check` in release verification.
