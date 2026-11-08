# OpenTap

Let an AI agent drive a real iPhone from your Mac. Open source, MIT licensed, no third-party dependencies.

- **Screen**: the iPhone's screen over USB (the same capture device QuickTime uses).
- **Text**: on-device OCR (Vision) so agents can `tap_text("Settings")`.
- **Input**: your Mac pairs with the iPhone as a Bluetooth keyboard and mouse. With AssistiveTouch on, the agent taps, swipes and types.
- **Agent**: a local MCP server at `http://127.0.0.1:47900/mcp`.

## Requirements

macOS 14+, an iPhone with a USB cable, Bluetooth.

## Quick start

```sh
scripts/build-app.sh        # builds build/OpenTap.app (ad-hoc signed)
open build/OpenTap.app      # the onboarding wizard checks every step live
claude mcp add --transport http --scope user opentap http://127.0.0.1:47900/mcp
```

## Tools

`status`, `screenshot(include_text)`, `tap(x,y)`, `tap_text(text, occurrence)`, `long_press(x,y,duration_ms)`,
`swipe(from_x,from_y,to_x,to_y,duration_ms)`, `scroll(direction, amount)`, `type_text(text, submit)`,
`press_key(key)`, `open_app(name)`, `calibrate`, `batch(actions)`. Every action returns a fresh screenshot plus OCR text.
Coordinates are in the latest screenshot's space.

## Layout

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

## Development

```sh
scripts/qa.sh               # build, unit tests, mock MCP smoke test (no hardware)
swift run opentap-mock --port 47999
```

## License

MIT, see [LICENSE](LICENSE).
