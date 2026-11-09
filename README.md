# RDC — Remote Desktop Control

Lightweight, low-latency cross-platform remote desktop written in Zig.

> Status: milestone M1. A Mac shares its screen to any browser: on the local network via a link or a 9-digit code, and from anywhere via a link that opens the viewer from GitHub Pages and connects over WebRTC. Architecture, protocol and roadmap: [docs/PLAN.md](docs/PLAN.md).

## Features

- Your Mac's screen in any browser on the same network: open the link or enter the code.
- From anywhere — a phone on mobile data, another network: the RDC window shows a second link that opens the viewer from [GitHub Pages](https://anods.github.io/RDC/). The page finds the computer through public MQTT brokers, with the handshake sealed by a key from the link, and connects to it directly over WebRTC. No servers of our own, no relay, nothing to install on the phone.
- Full mouse and keyboard control. On phones, a touchpad mode: tap for left click, double tap for right click, two fingers to scroll. Esc on the viewer's keyboard ends the session; the Esc of the on-screen keyboard is the one that goes to the computer.
- Your phone as the computer's microphone or camera: the viewer's **Camera and mic** button lends them, and on the computer they are ordinary devices, "RDC Microphone" and "RDC Camera", that any app can pick — see [below](#phone-as-a-microphone-and-camera).
- On-screen keyboard that matches the host OS (⌘/⌥/⌃ for macOS, Ctrl/Win/Alt for Windows), with OS-specific shortcuts. It can be moved, resized, docked and hidden.
- H.264 via WebCodecs where the browser supports it, JPEG otherwise.
- Automatic updates from GitHub Releases, verified with an Ed25519 signature.
- An MCP server for AI agents (Claude, Codex, ChatGPT and any other MCP client): the agent sees the screen and controls the mouse and keyboard, and the person at the computer can stop it at any time.
- Tiny: the whole app is a ~600 KB download, its WebRTC stack included (written in Zig on `std.crypto`).

## AI agents

RDC is also a tool for AI agents: `rdc mcp` is an [MCP](https://modelcontextprotocol.io) server with `connect`, `screenshot`, `click`, `move`, `drag`, `scroll`, `type`, `key`, `wait`, `devices` and `disconnect`. The agent connects with the link from the RDC window on the computer to control and works from screenshots; every action answers with a fresh one. The person at that computer sees "AI agent …" in the RDC window and in the browser viewer, with a **Stop** button.

| Where the agent runs | How to install |
|---|---|
| Claude Code | `claude plugin marketplace add ANODs/RDC`, then `claude plugin install rdc@rdc` |
| Claude Desktop | download `rdc-mcp.mcpb` from [Releases](https://github.com/ANODs/RDC/releases) and open it |
| Codex (CLI or the ChatGPT desktop app) | `codex plugin marketplace add ANODs/RDC`, then install **RDC** from `/plugins` |
| claude.ai, ChatGPT in a browser | run `rdc mcp --http --tunnel` on your computer and add the printed URL as a custom connector (needs [cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/)) |
| Any other MCP client | `{"command": "<path to rdc>", "args": ["mcp"]}` |

`rdc mcp` options: `--name NAME` (how the agent is shown on the controlled computer), `--http [PORT]` (Streamable HTTP on 127.0.0.1:7710 instead of stdio), `--public` (listen on every interface; a token is required or generated), `--token T` (the secret, as the path `/mcp/T` or `Authorization: Bearer T`; also `RDC_MCP_TOKEN`), `--tunnel` (a Cloudflare quick tunnel, prints the public URL).

## Phone as a microphone and camera

The device that opened the viewer — a phone, a laptop — can lend its microphone and camera to the computer. There they show up as capture devices, so any app can use them: record a voice message in the Claude app through the phone's microphone, or join a call with the phone as the camera.

1. On the computer, enable the device once (the table below).
2. On the phone, open the **From anywhere** link from the RDC window — browsers give the microphone and camera only to secure pages, and the plain `http://<ip>` link on the local network is not one. Then **Camera and mic** on the toolbar, and switch on what you need.
3. On the computer, pick **RDC Microphone** (or **RDC Camera**) in the app. The RDC window shows what is live, with a **Stop** button.

| Computer | Microphone | Camera |
|---|---|---|
| macOS 14.4+ | "RDC Microphone": **Enable phone microphone** in the RDC window, once, with the administrator password (sound pauses for a second). Remove it in Settings, or `rdc mic remove`. | Not available: macOS takes cameras only from an extension signed with a paid Apple developer account. |
| Windows 11 | Not available: Windows has no way to add a microphone without a kernel driver. | "RDC Camera": registered by RDC when it starts as administrator, or with **Enable phone camera** in its window. Built, not yet run on a PC. |
| Windows 10 | Not available. | Not available: the virtual camera API came with Windows 11. |

Audio travels as 48 kHz PCM and video as JPEG frames, over the same connection as the screen. On a Mac with the browser on the same machine the microphone arrives 70 ms later; expect about 100 ms on a home network and under 300 ms on mobile data. One viewer at a time lends its devices.

## Download

Prebuilt builds are on the [Releases](https://github.com/ANODs/RDC/releases) page. Unzip the archive, move RDC.app to Applications, and grant it Screen Recording and Accessibility permissions. After that, RDC keeps itself up to date (auto-update toggle in Settings, ⌘,).

## Build from source (macOS 14.4+, Zig 0.17.1)

```sh
zig build run-app -Doptimize=ReleaseSafe
```

RDC shows a code and two links. Open the first one in a browser on any device on the same network, or open `http://<computer IP>:7700/` and enter the code. The second one, "From anywhere", works from any network; `--no-remote` turns it off. On first launch, allow RDC Screen Recording and Accessibility (System Settings → Privacy & Security), then restart it.

Tests: `zig build test`; `zig build mic-check` loads the microphone driver the way macOS does and plays samples through it. Local release build: `zig build release -Doptimize=ReleaseSafe`. CI releases: [.github/workflows/release.yml](.github/workflows/release.yml).

On Windows RDC asks to start as administrator (the UAC prompt): then clicks and keys reach apps that run as administrator, and RDC adds its own rule to Windows Firewall so viewers can connect. Declined, it runs with your rights. `rdc mcp` never asks.

## Goals

- LAN latency from capture to display of 16 ms or less.
- Binary of 3 MB or less on Windows and Linux, 6 MB or less on macOS. No installer, runtimes or bundled libraries.
- A static screen sends zero frames and almost no traffic.
- End-to-end encryption (Noise over UDP): servers and relays never see the picture or the input.
- No input is ever lost or duplicated; a failure means a pause, not a disconnect.
- Self-hosted ID and relay server: one static binary for any VPS.

## Platforms

| OS | Role |
|---|---|
| macOS 14.4+ | host and viewer |
| Windows 10/11 | host and viewer (planned) |
| Linux (X11, Wayland) | host and viewer (planned) |
| Android | viewer and host (planned) |
| iOS / iPadOS | viewer and screen sharing (planned) |
| Browser | viewer |

## License

Copyright 2026 Timoshkin Timofey. RDC is open source under the [Apache License 2.0](LICENSE).
