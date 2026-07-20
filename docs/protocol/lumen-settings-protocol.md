# Lumen Settings Protocol v1

Lumen settings are a source-neutral, revisioned host authority. The canonical
machine-readable field catalog is
[`lumen-settings-conformance.json`](./lumen-settings-conformance.json). Platform
stores map to this contract; Swift property names, registry names, and worker
configuration keys are not protocol keys.

## HTTPS transport

Enrolled devices use the shared Lumen device Bearer contract on every settings
request: `Authorization: Bearer <accessToken>` together with exactly one
case-insensitive `Lumen-Device-ID` header. Basic authentication, cookies, and
authentication query parameters are forbidden.

- `GET /api/v1/settings` returns the authoritative snapshot.
- `PATCH /api/v1/settings` accepts one JSON patch envelope, up to 32 KiB.
- `GET /api/v1/settings/events?afterRevision=<u64>` returns retained events
  strictly after the supplied revision.

Settings responses are JSON and carry `Cache-Control: no-store`. Worker startup
reconciles the native launch snapshot before network services begin.
Reconciliation preserves unapplied client-authored values whose effective
runtime values did not change.

## Envelopes

A snapshot contains `schemaVersion`, the host-assigned concurrency `revision`, requested
`settings`, currently `effective` settings, `applyState`, and field
`capabilities`. A patch contains `schemaVersion`, `baseRevision`, a stable
`requestId`, and nested partial `changes`. An accepted response contains the new
revision, `accepted: true`, authoritative effective settings, `applyState`, and
`requires`.

Schema version 1 recognizes `applied`, `pending-next-session`, and
`pending-worker-restart` apply states. Requirements are `none`, `next-session`,
or `worker-restart`. A saved next-session or worker-restart value does not appear
in `effective` until the platform adapter reports that transition as applied.

Patches are atomic. The host rejects the complete request for an unsupported
schema, stale revision, unknown or unavailable field, invalid enum or range,
forbidden key, or malformed command. Repeating the same accepted `requestId` and
payload returns the original response, including after restart. Reusing the ID
with a different payload is a conflict.

`revision` is an internal optimistic-concurrency token, not a product version.
The pre-release capability hard break keeps `schemaVersion: 1` while retiring
the previous on-disk journal generation. On first open, that journal is
discarded and reseeded at revision 1 with empty event and idempotency history;
the first accepted patch advances to revision 2. No legacy field or revision
migration is performed.

## Events and capabilities

Every accepted patch, local authoritative update, and deferred application
transition advances the revision and appends a resumable event. A client resumes
strictly after its last observed revision. If that point is no longer retained,
the host returns `revision-not-retained` and the client fetches a new snapshot.

Capabilities expose only settings whose accepted PATCH changes the running host
or the next native session: `general.name`, `network.fecPercentage`, and the
three structured command lists. Local launch configuration such as listener
address family, connection port, UPnP, display/audio device selection, discovery,
input policy, diagnostics, and update preferences is intentionally absent. The
application owns those values and restarts the worker with one authoritative
launch snapshot.

Each public capability is also the authoritative presentation contract under
`schemaVersion: 1`. Every field includes required `title`, `sectionId`,
`sectionTitle`, unique `order`, and `editor` values. Editors are `text`,
`integer-menu`, `prep-command-list`, or `server-command-list`. Clients derive
the visible settings hierarchy, ordering, controls, presets, and value labels
from this response; they do not maintain a parallel field catalog. FEC preset
labels are percentage strings such as `"20": "20%"`.

Remote-access scope and external-address selection are not product settings.
An enrolled device may use the same authenticated HTTPS and native-session
surfaces over LAN or WAN whenever routing permits. Lumen does not infer trust
from the peer's network location.

LAN and WAN encryption selectors are also absent because the current native
transport has no unencrypted mode. Control, discovery detail, applications,
authentication, and settings use the TLS control server. Native session control
uses QUIC with TLS 1.3. Reliable bootstrap/configuration objects use QUIC
streams and deadline-bound audio/video delta objects use QUIC DATAGRAM. The
transport does not expose a separate native UDP socket, application media key,
or application-layer encryption selector. The former LAN/WAN selector values
never selected any of these paths.

## Security boundary

Snapshots, events, and patches never contain owner passwords, device tokens,
private keys, certificate or credential paths, host file paths, a remote-control
selector, or a remote-settings permission toggle. Authorization is enforced by
the transport endpoint before invoking this authority.

Commands use structured program-and-argument arrays and an explicit `user` or
`administrator` privilege. Adapters execute the array directly without a shell.
Program paths, shell syntax, shell interpreters, control characters, oversized
arguments, duplicate server-command names, and oversized command lists are
rejected. Command-field `allowedValues` advertise the privileges the host can
actually honor: macOS accepts `user`, while the Windows service runtime accepts
`user` and `administrator`. Unsupported privilege requests fail atomically.

The authority persists revisions, desired/effective state, retained events, and
idempotency records with an atomic file replacement. Factory reset deletes this
state and returns to revision 1 defaults.
