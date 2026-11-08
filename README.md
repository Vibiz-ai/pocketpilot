# OpenTap

Let an AI agent drive a real iPhone from your Mac. OpenTap is a small macOS app that shows the iPhone's screen to an agent,
reads the text on it, and taps, swipes and types for it, all exposed as a local MCP server.

Open source (MIT), written in Swift, no third-party dependencies, nothing leaves your Mac.

## How it works

```
                USB cable (screen + lockdown)
  +--------+ -----------------------------------> +--------------------------------------------+
  |        |                                      |  OpenTap.app (your Mac)                    |
  | iPhone |  Bluetooth HID (keyboard, mouse,     |                                            |
  |        | <----------------------------------- |  Capture   -> latest frame -> screenshot   |
  +--------+   consumer control)                  |  Vision    -> OCR text + centre x,y        |
                                                  |  Device    -> Trust, AssistiveTouch toggle |
                                                  |  Bluetooth -> HID reports (0xA1 packets)   |
                                                  |  Control   -> calibration, taps, swipes    |
                                                  |  MCP       -> http://127.0.0.1:47900/mcp   |
                                                  +----------------------^---------------------+
                                                                         | JSON-RPC over HTTP
                                                              Claude Code / Cursor / Codex
```

- **Screen.** An iPhone plugged in by USB appears as a capture device once CoreMediaIO's
  `kCMIOHardwarePropertyAllowScreenCaptureDevices` is turned on (the same thing QuickTime does). OpenTap keeps the latest
  frame and serves screenshots downscaled to a 590-pixel-wide "screenshot space".
- **Text.** Vision's accurate text recognizer turns each screenshot into a list of `{text, x, y}` in screenshot coordinates,
  so agents can `tap_text("Settings")`.
- **Input.** The Mac publishes a classic Bluetooth HID service (keyboard + relative mouse + consumer control). You pair it
  once from the iPhone's Settings > Bluetooth. With AssistiveTouch on, iOS shows a pointer for the mouse.
- **Pointer.** The mouse is relative and iOS accelerates it, so OpenTap calibrates: it parks the pointer in a corner,
  measures how many pixels each mouse step moves it, and stores the curve in
  `~/Library/Application Support/OpenTap/calibration.json`. A tap is: park, move along the curve, find the pointer dot in
  the frame, correct, click.
- **USB lockdown.** If Apple's MobileDevice framework is present, OpenTap uses it to see the iPhone attach, read its name and
  iOS version, ask it to Trust this Mac, and turn AssistiveTouch on. If it is missing, those steps fall back to manual
  instructions.
- **MCP.** A Streamable-HTTP MCP server (protocol `2025-06-18`) bound to `127.0.0.1:47900`. Every action returns a fresh
  screenshot plus the OCR text.

## Requirements

- A Mac with macOS 14 Sonoma or later and Bluetooth.
- An iPhone and a USB cable that carries data.
- Swift 5.9 or later to build (Xcode or `xcode-select --install`).

## Install and build

```sh
git clone <this repo> opentap && cd opentap
scripts/build-app.sh          # release build -> build/OpenTap.app, ad-hoc signed
open build/OpenTap.app        # or drag it into /Applications first
```

`build-app.sh` writes an Info.plist with bundle id `xyz.opentap.app`, the Camera and Bluetooth usage strings and
`LSMinimumSystemVersion 14.0`, then ad-hoc signs the bundle. Because it is ad-hoc signed, the first launch may need
right-click > Open.

## Onboarding

The setup wizard opens on first launch, and again from the menu with **Run Setup Again…** (Cmd+Shift+R). Every step
checks itself live and turns green; when one fails it says what failed, why, and how to fix it right there.

1. **Permissions.** Allow Camera (macOS delivers the iPhone screen as a camera-like device) and Bluetooth. Buttons ask
   for each permission or open the right pane of System Settings.
2. **Plug in your iPhone.** Connect it by USB and unlock it. OpenTap asks it to Trust this Mac; tap Trust and enter your
   passcode. The step shows the iPhone's name once it is trusted.
