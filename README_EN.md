# BoltKVM

[简体中文](README.md) | **English**

Low-latency screen control between two Macs. A single app bundle serves both roles: **Controlled Mac** (creates a virtual display and shares the screen, including headless Macs with no physical monitor attached) and **Controller** (renders the remote screen in a window or full screen and forwards keyboard, mouse, and trackpad scroll events). Designed primarily for direct Thunderbolt Bridge links—no relay servers, accounts, or internet access required. Both ends authenticate and encrypt traffic using a shared connection password.

## Key Characteristics

- **Pixel Equivalence**: Streams and renders at the controlled Mac's native 2× HiDPI backing resolution so text stays crisp without secondary scaling blur.
- **Low-Latency Interaction**: Capture-to-decode P95 < 33 ms; GUI capture-to-present P95 < 50 ms.
- **Audio Isolation by Default**: The controlled Mac captures and sends no audio, and does not pause, mute, or change its volume, unless the controller explicitly selects audio (or requests record-only capture) for that host. When selected, the controlled Mac mutes its local output but keeps the source playing, so the controller hears the full stream. Closing the controller sends a pause request first; the controlled Mac waits until its player reports stopped before restoring the output, so no audio leaks out during teardown.
- **Unidirectional Control**: The controller only captures input and renders video, while the controlled Mac only captures the screen and injects input—eliminating feedback loops by topology.
- **Automatic Reconnect**: If the controlled Mac restarts its capture helper (resolution change, update) or the link drops briefly, the controller reconnects and shows the attempt count instead of freezing on the last frame. A wrong key still fails immediately.

## Download & Install

