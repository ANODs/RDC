# RDC — Remote Desktop Control

A cross-platform remote desktop in Zig: macOS, Windows, Linux, then Android, iOS and the web. Talk to the user in Russian. Everything in the repository — code, comments, docs, UI, commit messages and release notes — is in English.

## Where things are
- `docs/PLAN.md` — goals, architecture, protocol, stability, and stages with acceptance criteria; section 17 — the usage scenarios and which of them work.
- Current milestone — M3 "Windows" (`docs/PLAN.md`, section 16): a host on the PC; the Mac and the PC control each other through a browser. The product's main focus is AI agents that control other devices.
- `src/agent/` — the agent side: `client.zig` (a viewer connection to a host: frames in, input out), `keys.zig` (key names → HID codes), `tools.zig` (the MCP tools and their descriptions), `mcp.zig` (JSON-RPC over stdio and Streamable HTTP, both protocol eras). `plugins/rdc/` — one plugin directory for Claude Code (`.claude-plugin/plugin.json` → the `rdc-mcp.mcpb` release asset), for Codex and other Agent Plugins clients (`plugin.json`, `mcp.json` → `scripts/rdc-mcp`), with the shared skill `skills/rdc/SKILL.md`. Marketplaces: `.claude-plugin/marketplace.json`, `.agents/plugins/marketplace.json`. `mcpb/manifest.json` + `tools/make_mcpb.sh` build the bundle.
- `src/net/` — the network. Local network: `http.zig`, `ws.zig`. From anywhere (`docs/PLAN.md`, section 6): `signal.zig` + `mqtt.zig` (the host finds browsers through public MQTT brokers; topic and AES-GCM key from the code and the link's key), `webrtc.zig` (one session: socket, ICE, glue), `stun.zig`, `sdp.zig`, `dtls.zig` (DTLS 1.2 server), `sctp.zig` (data channel). The browser side is in `web/viewer.js` (`rtcLink`, `signaling`).
- The viewer's microphone and camera as capture devices on the host (`docs/PLAN.md`, section 6): `src/platform/macos/mic_driver.c` — "RDC Microphone", a CoreAudio HAL plug-in (`mic_shm.h` — the shared-memory ring, `mic_writer.h` — the host's side, `mic_test.c` — the harness behind `zig build mic-check`; its own version is in `macos/RDCMicrophone-Info.plist`); `src/platform/windows/camera.c` — "RDC Camera", the media source of Windows 11's virtual camera, embedded in RDC.exe (`camera_pipe.h` — how RDC.exe feeds it). The browser side is `media` in `web/viewer.js`; the messages are in `src/core/proto.zig`.

- Permanent access (`docs/PLAN.md`, section 6): `src/core/totp.zig` (the seed, the link key, TOTP codes, the wrong-code guard), `src/core/qr.zig` (QR codes for the setup window), `Host.setPermanent`/`admitPermanentLocked` in `src/host.zig`, the Settings and "Permanent access" windows, start at login and keep-awake in `src/platform/macos/shim.m`. The browser side is `startPermanent` in `web/viewer.js`.