3. **Screen.** The live preview of the iPhone screen appears.
4. **Bluetooth.** The Mac becomes discoverable. On the iPhone open Settings > Bluetooth and tap the name the wizard shows
   (your Mac's Bluetooth name). The step completes when both HID channels are open.
5. **AssistiveTouch.** OpenTap tries to switch it on over USB. If that is not possible it shows the path:
   Settings > Accessibility > Touch > AssistiveTouch. It then wiggles the mouse and confirms the pointer is visible.
6. **Calibration.** About 30 seconds with a progress bar. Keep the iPhone unlocked and do not touch it.
7. **Connect your agent.** Copy the command or click **Add to Claude Code**, then **Test it** calls `status` over MCP.

After setup the main window shows the live screen, status pills (USB, Screen, Bluetooth, AssistiveTouch, Calibration,
MCP), the first problem with its fix, and a log.

## Connect an agent

The server lives at `http://127.0.0.1:47900/mcp` while OpenTap is running.

**Claude Code** (all projects):

```sh
claude mcp add --transport http --scope user opentap http://127.0.0.1:47900/mcp
```

or for one project, `.mcp.json`:

```json
{ "mcpServers": { "opentap": { "type": "http", "url": "http://127.0.0.1:47900/mcp" } } }
```

**Cursor**, `~/.cursor/mcp.json`:

```json
{ "mcpServers": { "opentap": { "url": "http://127.0.0.1:47900/mcp" } } }
```

**Codex**:

```sh
codex mcp add opentap --url http://127.0.0.1:47900/mcp
```

or `~/.codex/config.toml`:

```toml
[mcp_servers.opentap]
url = "http://127.0.0.1:47900/mcp"
```

Any other Streamable-HTTP MCP client works with the same URL.

## Tools

Coordinates are pixels in the most recent screenshot (origin top-left, about 590 wide). Every action returns a fresh
screenshot and the on-screen text with centre coordinates.

| Tool | Arguments | What it does |
|---|---|---|
| `status` | | Health of USB, Screen, Bluetooth, AssistiveTouch, Calibration and MCP, each with its fix. Call first when something fails. |
| `screenshot` | `include_text` (default true) | Current screen as an image plus OCR text. |
| `tap` | `x`, `y` | Tap a point. |
| `tap_text` | `text`, `occurrence` (default 1) | Tap visible text (case-insensitive; exact beats starts-with beats contains, in reading order). |
| `long_press` | `x`, `y`, `duration_ms` (default 800) | Press and hold. |
| `swipe` | `from_x`, `from_y`, `to_x`, `to_y`, `duration_ms` (default 400) | Drag. 500 ms or more does not coast; shorter flings. Up from the bottom edge goes Home, in from the left edge goes Back. |
| `scroll` | `direction` (up/down/left/right), `amount` (0.1 to 1.0, default 0.5) | Scroll content, starting away from the edges. |
| `type_text` | `text`, `submit` (default false) | Type ASCII with a US layout into the focused field; `submit` presses Return. |
| `press_key` | `key` | `return`, `backspace`, `tab`, `escape`, `space`, arrows, `home`, volume keys, letters, digits, combos like `cmd+space`. |
| `open_app` | `name` | Home, Spotlight, type the name, Return. |
| `calibrate` | | Re-measure the pointer curve (about 30 s). |
| `batch` | `actions` | Run steps in order, e.g. `[{"action":"tap_text","text":"Notes"},{"action":"wait","ms":500}]`. Stops at the first failure and names the step. |

## Troubleshooting

| Symptom | Why | Fix |
|---|---|---|
| Screen step stays on "Waiting for the iPhone screen" | The iPhone is not visible as a capture device: charge-only cable, locked phone, or Trust not accepted | Use a data cable, unlock the iPhone, tap Trust, then unplug and replug |
| "Camera access is off for OpenTap" | macOS treats the iPhone screen as a camera | System Settings > Privacy & Security > Camera, turn on OpenTap, relaunch it |
| "No frames" after 5 s | The iPhone is locked, untrusted, or another app is holding the capture device | Unlock the iPhone, tap Trust, stop other recordings of it, replug |
| The Mac does not appear in iPhone Settings > Bluetooth | Bluetooth permission is off, Bluetooth is off, or the Mac stopped being discoverable | Allow Bluetooth for OpenTap in Privacy & Security, turn Bluetooth on, then Phone menu > Restart Bluetooth |
| Taps fail with `hidNotConnected` | The iPhone is paired but not connected right now | iPhone Settings > Bluetooth, tap your Mac's name so it says Connected |
| "Couldn't see the pointer" / `assistiveTouchOff` | AssistiveTouch is off, so iOS draws no pointer | Settings > Accessibility > Touch > AssistiveTouch, turn it on |
| Taps land in the wrong place | Pointer speed changed (AssistiveTouch > Tracking Speed) or it is a different iPhone | Run `calibrate` again, or Phone menu > Recalibrate |
| `notCalibrated` | No calibration for this iPhone and screen size | Run the Calibration step or the `calibrate` tool |
| `tap_text` says the text is not on screen | OCR did not see it, or it is spelled differently | Take a `screenshot`, use one of the listed texts, or `tap(x, y)` |
| USB step shows manual instructions only | Apple's MobileDevice framework could not be loaded on this Mac | Tap Trust and turn AssistiveTouch on by hand; everything else works |
| "Port 47900 is already in use" | Another OpenTap (or another program) is listening there | Quit the other copy; `lsof -nP -iTCP:47900 -sTCP:LISTEN` shows who has it |
| Agent gets HTTP 404 "unknown session" | OpenTap was restarted; sessions live in memory | Reconnect the server in your agent (in Claude Code: `/mcp`) |
| `type_text` rejects a character | Only US-layout ASCII can be typed through a HID keyboard | Type only the ASCII parts |

## Privacy

Everything runs on your Mac. The screen, OCR text, calibration and logs stay local. The MCP server listens only on
`127.0.0.1` and rejects requests from non-local web origins. OpenTap has no analytics and no accounts, and makes no
network requests of its own.

## Development

```sh
swift build                           # all targets
swift test                            # unit + integration tests (no hardware)
scripts/qa.sh                         # build, tests, MCP end-to-end against the simulated iPhone
swift run opentap-mock --port 47999   # headless MCP server backed by the simulated iPhone
scripts/hardware-smoke.sh             # guided checklist with a real iPhone
```

`opentap-mock` runs the real controller, pointer locator and MCP server against a simulated iPhone that applies pointer
acceleration and reacts to the HID reports, so most behaviour can be tested without a phone. See
[docs/TESTING.md](docs/TESTING.md) for the mock, its fault scenarios and the QA scripts.

| Path | What |
|---|---|
| `Sources/OpenTapCore/Shared` | Protocols and models every module codes against |
| `Sources/OpenTapCore/Capture` | USB screen capture, screenshot rendering |
| `Sources/OpenTapCore/Vision` | OCR |
| `Sources/OpenTapCore/Bluetooth` | Bluetooth HID keyboard + mouse + consumer control |
| `Sources/OpenTapCore/Device` | USB device detection, Trust pairing, AssistiveTouch toggle |
| `Sources/OpenTapCore/Control` | Calibration, pointer detection, actions |
| `Sources/OpenTapCore/MCP` | Streamable-HTTP MCP server |
| `Sources/OpenTapCore/Mock` | Simulated iPhone for tests and `opentap-mock` |
| `Sources/OpenTap` | SwiftUI app |
| `Sources/opentap-mock` | Headless MCP server against the simulated iPhone |

## Contributing

Issues and pull requests are welcome. Please:

- keep it dependency-free and macOS 14 compatible;
- put logic in `OpenTapCore` behind the protocols in `Shared/` so it can be tested with the mocks;
- make every error say what failed, why, and how to fix it;
- run `scripts/qa.sh` before opening a PR.

## License

MIT, see [LICENSE](LICENSE).
