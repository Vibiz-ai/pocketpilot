# Testing OpenTap

OpenTap drives real hardware (USB screen capture, Bluetooth HID, lockdown over USB), so almost everything is
tested against a **simulated iPhone** (`MockPhone`) instead. Only the last step, the hardware smoke test, needs
a human with a phone.

| Layer | What | Command | Needs hardware |
|---|---|---|---|
| Unit | Shared contracts, each module's own tests | `swift test --scratch-path .build-<you>` | no |
| Mock device | The simulated iPhone itself | `swift test --filter MockDeviceTests` | no |
| Integration | Real Control + Capture + Vision + MCP against the mock | `swift test --filter IntegrationTests` | no |
| MCP end-to-end | `opentap-mock` + JSON-RPC over HTTP, incl. fault scenarios | `scripts/qa.sh` | no |
| Hardware smoke | Guided checklist on a real iPhone | `scripts/hardware-smoke.sh` | yes |

## The QA gate: `scripts/qa.sh`

```sh
scripts/qa.sh                  # build + all tests + MCP end-to-end + fault scenarios, PASS/FAIL table
scripts/qa.sh --strict         # integrator mode: stubbed modules fail instead of skip
scripts/qa.sh --no-tests       # build + MCP end-to-end only (fast loop)
scripts/qa.sh --filter MockDeviceTests
scripts/qa.sh --scratch .build-me --port 48100   # parallel-safe
```

It exits non-zero if any row fails. Logs go to a temp dir printed at the end (`build.log`, `test.log`,
`mock-<port>.log`, `e2e-<port>.log`).

Integration tests that hit a module still throwing `.notImplemented` are **skipped** by default and **fail**
with `--strict` (`OPENTAP_STRICT_INTEGRATION=1`). Everything else, including a wrong result from a module
that is implemented, is a real failure.

## The simulated iPhone (`Sources/OpenTapCore/Mock`)

`MockPhone` renders a 1206x2622 iPhone screen with CoreGraphics and reacts to HID reports the way iOS does:

- **Screens**: Home (12 labelled icons in a 4x3 grid + a Search pill), Spotlight (search field + results),
  Settings (43 rows, scrolls; "Developer" is last; rows open a detail page with `< Settings`), Notes (a text
  field "Tap to type"; return saves the note), any other app ("Safari is open"), and a lock screen.
- **Pointer**: relative mouse reports go through a nonlinear acceleration curve
  (`px = 1.2*u + 0.012*u^2` per report, frame px), clamp at the edges (so parking works), and draw a grey dot
  whose shade adapts to the screen (light on dark UI, dark on light UI) like iOS. The AssistiveTouch button is
  drawn at the right edge whenever AssistiveTouch is on; with it off, mouse reports are ignored and no pointer
  is drawn.
- **Touches**: left button down/up = tap (< 500 ms) or long press (>= 500 ms; on an icon it opens the
  "Edit Home Screen" menu); moving more than 20 px while down = swipe. Swipe up from the bottom edge = Home,
  from the left edge = Back, vertical drags scroll Settings, swipe down on Home = Spotlight. Wheel scrolls.
- **Keyboard**: US layout typing into the focused field (Spotlight or Notes; typing with no focus is
  counted in `droppedKeystrokes`), backspace, return (submit), escape, cmd+space = Spotlight, cmd+H = Home.
  Consumer AC Home (0x0223) = Home. Keys are edge-triggered, so repeated letters need a release in between.
- **Inspection** for tests: `screen`, `pointer`, `gestures`, `typedText`, `notesSaved`, `settingsScroll`,
  `contextMenuApp`, `lastTapped`, `receivedReports`, `elements` (visible text = what OCR returns),
  `groundTruthCalibration()` (the exact curve, in screenshot space). Test hooks: `setPointer`, `show(screen)`,
  injectable `clock`.

The Mock components wrap one phone: `MockFrameSource` (60 fps frame counter, frames rendered on demand),
`MockHIDTransport` (connects on start, `sent` log), `MockDeviceLink` (attach/trust/AssistiveTouch over "USB"),
`MockTextRecognizer` (deterministic OCR from `elements`), `MockPermissions` (scriptable answers, records
`openSettings`). They all follow the phone's fault toggles live.

### Faults

Set them on the phone (`phone.isLocked = true`, `phone.apply([.locked, .assistiveTouchOff])`) or on the
command line (`opentap-mock --fault locked,at-off`, or `OPENTAP_MOCK_FAULTS`):