## Build
`ZIG=~/Applications/zig-0.17.1/zig`; run commands from the project root:
- `"$ZIG" build test` — tests of the pure modules (`src/tests.zig`)
- `"$ZIG" build mic-check` — loads a sanitized copy of the microphone driver through CFPlugIn, the way coreaudiod does, reads every property and plays samples through it. `zig-out/RDC.app/Contents/MacOS/rdc mic install` (or `remove`) puts the driver into `/Library/Audio/Plug-Ins/HAL` and restarts coreaudiod; it asks for the administrator password in a system dialog.
- `"$ZIG" build app -Doptimize=ReleaseSafe` — `zig-out/RDC.app`; `run-app` — build and open
- `"$ZIG" build package -Dtarget=x86_64-windows -Doptimize=ReleaseSafe` — `zig-out/package/RDC.exe` (built on the Mac; the log on the PC is `%LOCALAPPDATA%\RDC\rdc.log`)
- `zig-out/bin/rdc host --no-ui` — host without a window; the code and link are in the log `~/Library/Logs/RDC/rdc.log`
- `open -n zig-out/RDC.app --args --web-dir "$PWD/web"` — the viewer is served from `web/` without rebuilding; `--update-url URL` — updates from URL instead of GitHub (for testing)
- The link from anywhere without GitHub Pages: `python3 -m http.server 8765 --bind 127.0.0.1 --directory web`, then `open -n zig-out/RDC.app --args --remote-url http://localhost:8765/` and open the "From anywhere" link (localhost is a secure context, so WebCrypto and WebRTC work). `--no-remote` turns connections from anywhere off.
- `zig-out/bin/rdc mcp` — the MCP server on stdio (JSON-RPC, one message per line; the log goes to stderr and the file); `rdc mcp --http [PORT] [--token T] [--public] [--tunnel]` — Streamable HTTP. A quick check: pipe `{"jsonrpc":"2.0","id":1,"method":"tools/list"}` into it, or POST it to `http://127.0.0.1:7710/mcp`.
- `tools/make_mcpb.sh <version> <out.mcpb> --mac <rdc> --win <rdc.exe>` — the MCP bundle for Claude Desktop (CI does this in the release).
- The icon is `design/icon.svg`; `tools/make_icons.sh` renders it into `macos/RDC.icns`, `windows/rdc.ico`, `mcpb/icon.png`, `plugins/rdc/assets/icon.png` and `web/icon.png` (the favicon, served by the host at `/icon.png`). Edit the SVG, rerun the script, commit the results.
- `zig-out/bin/rdc` started from a shell has no Screen Recording permission; `zig-out/RDC.app` opened with `open -n` had it on 2026-11-09 (same identifier as the installed `~/Applications/RDC.app`). Otherwise, for a live test of screenshots connect to the installed RDC (its link is in `~/Library/Logs/RDC/rdc.log`).
- Ad-hoc signing with the designated requirement `identifier "com.anods.rdc"`: macOS permissions (Screen Recording, Accessibility) survive rebuilds and updates. If the permissions get stuck — `tccutil reset ScreenCapture com.anods.rdc` and `tccutil reset Accessibility com.anods.rdc` (the user runs these).
- The installed RDC is `~/Applications/RDC.app`; it updates itself. Builds from `zig-out` do not update themselves.

## Releases
- The version lives only in `build.zig.zon`; release notes are in `docs/releases/<version>.md`.
- GitHub Actions (`.github/workflows/release.yml`): on a `v<version>` tag or the Run workflow button — tests on macOS, Linux and Windows, the macOS archive, `RDC.exe`, `rdc-mcp.mcpb`, a signed `latest.json`, the release. Requires the `RDC_UPDATE_KEY` secret. `.github/workflows/pages.yml` publishes `web/` to GitHub Pages on every push to `main`.
- Locally: `"$ZIG" build release -Doptimize=ReleaseSafe` → `zig-out/release/` (archive, `latest.json`, `latest.json.sig`).
- The update signing key is `~/.config/rdc/update-signing.key` (not in git); the public key is in `src/core/update_key.zig`. New key: `zig run tools/release.zig -- keygen <file>`.

## How we work
- The goal is the milestone from section 16: work toward it without stopping to confirm steps, and show a working result. Before creating anything, check that it does not exist yet.
- Record user decisions in one line, without risks or caveats.
- Zig 0.17.1, pinned in `build.zig.zon`; on the Mac it is installed in `~/Applications/zig-0.17.1/`. Check the `std` API (`std.Io` since 0.16) and the 0.17 build system against the installed Zig sources, not from memory; verified notes are in `docs/zig-0.17-api.md`.
- The repository is public — `github.com/ANODs/RDC`, branch `main`. Commit only when the user asks, listing paths, without `git add -A`; the user pushes via GitHub Desktop.
- Line endings — LF (`.gitattributes`).
