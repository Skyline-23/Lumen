# ShadowVC regional predictor profile (SCV2)

This additive v4 profile is `VIDEO_PROFILE_SHADOW_VC_REGIONAL_PREDICTOR8` (10).
It must be explicitly negotiated; profile 9 retains its original FC3/SCV1 meaning.
Profile 10 availability is not implied by generic ShadowVC support. Both peers
must advertise the exact profile before a session selects it.

The selected format is ShadowVC, YUV420, SDR, limited-range P010 output. The
predictor retains 8-bit SDR plane codes exactly; a 10-bit output container does
not imply 10-bit source precision or HDR. Dimensions are even, width 2..3840 and
height 2..2160. Capture and output dimensions must match without scaling.

The UTF-8 JSON decoder configuration has at most 1024 bytes:

```
{"version":2,"model":"fc4-regional-predictor8-v1","checkpoint":"24efd0c26f332a15c92c015cf68cf8d4254a11b1b9ba798f66b0667ee8e51b86","width":3840,"height":2160}
```

The checkpoint fits a reversible causal reference tree from training data, with
zero gradient updates. Its native integer specialization is 64 luma and 16 chroma
reference indices. Their combined 80-byte SHA256 is
`5356c1d203731bfd916a884e3c1819d4c5b780fa20f2152ed279e8818deabda1`.
The ShadowVCRuntime dependency pins the implementation and model together.

## Access unit

All integer fields below are little endian. An SCV2 access unit contains:

| Offset | Value |
|---:|---|
| 0 | Four bytes `SCV2` |
| 4 | Nonzero uint32 source frame ID |
| 8 | uint32 full width |
| 12 | uint32 full height |
| 16 | uint32 source reference ID; zero means independent frame |
| 20, 24, 28 | uint32 byte lengths of Y, Cb, Cr packets |
| 32 | The three F4R2 packets in that order |
| final 4 bytes | CRC32C of every preceding access-unit byte |

The reference ID is smaller than the frame ID. Every plane must carry the same
frame and reference IDs; Y uses full dimensions, chroma uses half dimensions.
There are exactly three packets and no trailing bytes. The codec implementation
bounds a complete access unit to 32 MiB; enclosing transport/memory negotiation
may impose a smaller independent limit. A frame exceeding a negotiated bound
must fail explicitly, never be truncated or silently resized.

Source IDs are separate from QUIC object IDs. A decoder needs the exact source
reference, not merely the preceding received QUIC object. A missing source
reference must trigger recovery. An independent repair/bootstrap frame has
reference zero and is marked as a keyframe by the producer. Predictive frames
must not be promoted to keyframes after queue loss.

## F4R2 plane packet

The 28-byte header contains `F4R2`, uint32 frame ID, uint32 reference ID,
uint32 width, uint32 height, int16 x translation, int16 y translation, and
IEEE CRC32 of the uncompressed residual payload. Translations are bounded to
[-64,64]; independent frames require zero translation.

The remainder is exactly one zlib stream, without trailing or concatenated
streams. Its uncompressed data contains:

1. One byte for each 64x64 region, row-major, rounded up at image edges.
   Values 0,1,2,3 select (0,0), (dx,0), (0,dy), (dx,dy), respectively.
   Independent frames require all zero modes.
2. A packed changed-block bitmask, little bit order, row-major. Luma blocks are
   8x8; chroma blocks are 4x4. Unused mask bits are zero.
3. Signed little-endian int16 predictor coefficients for each set bit, block
   order then row-major pixel order. Each selected block contains every component.

Prediction reads the previous reconstructed plane at the selected translation,
using zero outside its bounds. Residual blocks use the pinned learned causal
tree. Pixel zero stores its residual; each later pixel stores its residual minus
the residual at its earlier reference index. Reconstruction adds that reference
back. Every reconstructed residual is in [-255,255], and every in-bounds output
code must be in [0,255]. Encoders pad partial residual blocks with zero; decoders
ignore padded outputs after range validation.

Decode bounds the inflated byte count from dimensions, validates CRC, exact
payload lengths, modes, mask padding, predictor ranges and output ranges. No
plane failure may leave a usable partial whole-frame reference. Failed frames
invalidate all plane references; a later independent frame can recover.

## Color conversion and acceptance

BGRA input uses BT.709 luma coefficients (.2126,.7152,.0722). Chroma is averaged
over each 2x2 source block, scaled to 8-bit codes centered at 128, and clamped.
Output luma codes are `round(y8 * 876/255 + 64)`. Output chroma codes are
`clamp(round((c8-128) * 896/255 + 512),64,960)`. P010 stores these codes shifted
left by six. Neutral gray therefore stays at chroma code 512.

This contract addition is not a performance or device acceptance claim. Actual
product capture, forwarding, packet loss/recovery, iPad decoding and displayed
frame identity/cadence must be verified on the integrated profile.