| Fault | Simulates | Expected behaviour |
|---|---|---|
| `locked` | screen locked | lock screen shown, input ignored, `pair()` throws `deviceLocked` |
| `untrusted` | attached, not paired | `pair()` succeeds after `trustDelay` |
| `deny-trust` | user taps Don't Trust | `pair()` throws `notPaired`, trust state `denied` |
| `at-off` | AssistiveTouch off | no pointer; taps/calibration must fail with an AssistiveTouch fix |
| `at-usb-blocked` | AssistiveTouch can't be set over USB | `setAssistiveTouch` throws with the manual Settings path |
| `no-usb` | nothing plugged in | device link `noDevice`, screen waiting |
| `no-frames` | capture device never appears | screen `waitingForDevice`, screenshots throw `noFrame` |
| `frozen-frames` | stream stalls | `waitForFrame` times out |
| `capture-fails` | capture session fails | `start()` throws `captureFailed` |
| `no-bluetooth` | iPhone never connects | HID stays `advertising`, sends throw `hidNotConnected` |
| `bluetooth-off` | Mac Bluetooth off | HID `unavailable(bluetoothUnavailable)` |
| `no-mobiledevice` | MobileDevice.framework missing | device link `unavailable` with manual steps |

## `opentap-mock`

A headless OpenTap: the real controller and MCP server on top of the simulated phone.

```sh
swift run --scratch-path .build-me opentap-mock               # http://127.0.0.1:47901/mcp
opentap-mock --port 48000 --calibrated                         # skip calibration (exact curve preloaded)
opentap-mock --fault no-bluetooth                              # error paths
opentap-mock --ocr vision                                      # real Vision OCR on the rendered screen
claude mcp add --transport http opentap-mock http://127.0.0.1:47901/mcp   # drive it from an agent
```

It prints `opentap-mock listening on <url>` once ready and exits cleanly on SIGINT/SIGTERM.

## MCP end-to-end: `scripts/mcp_e2e.py`

Standard-library Python. Against the mock it checks real outcomes, not just protocol shape: initialize
(protocol 2025-06-18, `Mcp-Session-Id`), session enforcement, tools/list (all 12 tools with schemas), status,
screenshot (JPEG/PNG, 590 wide, OCR), bad arguments and unknown tools (errors with a fix), calibrate,
`press_key home`, `tap_text Notes`, tap + `type_text` with submit, long press menu, `open_app`, scroll
down/up, Settings row + back, bottom-edge swipe, batch via Spotlight, batch failure naming the step, and
`tap_text` of missing text (textNotFound with a screenshot). `--scenario no-bluetooth|at-off|no-frames` checks
that each fault surfaces in `status` and as a tool error with the right code and fix.

```sh
python3 scripts/mcp_e2e.py --url http://127.0.0.1:47901/mcp
python3 scripts/mcp_e2e.py --url http://127.0.0.1:47900/mcp --live      # real phone: protocol checks only
python3 scripts/mcp_e2e.py call screenshot '{"include_text":true}' --save-image /tmp/s.jpg
```

## Hardware smoke test (humans only)

With OpenTap.app running, onboarding finished and the iPhone unlocked on the Home Screen:

```sh
scripts/hardware-smoke.sh            # asks y/n/s after each step, saves a report + screenshots
scripts/hardware-smoke.sh --no-calibrate
```

It checks status, screenshot + OCR, Home, calibration, cmd+space + typing, open_app, scroll, tap_text,
edge swipes (Back, Home), a tap at OCR coordinates and a batch. It never changes settings or sends anything.
Attach the printed report to the PR. (`--yes` auto-answers; only useful for dry-running against
`opentap-mock --calibrated`.)

## Writing tests

- Put module tests in `Tests/OpenTapCoreTests/<Module>/`. Use `OpenTapEnvironment.mock(...)` and a
  `MockPhone` instead of hardware, and assert on the phone's state (`screen`, `gestures`, ...), not just on
  return values.
- Set `HIDPhoneController.timing = .fast` and `reportIntervalOverrideMs = 0` to keep controller tests quick,
  and seed `InMemoryCalibrationStore(phone.groundTruthCalibration())` unless you are testing calibration.
- Every error must say what, why and how to fix. Assert on `code` and that `fix` names the setting/action.
- Use your own scratch path (`--scratch-path .build-<role>`) so parallel builds don't collide.
