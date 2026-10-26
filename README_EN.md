# BoltKVM

[简体中文](README.md) | **English**

Low-latency screen control between two Macs. A single app bundle serves both roles: **Controlled Mac** (creates a virtual display and shares the screen, including headless Macs with no physical monitor attached) and **Controller** (renders the remote screen in a window or full screen and forwards keyboard, mouse, and trackpad scroll events). Designed primarily for direct Thunderbolt Bridge links—no relay servers, accounts, or internet access required. Both ends authenticate and encrypt traffic using a shared connection password.

## Key Characteristics

- **Pixel Equivalence**: Streams and renders at the controlled Mac's native 2× HiDPI backing resolution so text stays crisp without secondary scaling blur.
- **Low-Latency Interaction**: Capture-to-decode P95 < 33 ms; GUI capture-to-present P95 < 50 ms.
- **Audio Isolation by Default**: Zero audio capture or transmission unless explicitly enabled, leaving the controller's audio output untouched.
- **Unidirectional Control**: The controller only captures input and renders video, while the controlled Mac only captures the screen and injects input—eliminating feedback loops by topology.
- **Automatic Reconnect**: If the controlled Mac restarts its capture helper (resolution change, update) or the link drops briefly, the controller reconnects and shows the attempt count instead of freezing on the last frame. A wrong key still fails immediately.

## Measured Performance (2026-10-23)

| Metric | Target | Measured | Status |
|---|---|---|---|
| Visual fidelity | SSIM > 0.98 | SSIM **0.984** | Pass |
| Decode throughput | 60 fps | **57.6–58.0 fps** | Pass |
| Capture-to-decode latency | P95 < 33 ms | P95 **25.4–27.0 ms** | Pass (all 20 sampling windows within 33 ms) |
| GUI capture-to-present latency | P95 < 50 ms | P50 **31.0 ms**, P95 **33.2 ms**, 60.0 fps | Pass ([B5 Latency Report](docs/reports/2026-10-23-b5-latency.md)) |
| Stability | 8-hour soak | 8h00m01s: 0 disconnects, 0 decode errors, 0 watchdog rebuilds | Pass |
| Audio | 0 bytes by default | Off by default; 1.54 Mbps / −34 dBFS when enabled, RSS 134→135 MB over 12 min | Pass (optional) |
| Input continuity | 8 hours without dropped events | 466 forwarded batches over 8h, 0 tap failures (CLI client; 8h GUI soak pending) | Partial |

Decode latency and GUI presentation latency are tracked separately: capture-to-decode P95 stays under 27 ms, while the GUI renderer triggers `MTKView.draw()` immediately upon frame arrival rather than waiting for the next display vsync tick, keeping capture-to-present P95 at 33.2 ms. See the [B5 Latency Report](docs/reports/2026-10-23-b5-latency.md) and [Audio & GUI Stability Report](docs/reports/2026-10-23-audio-and-gui-stability.md) for raw logs.

## Architecture

```text
[Controlled Mac]                                  [Controller]
Virtual Display (default 3008×1692 logical @2x → 6016×3384 pixels, configurable)
        │
ScreenCaptureKit capture
        │
VideoToolbox encode (ProRes 422 / HEVC) ── TCP ──► VideoToolbox decode
                               (Thunderbolt Bridge)        │
CGEvent injection         ◄── input & audio ────── CGEvent/NSEvent capture + Metal present
```

- **Transport & Security**: Raw TCP with a 20-byte big-endian frame header (`TCP_NODELAY` enabled). After HMAC-SHA256 challenge–response authentication, both peers exchange ephemeral X25519 public keys and derive directional session keys with HKDF-SHA256 over the pre-shared key. Every frame is sealed with ChaCha20-Poly1305 (frame header bound as AAD), providing forward secrecy and automatic rekeying every $2^{20}$ packets.
- **Video Codec**: Defaults to ProRes 422 ([ADR-0003](docs/adr/0003-prores-422-primary.md)); switchable to HEVC via `--codec hevc`.

