# Lumen

Lumen is a self-hosted desktop streaming host for Windows and macOS. It is built around low-latency capture, native client resolution, HDR-aware streaming, hardware encoding, and a web control surface for pairing, configuration, and application launch management.

Lumen keeps compatibility with existing GameStream-style clients where practical, while the active product direction is the Lumen host plus the Shadow client protocol.

## Features

- [x] Built-in Virtual Display with HDR support that matches the resolution/framerate config of your client automatically
- [x] Permission management for clients
- [x] Clipboard sync
- [x] Commands for client connection/disconnection
- [x] Input only mode
- [x] Source-neutral Lumen streaming protocol adapters for Windows and macOS
- [x] macOS app target backed by the shared protocol bridge

## Usage

The active Lumen host targets are Windows and macOS. Apple-platform bootstrap notes live in
`docs/tuist-bootstrap.md`, and the shared stream protocol contract lives in `docs/protocol/lumen-streaming-protocol.md`.

## About Permission System

Manage device permissions directly from the Lumen web UI.

> [!NOTE]
> The **FIRST** client paired with Lumen will be granted with FULL permissions, then other newly paired clients will only be granted with `View Streams` and `List Apps` permission. If you encounter `Permission Denied` error when trying to launch any app, go check the permission for that device and grant `Launch Apps` permission. The same applies to the situation when you find that you can't move mouse or type with keyboard on newly paired clients, grant the corresponding client `Mouse Input` and `Keyboard Input` permissions.

## About Virtual Display

> [!WARNING]
> ***It is highly recommended to remove other virtual display solutions from your system and Lumen config to reduce conflicts and compatibility issues.***

> [!NOTE]
> **TL;DR** Treat each streaming client like a dedicated PnP monitor managed by Lumen.

Lumen uses SudoVDA for virtual display. It features auto resolution and framerate matching for connected clients. The virtual display is created when a stream starts and removed when the app quits. **If you do not see a new virtual display added or removed when the stream starts or stops, there may be a driver misconfiguration, or another persistent virtual display might still be active.**

The virtual display works like a physically attached monitor with SudoVDA. Unlike solutions that reuse one identity or generate a random identity for every virtual display session, **Lumen assigns a fixed identity for each client, so your display configuration can be remembered and managed by Windows natively.**

## Configuration for dual GPU laptops

Lumen supports dual GPUs seamlessly.

If you want to use your dGPU, just set the `Adapter Name` to your dGPU and enable `Headless mode` in `Audio/Video` tab, save and restart your computer. No dummy plug is needed any more, the image will be rendered and encoded directly from your dGPU.

## About HDR

HDR starts supporting from Windows 11 23H2 and generally supported on 24H2. Some systems might not have HDR toggle on 23H2 and you just need to upgrade to 24H2. Any system lower than 23H2/Windows 10 will not have HDR option available.

> [!NOTE]
> The below section is written for professional media workers. It doesn't stop you from enabling HDR if you know what you're doing and have deep understanding about how HDR works.
>
> Lumen and SudoVDA can handle HDR just fine like any other streaming solutions.
>
> If you have had good experience with HDR previously, you can safely ignore this section.
>
> If you're curious, read on, but don't blame Lumen for poor HDR support.

Whether HDR streaming looks good, it depends completely on your client.

In short, ICC color correction should be totally useless while streaming HDR. It's your client's job to get HDR content displayed right, not the host. But in fact, it does affect the captured video stream and reflect changes on devices that can handle HDR correctly. On other devices that can't, the info is not respected at all.

It's very complicated to explain why HDR is a total mess, and why enabling HDR makes the image appear dark/yellow. If it's your first time got HDR streaming working, and thinks HDR looks awful, you're right, but that's not Lumen's fault, it's your device that tone mapped SDR content to the maximum of the capability of its screen, there's no headroom for anything beyond that actual peak brightness for HDR.

For client devices, usually Apple products that have HDR capability can be trusted to have good results, other than that, your luck depends.

<details>
<summary>DEPRECATION ALERT</summary>

