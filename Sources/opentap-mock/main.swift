import Foundation
import OpenTapCore

/// Owner: qa. Headless MCP server backed by the simulated iPhone (MockPhone), so QA and agents can drive
/// OpenTap's real controller + MCP code without hardware.
///
///   opentap-mock [--port N] [--fault a,b] [--calibrated] [--ocr mock|vision] [--quiet]
///
/// Port: --port, else $OPENTAP_MOCK_PORT, else 47901. Faults: --fault, else $OPENTAP_MOCK_FAULTS.
/// Prints "opentap-mock listening on <url>" on stdout once the MCP server accepts connections.

let defaultPort: UInt16 = 47901

func usage() -> String {
    let faults = MockPhone.Fault.allCases.map { "    \($0.rawValue.padding(toLength: 16, withPad: " ", startingAt: 0)) \($0.help)" }
    return """
    Usage: opentap-mock [options]

      --port N          MCP port on 127.0.0.1 (default $OPENTAP_MOCK_PORT or \(defaultPort))
      --fault a,b       simulate failures (default $OPENTAP_MOCK_FAULTS):
    \(faults.joined(separator: "\n"))
      --calibrated      start with the phone's exact acceleration curve already calibrated
      --ocr mock|vision text recognition: deterministic mock (default) or real Vision on the rendered screen
      --quiet           only print warnings and errors to stderr
      --help            show this help

    """
}

func fail(_ e: OpenTapError) -> Never {
    FileHandle.standardError.write(Data("opentap-mock: \(e.description)\n".utf8))
    exit(2)
}

var port = ProcessInfo.processInfo.environment["OPENTAP_MOCK_PORT"].flatMap { UInt16($0) } ?? defaultPort
var faultList = ProcessInfo.processInfo.environment["OPENTAP_MOCK_FAULTS"] ?? ""
var calibrated = false
var useVision = false
var quiet = false

var args = Array(CommandLine.arguments.dropFirst())[...]
while let a = args.popFirst() {
    switch a {
    case "--port":
        guard let v = args.popFirst(), let p = UInt16(v), p > 0 else {
            fail(.invalidArgument("--port", why: "It needs a number between 1 and 65535",
                                  fix: "Run e.g. opentap-mock --port \(defaultPort)"))
        }
        port = p
    case "--fault", "--faults":
        guard let v = args.popFirst() else {
            fail(.invalidArgument("--fault", why: "No fault list was given",
                                  fix: "Pass a comma-separated list, e.g. --fault locked,at-off"))
        }
        faultList = v
    case "--calibrated": calibrated = true
    case "--ocr":
        switch args.popFirst() {
        case "vision": useVision = true
        case "mock": useVision = false
        default: fail(.invalidArgument("--ocr", why: "It must be 'mock' or 'vision'", fix: "Run e.g. opentap-mock --ocr vision"))
        }
    case "--quiet", "-q": quiet = true
    case "--help", "-h": print(usage()); exit(0)
    default:
        fail(.invalidArgument(a, why: "Unknown option", fix: "Run opentap-mock --help to see the options"))
    }
}

let faults: [MockPhone.Fault]
do { faults = try MockPhone.Fault.parse(faultList) } catch { fail(OpenTapError.wrap(error, what: "Bad --fault list")) }

let log = Log(minimumLevel: quiet ? .warning : .info, echoToStderr: true)
let phone = MockPhone()
phone.apply(faults)
let store = InMemoryCalibrationStore(calibrated ? phone.groundTruthCalibration() : nil)

let env: OpenTapEnvironment
if useVision {
    env = OpenTapEnvironment(log: log, status: StatusModel(), permissions: MockPermissions(),
                             frames: MockFrameSource(phone: phone), renderer: ImageScreenshotRenderer(),
                             recognizer: VisionTextRecognizer(), hid: MockHIDTransport(phone: phone),
                             device: MockDeviceLink(phone: phone), pointer: DotPointerLocator(),
                             calibrationStore: store, mcpPort: port, mockPhone: phone)
} else {
    env = OpenTapEnvironment.mock(log: log, phone: phone, port: port, calibrationStore: store)
}

func shutdown(_ sig: Int32) {
    env.mcp.stop()
    env.frames.stop()
    env.hid.stop()
    env.device.stop()
    exit(0)
}
signal(SIGINT, shutdown)
signal(SIGTERM, shutdown)

Task {
    // Hardware first; a simulated fault is expected to fail some of these, which is the point.
    await env.device.start()
    do { try await env.hid.start() } catch { log.warning("mock", OpenTapError.wrap(error, what: "Mock Bluetooth didn't start").description) }
    do { try await env.frames.start() } catch { log.warning("mock", OpenTapError.wrap(error, what: "Mock screen didn't start").description) }
    do {
        try await env.mcp.start()
    } catch {
        let e = OpenTapError.wrap(error, what: "Couldn't start the mock MCP server",
                                  fix: "Make sure port \(port) is free (lsof -i :\(port)) or pass --port")
        FileHandle.standardError.write(Data("opentap-mock: \(e.description)\n".utf8))
        exit(1)
    }
    let url = "http://\(MCPDefaults.host):\(port)\(MCPDefaults.path)"
    print("opentap-mock listening on \(url)")
    print("  phone: \(phone.deviceInfo.name) \(Int(phone.screenSize.width))x\(Int(phone.screenSize.height)), "
          + "faults: \(faults.isEmpty ? "none" : faults.map(\.rawValue).joined(separator: ",")), "
          + "calibrated: \(calibrated), ocr: \(useVision ? "vision" : "mock")")
    print("  try: claude mcp add --transport http opentap-mock \(url)")
    fflush(stdout)
}
dispatchMain()
