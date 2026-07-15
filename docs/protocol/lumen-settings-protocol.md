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

Capabilities describe every field's stable key, type, apply class, availability,
allowed enum values, user-facing value labels, numeric bounds, integer presets
and steps, and string constraints. Finite host resources use enum capabilities
with nonempty `allowedValues` and matching `allowedValueLabels`; clients present
pickers and do not synthesize raw values. Unsupported
platform-specific fields are present as unavailable metadata and cannot be
patched. In particular, non-macOS hosts do not advertise macOS workspace policy
as available.

Host language is not a remote setting. `general.locale` is absent because
language selection belongs to each client device. `network.externalIpMode`
accepts only `automatic` or `disabled`; arbitrary external-IP text is not part
of the settings contract.

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
