# Lumen IddCx package boundary

This directory contains the first-party UMDF2 package boundary. The C++ shim owns only WDF and IddCx handles. The Rust static library owns the versioned lifecycle state machine and fixed queue admission. GPU acquisition and encoding are intentionally deferred to the later Windows media tasks.

The device interface is restricted to LocalSystem by `D:P(A;;GA;;;SY)`. Lumen's Windows service already runs as LocalSystem. File creation claims the sole owner; a second file object receives busy. Access-unit and event requests use overlapped direct I/O, admit at most four pending reads of each type, and cap payloads at 4 MiB and 256 bytes. The driver does not contain policy, authentication, networking, packetization, or unbounded queues.

Run the platform-neutral ABI and state-machine checks from macOS or Windows:

```bash
src/platform/windows/driver/scripts/test_driver_boundary.sh
```

Build and test-sign on an elevated Windows development host with Visual Studio 2022, the Desktop C++ workload, and WDK 10.0.26100 or newer:

```powershell
src\platform\windows\driver\scripts\build_windows_driver.ps1 -TestSign
src\platform\windows\driver\scripts\test_windows_driver.ps1 `
  -PackageDirectory src\platform\windows\driver\build\package\x64\Release
```

The test harness stages the package with `pnputil`, creates one root-enumerated device with the WDK `devcon`, verifies an administrator is denied, runs the owner/second-owner/malformed/oversize/stale/cancel cases as LocalSystem, queries the device with `pnputil`, and removes the package unless `-KeepInstalled` is set.

The package follows Microsoft's [indirect display driver model](https://learn.microsoft.com/windows-hardware/drivers/display/indirect-display-driver-model-overview), [IddCx device initialization](https://learn.microsoft.com/windows-hardware/drivers/ddi/iddcx/nf-iddcx-iddcxdeviceinitconfig), [UMDF WDF directives](https://learn.microsoft.com/windows-hardware/drivers/wdf/specifying-wdf-directives-in-inf-files), [device-object SDDL](https://learn.microsoft.com/windows-hardware/drivers/kernel/sddl-for-device-objects), and [manual queue cancellation](https://learn.microsoft.com/windows-hardware/drivers/wdf/managing-i-o-queues). No Windows Driver Samples source is included.
