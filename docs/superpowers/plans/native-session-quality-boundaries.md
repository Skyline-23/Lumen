# Native Session Quality Boundaries Implementation Plan

## 1. Decouple source receipt from VideoToolbox admission

- Add a production-boundary regression test with an injected blocking encoder
  submitter.
- Prove the current callback blocks, then introduce the smallest bounded
  serialized admission boundary.
- Preserve single-session VideoToolbox ownership, generation fences, drop
  accounting, and callback ordering.
- Run the focused macOS capture tests and macOS bridge build.
- Commit as one capture-cadence unit.

## 2. Reuse deferred physical isolation

- Update the existing desktop-mirror workspace test to require deferred
  isolation for `isolatedWorkspace`.
- Stop overriding the requested isolated policy for desktop-mirror content.
- Verify isolation starts only after the first encoded frame and exact
  restoration occurs on stop and failure.
- Run the focused workspace/recovery tests and macOS bridge build.
- Commit as one display-lifecycle unit.

## 3. Add session-scoped tapped system audio

- Add injected lifecycle tests for tap, aggregate device, AudioUnit start, and
  reverse-order cleanup across every terminal path.
- Implement Core Audio tapped capture with `mutedWhenTapped` semantics behind
  the existing audio runtime boundary.
- Preserve the existing audio frame format and forwarding contract.
- Fail with a typed platform error when exclusive capture cannot start.
- Run focused audio/runtime tests and the macOS bridge build.
- Commit as one audio-lifecycle unit.

## 4. Review and runtime replacement

- Run independent code review for all three commits.
- Run relevant Rust/native ABI checks plus Release build.
- Push the green feature branch.
- Install and deep/strict verify `/Applications/Lumen.app`.
- Verify the new app/worker PIDs and TCP 48990 / UDP 49010 listeners.
- Do not initiate a Shadow connection; live success is established only by
  the user's next manual session.