## App Mode (Recommended)

```bash
./Packaging/build-app.sh    # Build release binaries and assemble dist/BoltKVM.app
open dist/BoltKVM.app       # Choose a role on first launch; switch anytime under the "Role" menu
```

A single app bundle supports both roles:

**Controlled Mac** (menu bar agent, no Dock icon or main window)

- The settings panel displays resolution, picture quality, port, connection password with fingerprint, service status, TCC permission shortcuts, and log access;
- Screen capture and virtual display creation run inside the bundled `boltkvm-server` helper process, which automatically restarts 3 seconds after an unexpected exit;
- Clicking **New password…** generates a fresh password and restarts the server, immediately invalidating the old password.

**Controller** (single window)

- Opens to the saved host list—double-click a host to connect, or click **Edit** to configure display name, IP address, port, resolution, password, and input/audio toggles per host;
- The video window automatically locks its aspect ratio to match the remote display;
- The centered toolbar provides **Mission Control** and **Desktop** shortcuts for the remote Mac, with live `fps · Mbps` metrics on the right; in full screen, the toolbar auto-hides and reveals when the pointer reaches the top edge;
- Closing the video window disconnects the session and returns to the host list;
- Keyboard and mouse events are forwarded only while the pointer is inside the video view. Pressing keys or mouse buttons and then moving the pointer out, unfocusing the window, or disconnecting automatically synthesizes release events; modifier flags are also reconciled before each key event to prevent stuck modifiers.

The UI is localized in English and Simplified Chinese (`Packaging/Resources/{en,zh-Hans}.lproj/Localizable.strings`).

## Required Permissions

| Role | Permission | Purpose |
|---|---|---|
| Controlled Mac | Screen Recording | Required by ScreenCaptureKit; the server cannot start without it |
| Controlled Mac | Accessibility | Required by CGEvent to inject keyboard and mouse events (view-only without it) |
| Controller | Local Network (macOS 15+) | Required to reach Thunderbolt Bridge or LAN addresses (`No route to host` if denied) |

The controller app uses window-local `NSEvent` monitors for keyboard and mouse capture and does not require **Input Monitoring** permission (only the CLI `--input` full-screen mode uses `CGEventTap` and requires Input Monitoring).

By default, `build-app.sh` uses ad-hoc code signing (`-`). Because every rebuild changes the binary `cdhash`, macOS TCC treats each build as a new application and re-prompts for permissions. For local development, create and trust a persistent self-signed certificate once:

```bash
./scripts/make-signing-identity.sh                                  # Create and trust "BoltKVM Local"
BOLTKVM_CODESIGN_IDENTITY="BoltKVM Local" ./Packaging/build-app.sh
```

To regenerate the app icon: `swift scripts/make-icon.swift Packaging/AppIcon.icns`.

## Quick Start

### 1. Build and Deploy

```bash
./Packaging/build-app.sh
```

Copy `dist/BoltKVM.app` to `/Applications` on both Macs. If SSH access to the controlled Mac is configured, `./scripts/deploy-app.sh <remote-host>` builds, uploads, stops any previous instance, and launches the app automatically.

### 2. Set Up the Controlled Mac

Launch the app, select **As the controlled Mac**, grant **Screen Recording** and **Accessibility** permissions as prompted, and relaunch.

On first start, an 8-character connection password is written to `~/.boltkvm-key` (`0600`) and shown at the bottom of the panel:

```text
Connection password abcdefgh (enter once on the client)  Fingerprint E0AF 9869 0698 8829
```

To enable audio capture in app mode on the controlled Mac:

```bash
defaults write io.github.boltkvm server.audio -bool true
```

Then stop and restart the server from the menu bar icon.

### 3. Set Up the Controller

Launch the app, select **As the controller**, click **Add Remote Mac**, and enter the display name, Thunderbolt Bridge IP address, port (default `7474`), and the 8-character connection password from the controlled Mac.

