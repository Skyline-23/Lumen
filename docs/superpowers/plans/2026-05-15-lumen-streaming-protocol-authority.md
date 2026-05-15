# Lumen Streaming Protocol Authority Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Lumen the protocol authority for Mac and Windows streaming signals by extracting protocol constants and documenting the normalized wire contract.

**Architecture:** Create a source-neutral protocol core in `src/lumen_protocol.h`, then make RTSP, launch HTTP, and control-channel code consume it. Platform-specific Mac and future Windows adapters remain producers of normalized Lumen state.

**Tech Stack:** C++20 header-only protocol constants, existing Lumen RTSP/control code, Markdown protocol docs, existing Tuist/CMake test workflows.

---

### Task 1: Document The Protocol Contract

**Files:**
- Create: `docs/protocol/lumen-streaming-protocol.md`
- Create: `docs/superpowers/specs/2026-05-15-lumen-streaming-protocol-authority-design.md`

- [x] **Step 1: Define ownership**

Document that Lumen owns wire ids, capability keys, payload versions, fallback policy, and presentation contract names.

- [x] **Step 2: Define Mac and Windows adapter roles**

Document that MacDisplayKit and Windows capture stacks map source-specific metadata into Lumen protocol state.

- [x] **Step 3: Define client role**

Document that clients follow the Lumen protocol only and must not depend on MDK or Windows capture semantics.

### Task 2: Extract C++ Protocol Constants

**Files:**
- Create: `src/lumen_protocol.h`
- Modify: `src/rtsp.cpp`
- Modify: `src/shadow_http.cpp`
- Modify: `src/stream.cpp`

- [x] **Step 1: Create header-only protocol core**

Add `lumen::protocol::rtsp`, `lumen::protocol::launch`, `lumen::protocol::control`, and `lumen::protocol::presentation` namespaces.

- [x] **Step 2: Move RTSP capability keys into the protocol core**

Replace local required field arrays and encoded-tile key literals with protocol constants.

- [x] **Step 3: Move launch capability names into the protocol core**

Replace local required argument arrays and encoded-tile argument literals with protocol constants.

- [x] **Step 4: Move control ids and payload versions into the protocol core**

Replace local Lumen control message id, version, and flag constants with protocol constants.

### Task 3: Verify Behavior Preservation

**Files:**
- Test: `tests/unit/test_stream.cpp`
- Test: `tests/tuist/macos/LumenTuistBootstrapTests.swift`

- [x] **Step 1: Run targeted unit tests**

Run: `ctest --test-dir build --output-on-failure -R "stream|rtsp|video"` if an existing build directory is available.

Result: command completed, but the existing CTest build directory reported `No tests were found!!!`.

- [x] **Step 2: Run macOS bootstrap tests**

Run: `xcodebuild test -workspace src/platform/macos/Lumen.xcworkspace -scheme LumenTuistTests -only-testing:LumenTuistBootstrapTests`

Result: `LumenTuistBootstrapTests` executed 33 tests with 0 failures.

- [ ] **Step 3: Commit**

Commit with message `Extract Lumen streaming protocol constants`.
