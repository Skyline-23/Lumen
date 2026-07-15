# Lumen IddCx package boundary

This directory contains the first-party UMDF2 package boundary. The C++ shim owns only WDF, IddCx, and runtime GPU-probe handles. The Rust static library owns the versioned lifecycle state machine and fixed queue admission. GPU frame acquisition and encoding are intentionally deferred to the later Windows media tasks.

Before `IddCxAdapterInitAsync`, the shim records `IddCxGetVersion`, calls `IddCxCheckOsFeatureSupport` on IddCx 1.11 or newer, creates real D3D devices on the selected hardware adapter, and asks the Rust core to pin its LUID. `LUMEN_IOCTL_QUERY_BACKEND_CAPABILITY` returns one packed exact backend row at a time: `values[0]` is the pinned LUID; `values[1]` contains backend in bits 0-7, surface kind in bits 8-15, hardware proof in bit 16, row count in bits 24-31, and IddCx version in bits 32-63. D3D12 is emitted only when both the OS feature flag and D3D12 device creation succeed.

The Windows driver project must be built with a 26H1 WDK that declares `IddCxCheckOsFeatureSupport`, `IDARG_OUT_FEATURES_SUPPORTED`, and the IddCx 1.11 D3D12 feature flag. The resulting 1.11 driver still checks the runtime version before calling the feature API on downlevel Windows.

The device interface is restricted to LocalSystem by `D:P(A;;GA;;;SY)`. Lumen's Windows service already runs as LocalSystem. File creation claims the sole owner; a second file object receives busy. Access-unit and event requests use overlapped direct I/O, admit at most four pending reads of each type, and cap payloads at 4 MiB and 256 bytes. The driver does not contain policy, authentication, networking, packetization, or unbounded queues.

Run the platform-neutral ABI and state-machine checks from macOS or Windows:

```bash
src/platform/windows/driver/scripts/test_driver_boundary.sh
```

Build and test-sign on an elevated Windows development host with Visual Studio 2022, the Desktop C++ workload, and a Windows 11 26H1 WDK exposing IddCx 1.11:

```powershell
src\platform\windows\driver\scripts\build_windows_driver.ps1 -TestSign
src\platform\windows\driver\scripts\test_windows_driver.ps1 `
  -PackageDirectory src\platform\windows\driver\build\package\x64\Release
```

The test harness stages the package with `pnputil`, creates one root-enumerated device with the WDK `devcon`, verifies an administrator is denied, and runs the owner, malformed, bounds, generation, cancellation, and repeated stop/restart cases as LocalSystem. Every probe is retained as a separate JSONL receipt. Failed QA always removes the root device, driver package, and exact imported test certificate; successful QA keeps the package only when `-KeepInstalled` is set.

The package follows Microsoft's [indirect display driver model](https://learn.microsoft.com/windows-hardware/drivers/display/indirect-display-driver-model-overview), [IddCx device initialization](https://learn.microsoft.com/windows-hardware/drivers/ddi/iddcx/nf-iddcx-iddcxdeviceinitconfig), [UMDF WDF directives](https://learn.microsoft.com/windows-hardware/drivers/wdf/specifying-wdf-directives-in-inf-files), [device-object SDDL](https://learn.microsoft.com/windows-hardware/drivers/kernel/sddl-for-device-objects), and [manual queue cancellation](https://learn.microsoft.com/windows-hardware/drivers/wdf/managing-i-o-queues). No Windows Driver Samples source is included.