Grab the latest `BoltKVM-<version>.zip` and its `.sha256` from [Releases](https://github.com/haitau/boltkvm/releases). The latest published release is **v0.13**. It includes 24-bit/48 kHz audio, authentication/key-release fixes, and the audio lifecycle fixes; the `v0.13` tag and release are published:

```bash
V=0.13
unzip BoltKVM-$V.zip -d BoltKVM-$V
shasum -a 256 -c BoltKVM-$V.zip.sha256
open BoltKVM-$V/BoltKVM.app
```

Release builds are ad-hoc signed: allow the app in **System Settings → Privacy & Security** on first launch. For stable TCC grants, create and trust a local certificate as described under **Required Permissions**, or build from source.

## Measured Performance (2026-10-23)

| Metric | Target | Measured | Status |
|---|---|---|---|
| Visual fidelity | SSIM > 0.98 | SSIM **0.984** | Pass |
| Decode throughput | 60 fps | **54.1–58.0 fps** (three runs) | Pass |
| Capture-to-decode latency | P95 < 33 ms | P95 **25.4–27.0 ms** | Pass (all three decode runs stayed under 33 ms) |
| GUI capture-to-present latency | P95 < 50 ms | P50 **31.0 ms**, P95 **33.2 ms**, 60.0 fps | Pass ([B5 Latency Report](docs/reports/2026-10-23-b5-latency.md)) |
| Stability | 8-hour soak | 8h00m01s: 0 disconnects, 0 decode errors, 0 watchdog rebuilds | Pass |
| Audio | 0 bytes by default | No capture or transmission unless the controller explicitly selects audio. When enabled: 48 kHz stereo, 16-bit at 1.54 Mbps (measured: −34 dBFS, RSS 134→135 MB over 12 min) or 24-bit at 2.30 Mbps (0.13, format verified end to end) | Pass (16-bit measured; 24-bit transport and close/route behavior measured and user-retested on 0.13 (245); dedicated 24-bit listening not separately recorded) |
| Input continuity | 8 hours without dropped events | 466 forwarded batches over 8h, 0 tap failures (CLI client; the probe delivered 458 events, so the 8-event difference is unverified; GUI client 8-hour run confirmed by the user on 2026-10-28) | Pass |

Decode latency and GUI presentation latency are tracked separately: capture-to-decode P95 stays under 27 ms, while the GUI renderer triggers `MTKView.draw()` immediately upon frame arrival rather than waiting for the next display vsync tick, keeping capture-to-present P95 at 33.2 ms. See the [B5 Latency Report](docs/reports/2026-10-23-b5-latency.md) and [Audio & GUI Stability Report](docs/reports/2026-10-23-audio-and-gui-stability.md) for raw logs.

## Architecture

```text
[Controlled Mac]                                  [Controller]
Virtual Display (app default 3008×1692 logical @2x → 6016×3384 pixels, configurable; CLI defaults to 3840×2160 capture with a 1920×1080 logical display)
        │
ScreenCaptureKit capture
        │
VideoToolbox encode (ProRes 422 / HEVC) ── TCP ──► VideoToolbox decode
                               (Thunderbolt Bridge)        │
CGEvent injection         ◄── input & audio ────── CGEvent/NSEvent capture + Metal present
```

- **Transport & Security**: Raw TCP with a 20-byte big-endian frame header (`TCP_NODELAY` enabled). After HMAC-SHA256 challenge–response authentication, both peers exchange ephemeral X25519 public keys and derive directional session keys with HKDF-SHA256 over the pre-shared key. Every frame is sealed with ChaCha20-Poly1305 (frame header bound as AAD), providing forward secrecy. Keys are negotiated per connection; there is no periodic packet-count rekey.
- **Video Codec**: Defaults to ProRes 422 ([ADR-0003](docs/adr/0003-prores-422-primary.md)); switchable to HEVC via `--codec hevc`.

## App Mode (Recommended)

```bash
./scripts/install-app.sh    # Build, sign, install to /Applications, and launch
```

Choose a role on first launch; switch anytime under the **Role** menu. To assemble `dist/BoltKVM.app` without installing it, run `./Packaging/build-app.sh`. The install script stages the previous bundle only for the duration of the swap, restores it on failure, and deletes it on success, so it never leaves a `.bak` in `/Applications`; signing prefers the stable local **BoltKVM Local** certificate.

A single app bundle supports both roles:

**Controlled Mac** (menu bar agent, no Dock icon or main window)

- The settings panel displays resolution, picture quality, port, connection password with fingerprint, version/build, service status, TCC permission shortcuts, and log access; the host list and controller window titles also show the version;
- Screen capture and virtual display creation run inside the bundled `boltkvm-server` helper process, which automatically restarts 3 seconds after an unexpected exit;
- Clicking **New password…** generates a fresh password and restarts the server, immediately invalidating the old password.

**Controller** (single window)

- Opens to the saved host list—double-click a host to connect, or click **Edit** to configure display name, IP address, port, resolution, password, color mode, and input/audio/clipboard toggles per host;
- After connecting, the window maps one stream pixel to one physical pixel (**1:1**) when it fits; otherwise it scales down proportionally to the visible area and the toolbar shows the scale percentage (only when below 100%). Full screen (⌃⌘F) on a matching display is 100%, giving the crispest text;
- The centered toolbar provides **Mission Control** and **Desktop** shortcuts for the remote Mac; **Desktop** becomes **Restore Windows** when pressed again. Live `fps · Mbps` metrics sit on the right;
- In full screen the toolbar is an overlay: it auto-hides and reveals after a short dwell at the top edge, and the remote picture moves down by exactly one toolbar height without being resized or re-scaled (the bottom goes off-screen). This matches macOS Screen Sharing instead of squeezing the drawable;
- Closing the video window disconnects the session and returns to the host list. If audio is being forwarded for this host, the client sends `pauseMedia` first and the server restores the controlled Mac's output only after Now Playing is confirmed stopped;
- Keyboard and mouse events are forwarded only while the pointer is inside the video view. Pressing keys or mouse buttons and then moving the pointer out, unfocusing the window, or disconnecting automatically synthesizes release events; modifier flags are also reconciled before each key event to prevent stuck modifiers. When audio is selected and playing for this host, the hardware volume up/down/mute keys stay local; with audio unselected they are forwarded.

## Color Modes

The controller's **Edit → Color** offers two choices; the setting is sent to the server in the `config` packet:

| Mode | Capture | Encode | Bitrate (6016×3384 desktop) | When to use |
|---|---|---|---|---|
| Standard (default) | 8-bit 4:2:0 BT.709 | ProRes 422 | ~1.9 Gbps | Everyday use |
| Wide gamut | 10-bit 4:2:2 Display P3 | ProRes 422 (P3 tagged) | ~1.85 Gbps | Smoother gradients; real wide-gamut gain only when capturing a physical P3 display |

To be precise: when the server uses a **virtual display**, that display's framebuffer is sRGB (measured: pure red in that space maps to P3 as `0.918 / 0.200 / 0.139`, i.e. sRGB red), so wide gamut does **not** widen the gamut at this layer—it only removes one intermediate quantization step. The real benefit appears when `--display-id` captures a physical P3 display. The controller shows a `P3` badge at the right end of the toolbar for a wide-gamut stream.

ProRes 422 is 10-bit 4:2:2 on the wire, so the client always decodes ProRes to 10-bit—even in Standard mode; the 8-bit figure above refers to the capture pixel format. The HEVC path remains 8-bit 4:2:0.

The UI is localized in English and Simplified Chinese (`Packaging/Resources/{en,zh-Hans}.lproj/Localizable.strings`).

## Required Permissions

| Role | Permission | Purpose |
|---|---|---|
| Controlled Mac | Screen Recording | Required by ScreenCaptureKit; the server cannot start without it |
| Controlled Mac | Accessibility | Required by CGEvent to inject keyboard and mouse events (view-only without it) |
| Controller | Local Network (macOS 15+) | Required to reach Thunderbolt Bridge or LAN addresses (`No route to host` if denied) |

The controller app uses window-local `NSEvent` monitors for keyboard and mouse capture and does not require **Input Monitoring** permission (only the CLI `--input` full-screen mode uses `CGEventTap` and requires Input Monitoring).

`build-app.sh` prefers the local, stable `BoltKVM Local` identity when it exists; only when that identity is absent does it fall back to ad-hoc signing (`-`). Because every rebuild changes the binary `cdhash` under ad-hoc signing, macOS TCC treats each build as a new application and re-prompts for permissions. Create and trust a persistent self-signed certificate once:

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

Double-click the host or click **Connect**. Changing the resolution in the host editor automatically rebuilds the remote virtual display on the next connection; picture quality (**Standard** caps stream width at 3840, **Sharp** streams the full 2× backing pixels, capped at 8192 wide for custom sizes over 4096 logical) can be toggled from the controlled Mac's menu bar or settings panel.

The controlled Mac's menu, the settings panel, and the host editor share one resolution catalog: the first two entries are this project's targets, 3008×1692 (Thunderbolt bridge / 32-inch display) and 1728×1117 (MacBook Pro panel), followed by 1920×1080, 2560×1440, 2880×1620, and 3840×2160. A custom size is added to this Mac's catalog and the controlled Mac's menu also lists the current custom size. Custom entries live in this Mac's preferences and are not synchronized to the other machine.

## Audio and Clipboard Behavior

Audio is opt-in per host. The controller writes an explicit selected/unselected/record-only value into byte 7 of the `config` packet; a new server then skips audio capture entirely for an unselected host. Older clients send 0 there, so a new server keeps the legacy "server decides" behavior for them. `--audio-record` sends 3 (capture only): the server still sends audio, but the client neither plays it nor asks the controlled Mac to mute. The wire format is negotiated after authentication: the server advertises 24-bit support in `authOk`, and the controller requests packed 24-bit PCM; old peers fall back to 48 kHz / 16-bit. Both formats are stereo; 96 kHz is not implemented. 24-bit samples are decoded to float32 for the mixer because an int32 player connection is rejected by the current macOS (`-10868`).

When audio is selected:

- The controlled Mac's default output is muted through `AudioOutputMute`; the source keeps playing, and ScreenCaptureKit taps it before the device mute, so the controller receives the complete stream. The original mute/volume state is saved and restored.
- Selecting audio does **not** pause the controlled Mac's Now Playing app.
- Closing the controller first sends `pauseMedia`. The server pauses the app again as a fallback, polls `MRMediaRemoteGetNowPlayingApplicationIsPlaying`, and only restores the output after the player reports stopped (plus a short settle window). If MediaRemote cannot confirm, the output stays muted a little longer rather than leaking a burst.
- A controller output-route change (Bluetooth headphones, wired headphones, a display with speakers) immediately stops local playback and mutes the controller's **whole** default output, pauses the controlled Mac's Now Playing app, then rebuilds the audio graph once and restores the controller output after 2.5 s. The controlled Mac's media does not resume automatically.

### Clipboard Sync

Clipboard sync is bidirectional and enabled by default. It carries plain text, HTML/RTF (with a plain-text fallback), PNG (TIFF is converted), and files/folders as content, not paths. Received files go to `~/Downloads/BoltKVM Clipboard/`; folders are packed/unpacked with `ditto` and verified file by file with SHA-256. Symlinks are not supported. The receiver skips `ConcealedType` / `TransientType` / `AutoGeneratedType`, never simulates ⌘V, and suppresses loops with `NSPasteboard.changeCount` plus a content hash. Limits are configurable (`client.clipboardMaxMB`, `client.clipboardMaxGB`; server `--clipboard-max-mb` / `--clipboard-max-gb`); non-file items default to 512 MB, and file transfers are bounded by free disk minus 20 GB rather than a fixed 2 GB cap. Interrupted transfers use a `.incoming-*` path and are cleaned up. Disable per host in the editor or with `defaults write io.github.boltkvm client.clipboard -bool false`; the server accepts `--no-clipboard`.

## Command-Line Interface (CLI)

The `boltkvm` CLI shares `BoltKVMCore` with the GUI app and is used for scripted verification and long-running soak tests:

```bash
# Start the server
.build/release/boltkvm server --width 3840 --height 2160 --port 7474 --seconds 0

# Start the client (full-screen Metal render + input capture + auto-reconnect)
.build/release/boltkvm client --host <server-ip> --port 7474 --seconds 28800 \
  --render --switch-mode --input --reconnect

# Run the test suite (all XCTest unit tests; falls back to CLI self-tests on CLT-only machines)
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
--audio                            # Enable system audio capture (48 kHz stereo; negotiated 16/24-bit, ~1.5/2.3 Mbps)
--local-mute                       # Explicitly mute the controlled Mac's default output (off by default)
--codec hevc                       # Use HEVC instead of the default ProRes 422 encoder
--no-clipboard                     # Disable clipboard sync
--clipboard-max-mb 512             # Non-file clipboard item cap
--clipboard-max-gb 0               # Optional file-transfer cap (0 = disk minus 20 GB)
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
git tag v0.14.0 && git push origin v0.14.0   # replace with the actual version
```

Pushing `main` alone never publishes a release—`release.yml` only runs for `v*` tags. Make sure CI is green on `main` before tagging. ## Recovery After a Controlled Mac Reboot

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
- **No Audio Output Device**: If `--audio` is enabled on a machine without a usable output device (e.g. a CI runner), the audio path degrades to silence and logs `audio: playback unavailable (...)`; video and input keep working, the server no longer crashes, and the client retries when a device appears.
- **Output Route Changes / Bluetooth Reconnect**: When Bluetooth headphones disconnect and reconnect, or a display with speakers is plugged in, the default output changes. The controller immediately stops forwarded playback and mutes its whole default output, asks the controlled Mac to pause Now Playing, rebuilds the audio graph once after the route settles (log: `audio: playing to <default device> (...; graph #n)`), and restores the controller output after 2.5 s. If audio is still silent, look for `audio: retrying output` / `audio: playback unavailable`. Selecting audio alone does not pause the controlled Mac; it mutes its output. Closing the controller does pause it, after which the server confirms the player stopped before restoring output. With audio unselected, the controller sends no mute/pause command and the server captures no audio.
- **Controlled Mac Output Mute**: After the controller selects audio, the server logs `audio: client selected audio; local output is muted`; Now Playing keeps playing. On a deliberate close, the controller sends `pauseMedia`, the server confirms the player stopped (`audio: Now Playing confirmed paused; restoring output`) and then restores the saved mute/volume (`audio: restored local output ... aggregate members`). If a player ignores MediaRemote pause, the server logs `pause not confirmed` and holds the output mute a little longer.
- **Virtual Display Failure**: If the virtual display still cannot be created after retries, the server exits with status 3 and lets the supervisor restart it; it never falls back to streaming the operator's local desktop.

## Milestones

Background and target metrics are documented in the [Project Charter](docs/design/project-charter.md).

- [x] **M0 Preflight**: Virtual display and Thunderbolt Bridge baseline ([report](docs/reports/2026-10-21-m0-display.md); the display layer passed, while physical unplug/headless re-test, sleep/wake, audible audio, and the physical latency baseline remain tracked in [Open Items](docs/plans/open-items.md))
- [x] **M1 Visual Equivalence**: Capture → hardware encode → direct TCP → hardware decode → Metal present at 60 fps, SSIM 0.984 ([report](docs/reports/2026-10-21-m1-pipeline.md))
- [x] **M2 Input Pipeline**: System shortcuts, modifier synchronization, and continuous scroll phases ([report](docs/reports/2026-10-21-m2-input.md))
- [x] **M3 Stability**: TCC preflight, auto-reconnect, 8-hour soak ([soak report](docs/reports/2026-10-22-m3-soak-8h.md)) and 8-hour CLI input continuity ([night-run report](docs/reports/2026-10-22-night-run.md))
- [x] **App Packaging**: Dual-role app bundle, built-in virtual display, multi-host manager, optional audio, and CI releases ([report](docs/reports/2026-10-22-app-conversion.md))

## Documentation Index

> Detailed design documents, ADRs, plans, and verification reports under `docs/` are maintained in Chinese.

- [Project Charter](docs/design/project-charter.md)
- [Open Items](docs/plans/open-items.md)
- [Release Guide](docs/releasing.md)
- [Connection Manager Design](docs/plans/2026-10-22-connection-manager-design.md)
- [B5 Frame Rate & Latency Report](docs/reports/2026-10-23-b5-latency.md)
- [Audio & GUI Stability Report](docs/reports/2026-10-23-audio-and-gui-stability.md)
- [Audio Route and Local Mute](docs/reports/2026-10-28-audio-route-mute.md)
- [Code Audit and Fixes (2026-10-28)](docs/reports/2026-10-28-code-audit-fixes.md)
- [Transport Encryption Report](docs/reports/2026-10-22-transport-encryption.md)
- [Verification Report Index](docs/reports/README.md)
- [Architecture Decision Records (ADR) Index](docs/adr/README.md), [Plans](docs/plans/)

## Requirements

- macOS 15+ on Apple Silicon;
- Direct Thunderbolt Bridge connection, or any routable LAN IP connection;
- Swift 6 / Xcode Command Line Tools to build from source;
- CI runs on `macos-15` with the runner's Swift 6.1.2, which can differ from a newer local toolchain—trust CI for release behaviour (toolchain pitfalls are recorded in [docs/releasing.md](docs/releasing.md)).

## Contributing

Read [AGENTS.md](AGENTS.md) before submitting changes. Every self-contained change must build cleanly, pass tests, and update relevant documentation in the same commit.

## License

[MIT](LICENSE). Third-party license notices are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
