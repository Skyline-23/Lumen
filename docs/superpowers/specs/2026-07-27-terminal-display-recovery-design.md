# Terminal Display Recovery Design

## Problem

A native QUIC session can end through control-stream EOF, transport reset,
task failure, or an explicit `StopSession`. The current server invokes
`terminate_native_connection` for every terminal result, but macOS workspace
cleanup is attempted only once. If physical-display enable succeeds while
WindowServer publication is still converging, exact topology verification
fails, the retryable workspace owner remains retained, and the physical
display can stay unavailable until the host worker exits.

The worker-exit watchdog eventually retries durable recovery, but a worker
crash or manual restart must not be required to restore the local display.

## Required Behavior

- Every terminal connection result must stop media delivery immediately and
  enter workspace teardown for that exact session epoch.
- Explicit `StopSession`, control EOF, QUIC reset, timeout, cancellation, and
  media-task failure must share the same teardown owner.
- macOS teardown must keep retrying only the retained workspace cleanup while
  physical display publication is still transient.
- A retry must never start a second application cleanup or lose the retained
  workspace key.
- Recovery is complete only after the saved physical identity, mode, origin,
  mirror state, active state, online state, and `NSScreen` visibility converge
  continuously.
- The durable display journals are cleared only after that verification.
- A new native session must remain fail-closed while cleanup is pending.
- The worker-exit watchdog remains an independent last-resort recovery path.

## Architecture

The QUIC server continues to own the terminal boundary and calls
`terminate_native_connection` exactly once. `NativeControlRouter` retains the
pending cleanup state exactly as it does today.

The macOS workspace layer owns transient WindowServer convergence. Its durable
recovery operation performs bounded, condition-based retry of the existing
restore/verify transaction. Retrying at this layer preserves the stable
physical-display identity mapping and avoids transport-specific sleeps or
duplicate application teardown.

The retry budget applies only after the connection has already terminated, so
it cannot reduce active streaming performance. Failure after the bounded
window remains retryable and keeps both journals intact for the independent
worker watchdog or a later authenticated cleanup owner.

## Alternatives Rejected

1. Terminate the worker on every connection loss. This restores the display
   through the existing watchdog but unnecessarily drops the listening host
   service and hides the broken session lifecycle.
2. Require Shadow to always send `StopSession`. Mobile suspension, process
   termination, network loss, and transport reset can prevent that message,
   so the host must own terminal cleanup.
3. Delete recovery journals when the display merely reappears. Visibility
   alone does not prove that mode, origin, mirroring, and ownership were
   restored.

## Verification

- A RED host test proves control EOF invokes the same retained cleanup owner
  and does not require worker exit.
- A RED macOS workspace test simulates delayed physical republication beyond
  the first verification attempt and requires eventual exact convergence.
- A retry test proves application cleanup is not duplicated.
- A failure test proves bounded exhaustion preserves recovery journals and
  rejects a new session.
- Existing Lumen Rust, Swift, display-disconnect, and workspace recovery tests
  remain green.
- A Release canary verifies physical disable and restore.
- One physical-iPad session verifies that disconnect restores the physical
  display without restarting the Lumen worker.
