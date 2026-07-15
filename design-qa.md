# Windows UI design QA

Status: PASS

## Reference

- Source: the running macOS Lumen authentication window at 960 x 620.
- Implementation: `engine/lumen-host/ui/windows-app.slint`, rendered at the
  same 960 x 620 window size with the Fluent backend.
- Comparison: source and implementation were placed side by side before the
  final geometry and spacing pass.

## Verified

- Authentication uses the same 340 px hero, brand placement, headline, copy,
  feature list, owner row, 420 px form, control order, and centered vertical
  composition as macOS.
- The management window preserves the macOS 210 px split-view sidebar,
  Overview and Applications destinations, all seven Settings categories,
  Diagnostics, signed-in footer, overview cards, system-access group, and host
  controls.
- Setup, password login, lock, sidebar navigation, application reload, stream
  stop, host restart, and quit callbacks are connected to the Rust model or
  Rust host commands.
- The macOS preview falls back when Segoe UI Variable is unavailable; packaged
  Windows builds resolve that declared Windows font rather than the preview
  fallback.

## Build evidence

- Slint compilation passed through `cargo check --locked --target
  x86_64-pc-windows-gnu -p lumen-host`.
- Windows model authentication and navigation tests passed.
- The Rust-owned management state keeps the C++ tray limited to a native shell
  adapter.
