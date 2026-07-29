# Windows settings UI design QA

## Reference and implementation

- Defect reference:
  `/var/folders/rz/b2b1bmx51d76nb2mfg3mlxfc0000gn/T/codex-clipboard-6b3f352a-547c-41c9-a1ec-9e0359e46f42.png`
  (2816 x 1940 pixels).
- Production source: `engine/lumen-host/ui/windows-app.slint`.
- Windows production-source captures:
  - General: `/private/tmp/lumen-ui-qa-3-fixed.png`
  - Input: `/private/tmp/lumen-ui-qa-6-fixed.png`
  - Advanced: `/private/tmp/lumen-ui-qa-8-fixed.png`
- Each implementation capture is a 1920 x 1240 physical-pixel snapshot of the
  production 960 x 620 logical window at 2x density.
- Combined full-view comparison:
  `/private/tmp/lumen-ui-reference-vs-implementation.png`. The defect reference
  was normalized to 1240 pixels high and placed beside the implementation
  capture before judging the final result.

## States verified

- General shows discovery enabled and prerelease notifications disabled.
- Input shows the configured default-on keyboard, mouse, controller, Right Alt,
  high-resolution scrolling, pen/touch, and rumble controls.
- Advanced represents preparation, state, and server commands as configured
  counts instead of fake disabled boolean switches.
- Sidebar destinations share one optical icon slot, the selected destination
  uses the Lumen orange treatment, and all icon/label pairs remain aligned.
- Settings labels are leading-aligned, trailing values and switches are
  centered vertically, dividers remain inside the card, and no labels,
  controls, or cards are clipped.

## Comparison history

- Initial P1: Advanced rendered non-boolean command collections as disabled
  switches. Replaced them with command-count rows.
- Initial P1: setting content was packed around the center of wide cards.
  Removed main-axis centering, gave labels the flexible width, and centered only
  the fixed trailing control.
- Initial P1: sidebar SVGs exposed inconsistent intrinsic optical bounds.
  Routed every icon through the same 22 x 22 slot and 18 x 18 image frame.
- Post-fix full views and focused General/Input/Advanced states contain no
  remaining P0, P1, or P2 visual findings.

## Evidence hashes

- Defect reference:
  `7d545757bf1aa3b6e49cbf40c01af6f0ca88a2208323cd5f77588b1f2548fb67`
- General:
  `8e3e46fcd7f360bce357529dcecb0678b6aa99761170b328a7f3bd0b9ba28f84`
- Input:
  `3ad74e25bbb84bec05cf93f5e44cb63c36048e2a242f891d1561df61924228d0`
- Advanced:
  `e03e247091c92480f096979d45e986067d884ab5007dde8492723c43d3646766`
- Combined comparison:
  `0f1541759ffb80107b4c2845e7eca94701e783196faff3e0dad6f4e198c7dc38`

final result: passed