- **8-Character Connection Password**: Lowercase letters and digits with lookalikes (`0/o/1/l/i`) removed; case, spaces, and hyphens are ignored on input. Stretched to a 32-byte key via PBKDF2-HMAC-SHA256 (120,000 iterations).
- **256-Bit Static Key**: For higher entropy, click **256-bit key…** on the controlled Mac panel to generate a 64-character hex key and paste it into the controller's password field.
- **Fingerprint Verification**: Both ends display a 16-character hex fingerprint (first 8 bytes of SHA-256) so you can confirm the keys match.
- **Credential Storage**: Controller passwords are stored per host under `~/Library/Application Support/BoltKVM/keys/` (`0600`) rather than the macOS Keychain, avoiding repeated Keychain prompts across local rebuilds.

**Note**: Always enter the literal IP address of the Thunderbolt Bridge interface rather than a `.local` or custom hostname—local proxy tools with fake-ip DNS interception can hijack hostnames and reset the connection.

### 4. Connect

Double-click the host or click **Connect**. Changing the resolution in the host editor automatically rebuilds the remote virtual display on the next connection; picture quality (**Standard** caps stream width at 3840, **Sharp** streams the full 2× backing pixels) can be toggled from the controlled Mac's menu bar or settings panel.

The resolution presets are shared by the controlled Mac's menu, the settings panel, and the host editor: the first two are this project's targets, 3008×1692 (Thunderbolt bridge / 32-inch display) and 1728×1117 (MacBook Pro panel), followed by 1920×1080, 2560×1440, 2880×1620, and 3840×2160. Custom sizes still accept any width and height within range.

## Command-Line Interface (CLI)

The `boltkvm` CLI shares `BoltKVMCore` with the GUI app and is used for scripted verification and long-running soak tests:

```bash
# Start the server
.build/release/boltkvm server --width 3840 --height 2160 --port 7474 --seconds 0

# Start the client (full-screen Metal render + input capture + auto-reconnect)
.build/release/boltkvm client --host <server-ip> --port 7474 --seconds 28800 \
  --render --switch-mode --input --reconnect

# Run the test suite (48 XCTest unit tests; falls back to CLI self-tests on CLT-only machines)
./scripts/test.sh

# Protocol and crypto self-tests (no TCC permissions required)
.build/release/boltkvm selftest
.build/release/boltkvm cryptotest

# Diagnostics
.build/release/boltkvm displays      # List active displays with logical and pixel dimensions
.build/release/boltkvm doctor        # Check TCC permission status
.build/release/boltkvm keygen        # Generate a connection password and print its fingerprint
```

Common server flags:

```bash
--virtual-display builtin          # Built-in CGVirtualDisplay (default); "external" uses an existing display
--virtual-display-size 3008x1692   # Logical resolution of the virtual display
--bind auto                        # Bind only bridge* interfaces by default; pass 127.0.0.1 for loopback tests
--audio                            # Enable system audio capture (48 kHz stereo Float32 PCM, ~1.5 Mbps)
--codec hevc                       # Use HEVC instead of the default ProRes 422 encoder
```

Soak and rescue helper scripts:

```bash
./scripts/soak-preflight.sh --host <ip>         # Verify caffeinate, power assertions, ports, and stale processes
./scripts/soak-monitor.sh --client-log <path>   # Sample client liveness and latency metrics every 5 minutes
./scripts/rescue.sh --host <ip>                 # Probe SSH (22), VNC (5900), and BoltKVM (7474) reachability
```

## Releases

Pushing a `v*` tag triggers GitHub Actions to build, run self-tests, package and sign the app bundle, and publish a GitHub Release:

```bash
git tag v0.2.0 && git push origin v0.2.0
```

See [docs/releasing.md](docs/releasing.md) for code signing and notarization details.

## Recovery After a Controlled Mac Reboot

```text
Reboot ──► SSH ready ──► Auto-login into Aqua desktop session
                           ├─ Login Item launches BoltKVM.app
                           ├─ App spawns boltkvm-server, creates virtual display, listens on port 7474
                           └─ If stuck at the lock screen → unlock via macOS Screen Sharing (vnc://<ip>)
```

