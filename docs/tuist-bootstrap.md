# macOS Tuist Project

Tuist is the only supported macOS project-generation, test, and build entry
point. CMake is reserved for the Windows-native adapter build.

## Targets

- `LumenApp`: SwiftUI application, menu bar, onboarding, settings, and worker
  supervision.
- `LumenEngineBridge`: Rust engine archive and C ABI.
- `LumenMacBridge`: macOS capture, encode, display, audio, and input adapters.
- `LumenHostRuntimeBridge`: Objective-C worker-process boundary.
- `LumenHostWorker`: bundle-contained `lumen-host` executable.
- `LumenMacCaptureAdapter`: application-to-worker lifecycle adapter.
- `LumenTuistTests`: native bridge and contract tests.

The source manifest is `src/platform/macos/Project.swift`. Generated Xcode
projects and workspaces are build artifacts, not authorities.

## Commands

Generate without opening Xcode, then use the generated workspace for every
build and test:

```bash
cd src/platform/macos
tuist generate --no-open
tuist xcodebuild test -workspace Lumen.xcworkspace \
  -scheme LumenTuistTests -destination 'platform=macOS'
tuist xcodebuild build -workspace Lumen.xcworkspace \
  -scheme LumenApp -destination 'generic/platform=macOS'
```

Do not call raw `xcodebuild` for repository validation.
