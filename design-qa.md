# Windows native management UI design QA

## Reference

- Canonical implementation: `src/platform/macos/Projects/LumenApp/Sources/LumenRootView.swift`
- Canonical palette: `src/platform/macos/Projects/LumenApp/Sources/LumenAuthenticationSupport.swift`
- Rejected Windows state: `/var/folders/rz/b2b1bmx51d76nb2mfg3mlxfc0000gn/T/codex-clipboard-965c72a7-ccb8-40f4-afa5-afdce8e57d24.png`
- Target viewport: native 960 x 620 logical-pixel window, matching the macOS default content size.

## Source contract verified

- Authentication has a dedicated 340 px hero and a centered form surface; the management sidebar is hidden until authentication succeeds.
- Authentication maps the macOS dark palette directly: hero `#13120F`, form `#0E0F12`, primary/secondary/tertiary white at 94%/66%/43%, and tint `#FF6B33`.
- The hero reproduces the macOS amber, coral, and mint radial glows and the rotated 7.5%-opacity Lumen watermark over the solid warm-black base.
- Brand, authentication, feature, application, and navigation icons use the canonical packaged `icon.svg` and `src_assets/common/assets/icons/ui/*.svg` through the reusable WinUI asset icon adapter; no Segoe glyph substitutes remain.
- Auth inputs sit directly on the form surface like the macOS source; management retains translucent cards, subtle borders, and native controls.
- Primary authentication actions stretch to the full form width and retain white text.
- Owner and password fields use native WinUI controls; passwords use `PasswordBox` with reveal-on-demand.
- Management navigation icons use one fixed 22 px slot.
- English, Korean, and Japanese hero copy is present.
- The isolated native WinUI project builds on Windows with zero warnings and zero errors.

## Native Windows visual gate

- Captured from the installed 0.0.47 MSI in the active Windows user session:
  [`docs/qa/windows-native-auth-0.0.47-2026-07-30.jpeg`](docs/qa/windows-native-auth-0.0.47-2026-07-30.jpeg)
  (1365 x 768 remote-desktop capture, SHA-256
  `30f37bda7c628630c52001e89b50f1abeac5403a6806c059909a4287d3ffb92b`).
- The visible authentication window has the intended 340 logical-pixel hero,
  `#13120F` hero / `#0E0F12` form split, native owner/password controls,
  shared SVG branding, and `#FF6B33` full-width primary action.
- P0 fixed: the unpackaged WinUI app now resolves dotted RESW keys from its
  explicitly loaded `Lumen.pri`; the final launch left no
  `%LOCALAPPDATA%\\Lumen\\ui-error.log`.
- P1 fixed: the initial `AppWindow` size now applies the active XAML
  rasterization scale, preserving the 960 x 620 logical design rather than
  shrinking the form at high Windows DPI.
- P2 fixed: caption buttons use the form surface instead of the light system
  fallback; the final capture has a continuous dark title bar.
- Runtime evidence: installed `Lumen 0.0.47`, visible `Lumen.exe` in Windows
  session 2, titled `Lumen`, with a nonzero `MainWindowHandle` (`1049702`).
  No Shadow connection or media session was started.

## Verification

- `cmake --build cmake-build-0.0.47 --config Release`
- `cmake --install cmake-build-0.0.47 --prefix cmake-build-0.0.47\\msi-stage --strip`
- `dotnet build packaging/windows/Lumen.wixproj --configuration Release --no-incremental ...`
  produced and installed
  `C:\\Temp\\LumenNativeProbe\\cmake-build-0.0.47\\cpack_artifacts\\Lumen-0.0.47-Windows-x86_64.msi`.

final result: passed