Enabling HDR is **generally not recommended** with **ANY streaming solutions** at this moment, probably in the long term. The issue with **HDR itself** is huge, with loads of semi-incompatible standards, and massive variance between device configurations and capabilities. Game support for HDR is still choppy.

SDR actually provides much more stable color accuracy, and are widely supported throughout most devices you can imagine. For games, art style can easily overcome the shortcoming with no HDR, and SDR has pretty standard workflows to ensure their visual performance. So HDR isn't *that* important in most of the cases.

</details>

## How to run multiple instances of Lumen for multiple virtual displays

This workflow is still being rewritten for the Lumen control surface.

## FAQ
The legacy Lumen wiki has not been migrated yet.

## Stuttering Clinic
Latency tuning guidance is being consolidated into the Lumen docs and web UI profiles.

## Device specific setups
- Pixel devices might not be able to use native resolution:
  - Change the device resolution to High.

## System Requirements

> **Warning**: This table is a work in progress. Do not purchase hardware based on this.

**Minimum Requirements**

| **Component** | **Description** |
|---------------|-----------------|
| GPU           | AMD: VCE 1.0 or higher, see: [obs-amd hardware support](https://github.com/obsproject/obs-amd-encoder/wiki/Hardware-Support) |
|               | Intel: VAAPI-compatible, see: [VAAPI hardware support](https://www.intel.com/content/www/us/en/developer/articles/technical/linuxmedia-vaapi.html) |
|               | Nvidia: NVENC enabled cards, see: [nvenc support matrix](https://developer.nvidia.com/video-encode-and-decode-gpu-support-matrix-new) |
| CPU           | AMD: Ryzen 3 or higher |
|               | Intel: Core i3 or higher |
| RAM           | 4GB or more |
| OS            | Windows: 10+ (Windows Server requires [manual installation](https://github.com/nefarius/ViGEmBus/issues/153) for gamepad support) |
|               | macOS: 12+ |
| Network       | Host: 5GHz, 802.11ac |
|               | Client: 5GHz, 802.11ac |

**4k Suggestions**

| **Component** | **Description** |
|---------------|-----------------|
| GPU           | AMD: Video Coding Engine 3.1 or higher |
|               | Intel: HD Graphics 510 or higher |
|               | Nvidia: GeForce GTX 1080 or higher |
| CPU           | AMD: Ryzen 5 or higher |
|               | Intel: Core i5 or higher |
| Network       | Host: CAT5e ethernet or better |
|               | Client: CAT5e ethernet or better |

**HDR Suggestions**

| **Component** | **Description** |
|---------------|-----------------|
| GPU           | AMD: Video Coding Engine 3.4 or higher |
|               | Intel: UHD Graphics 730 or higher |
|               | Nvidia: Pascal-based GPU (GTX 10-series) or higher |
| CPU           | AMD: todo |
|               | Intel: todo |
| Network       | Host: CAT5e ethernet or better |
|               | Client: CAT5e ethernet or better |

## Clients

Shadow Client is the first-party client direction for Lumen. Other GameStream-compatible clients may still work through compatibility paths, but new protocol work targets Shadow first.

## Integrations

SudoVDA: Virtual Display Adapter Driver used in Lumen.

## Support

Support is provided through GitHub Issues and Discussions.

## Downloads

### Direct Download

**Recommended**

[Releases](https://github.com/Skyline-23/Lumen/releases)

### WinGet

**Note:** Community maintained

In an elevated PowerShell window, run

```pwsh
winget install Skyline-23.Lumen

```

You'll need WinGet installed first.

### Chocolatey

**Note:** Community maintained

You can also install the Lumen streaming host with chocolatey.

Install Chocolatey if you don't have it, then run the following command in an elevated PowerShell/CMD window:

```pwsh
choco upgrade lumen -y 
```

Same command can be used to upgrade, add to a scheduled task to automate updates.

See more details on the chocolatey package [here](https://community.chocolatey.org/packages/lumen)

## Attribution

Lumen builds on open streaming, capture, and client compatibility work from the wider GameStream ecosystem. Legacy compatibility names are retained only where they describe protocol behavior, third-party dependencies, or source attribution.

## License

GPLv3