- Run `./scripts/rescue.sh --host <ip>` to check SSH (`22`), VNC (`5900`), and BoltKVM (`7474`) in one step;
- Use **Launch at Login** inside `BoltKVM.app` to supervise the server rather than running the raw CLI binary under `launchd` directly (`launchd` daemons lack a GUI responsible-process identity for Screen Recording TCC).

## Known Limitations

- **Pre-Shared Password Authority**: Any party holding the password can connect and control the remote Mac (past recorded sessions remain protected by X25519 forward secrecy). Rotate the password immediately via **New password…** if exposed; see [ADR-0004](docs/adr/0004-psk-over-pairing-code.md).
- **Single Virtual Display**: Having two high-resolution virtual displays active simultaneously causes ScreenCaptureKit frame rates to drop to 3–8 fps. Use `boltkvm displays` to inspect active displays and terminate external virtual display tools if needed.
- **No Thunderbolt Bridge**: The controlled Mac still creates and keeps its virtual display (so its resolution can be changed from the menu while accessed through a remote desktop or screen sharing), but does not listen for BoltKVM clients until a bridge appears. The menu bar shows "Display ready, waiting for network"; plugging in the cable starts listening without rebuilding the display. This prevents the helper from restarting in a loop and the desktop from flipping between two resolutions.
- **Stale Server Processes**: Ensure no orphaned `boltkvm server` process is running before starting the CLI server manually, or `SCStream` initialization may hang.
- **Secure Input & Lock Screen**: macOS blocks session-level event capture and injection while the lock screen or a Secure Input password field is active; use built-in macOS Screen Sharing (VNC) to unlock a locked screen.
- **Single-Monitor Streaming**: The server creates and captures a single virtual display per session.

## Milestones

Background and target metrics are documented in the [Project Charter](docs/design/project-charter.md).

- [x] **M0 Preflight**: Virtual display and Thunderbolt Bridge baseline ([report](docs/reports/2026-10-21-m0-display.md))
- [x] **M1 Visual Equivalence**: Capture → hardware encode → direct TCP → hardware decode → Metal present at 60 fps, SSIM 0.984 ([report](docs/reports/2026-10-21-m1-pipeline.md))
- [x] **M2 Input Pipeline**: System shortcuts, modifier synchronization, and continuous scroll phases ([report](docs/reports/2026-10-21-m2-input.md))
- [x] **M3 Stability**: TCC preflight, auto-reconnect, 8-hour soak test, and input continuity ([report](docs/reports/2026-10-22-m3-soak-8h.md))
- [x] **App Packaging**: Dual-role app bundle, built-in virtual display, multi-host manager, optional audio, and CI releases ([report](docs/reports/2026-10-22-app-conversion.md))

## Documentation Index

> Detailed design documents, ADRs, plans, and verification reports under `docs/` are maintained in Chinese.

- [Project Charter](docs/design/project-charter.md)
- [Open Items](docs/plans/open-items.md)
- [Release Guide](docs/releasing.md)
- [Connection Manager Design](docs/plans/2026-10-22-connection-manager-design.md)
- [B5 Frame Rate & Latency Report](docs/reports/2026-10-23-b5-latency.md)
- [Audio & GUI Stability Report](docs/reports/2026-10-23-audio-and-gui-stability.md)
- [Transport Encryption Report](docs/reports/2026-10-22-transport-encryption.md)
- [Architecture Decision Records (ADR)](docs/adr/), [Verification Reports](docs/reports/), [Plans](docs/plans/)

## Requirements

- macOS 15+ on Apple Silicon;
- Direct Thunderbolt Bridge connection, or any routable LAN IP connection;
- Swift 6 / Xcode Command Line Tools to build from source.

## Contributing

Read [AGENTS.md](AGENTS.md) before submitting changes. Every self-contained change must build cleanly, pass tests, and update relevant documentation in the same commit.

## License

[MIT](LICENSE). Third-party license notices are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
