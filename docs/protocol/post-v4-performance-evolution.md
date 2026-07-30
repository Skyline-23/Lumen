# Post-v4 Performance Evolution

This document records performance work that cannot be introduced without a
new, atomic Shadow-Lumen protocol generation. Protocol v4 remains unchanged and
has no fallback or migration path.

## Already supported by v4

The following remain implementation work inside the current contract:

- encoder bitrate, FEC percentage, and latest-frame admission adaptation;
- paired audio and video feedback windows;
- same-generation datagram keyframes and reliable repair bootstraps;
- bounded independent media lanes;
- client-requested display reconfiguration; and
- capture, encoder, transport, decoder, and presentation scheduling changes.

## Future contract changes

### Multi-link sessions

Protocol v4 binds every role to one QUIC connection and defines no path or
secondary connection identity. A future generation would need session-global
object identities, additional-connection registration, cross-link
deduplication, scheduling, and failover rules before audio, input, and video can
use independent links safely.

### Host-initiated format ladder

The current adaptive controller may change bitrate, FEC, and encoder admission,
but not the selected codec, dimensions, refresh rate, chroma, bit depth, or
dynamic range. A future generation would need host proposals, client
acknowledgements, exact capability-rung selection, revised bitrate floors, and
an atomic decoder cutover. This is distinct from the existing client-requested
`DisplayReconfigurationRequest`.

### Authoritative delay-based congestion control

Packet-arrival feedback is observation-only in v4. Making it control pacing or
wire rate requires shared semantics for sender and receiver clocks, arrival
trend calculation, validation, and precedence relative to loss, FEC, and
pipeline pressure.

### Layer-aware video delivery

The current media header describes one complete encoded object and exposes no
temporal or spatial dependency graph. A future generation would need layer
identifiers, dependency and decodability metadata, per-layer budgets and
feedback, and explicit enhancement-layer discard rules.

### Negotiable burst-loss protection

Protocol v4 fixes media recovery to systematic Reed-Solomon over GF(2^8). A
future generation would need an FEC scheme identifier, symbol and interleaving
model, unequal-protection classes, and matching receiver feedback before it can
prefer reference data or tolerate longer burst loss without uniform parity.

## Release rule

Any item above must ship as one new protocol generation in Lumen and Shadow.
The v4 parser, capability mask, stream layout, and media flags must not be
extended piecemeal, and a new generation must not silently fall back to v4.
