import Foundation

/// Owner: mcp. MCP tool definitions (names, descriptions, JSON Schemas) and argument parsing into PhoneActions.

public struct MCPToolDefinition: Sendable {
    public var name: String
    public var title: String
    public var description: String
    public var inputSchema: JSONValue
    public var readOnly: Bool

    public init(name: String, title: String, description: String, inputSchema: JSONValue, readOnly: Bool = false) {
        self.name = name; self.title = title; self.description = description; self.inputSchema = inputSchema; self.readOnly = readOnly
    }

    public var json: JSONValue {
        [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": [
                "title": .string(title),
                "readOnlyHint": .bool(readOnly),
                "destructiveHint": false,
                "idempotentHint": .bool(readOnly),
                "openWorldHint": false,
            ],
        ]
    }
}

public enum MCPTools {
    public static let defaultLongPressMs = 800
    public static let defaultSwipeMs = 400
    public static let defaultScrollAmount = 0.5
    public static let maxDurationMs = 10_000
    public static let maxWaitMs = 10_000
    public static let maxBatchActions = 50
    /// Coordinates above this are rejected up front (no screenshot is anywhere near it).
    public static let maxCoordinate: Double = 100_000
    public static let maxTextLength = 2_000

    public static let instructions = """
    OpenTap drives a real iPhone that is plugged into this Mac: it sees the screen over USB and taps/types as a Bluetooth \
    mouse and keyboard.
    Workflow: call `status` if anything fails, call `screenshot`, then act. Every action returns a fresh screenshot plus \
    the on-screen text, so read it before the next step.
    Coordinates are pixels in the most recent screenshot (origin top-left, x right, y down); they are not iPhone points \
    or full-resolution pixels. Prefer `tap_text` for anything with a visible label.
    The small dark dot is the mouse pointer and the large translucent circle (if shown) is the AssistiveTouch button; \
    ignore both. The pointer only exists while AssistiveTouch is on (Settings > Accessibility > Touch > AssistiveTouch); \
    if taps fail with "pointer not found", check that and run `calibrate`.
    Swipes of 500 ms or longer don't coast; shorter ones fling. Start scrolls away from the screen edges: a left-edge \
    swipe goes Back and a bottom-edge swipe goes Home.
    Typing is US-keyboard ASCII; tap a text field first to focus it. `press_key` accepts names like return, backspace, \
    tab, escape, space, up/down/left/right, home and combos like cmd+space.
    Use `batch` to run several steps with one screenshot at the end; it stops at the first failing step.
    Errors explain what failed, why, and how to fix it; follow the fix before retrying.
    """

    // MARK: Schema helpers

    static func number(_ description: String, minimum: Double? = nil, maximum: Double? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": "number", "description": .string(description)]
        if let minimum { o["minimum"] = .number(minimum) }
        if let maximum { o["maximum"] = .number(maximum) }
        return .object(o)
    }

    static func integer(_ description: String, minimum: Int? = nil, maximum: Int? = nil, default def: Int? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": "integer", "description": .string(description)]
        if let minimum { o["minimum"] = .number(Double(minimum)) }
        if let maximum { o["maximum"] = .number(Double(maximum)) }
        if let def { o["default"] = .number(Double(def)) }
        return .object(o)
    }

    static func string(_ description: String, minLength: Int? = nil, enumValues: [String]? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": "string", "description": .string(description)]
        if let minLength { o["minLength"] = .number(Double(minLength)) }
        if let enumValues { o["enum"] = .array(enumValues.map { .string($0) }) }
        return .object(o)
    }

    static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        [
            "type": "object",
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
            "additionalProperties": false,
        ]
    }

    static let xDesc = "X in pixels of the latest screenshot (0 = left edge)."
    static let yDesc = "Y in pixels of the latest screenshot (0 = top edge)."

    static var keyDescription: String {
        "Key or combo, e.g. \"return\", \"backspace\", \"cmd+space\", \"home\", \"a\". Supported: "
            + KeyCombo.supportedNames.joined(separator: "; ")
    }

    /// Per-action properties (without the batch "action" discriminator).
    static let actionProperties: [String: (props: [String: JSONValue], required: [String])] = [
        "tap": (["x": number(xDesc, minimum: 0), "y": number(yDesc, minimum: 0)], ["x", "y"]),
        "tap_text": ([
            "text": string("Visible text to tap (case-insensitive; exact matches win over partial ones).", minLength: 1),
            "occurrence": integer("Which match to tap, in reading order (1 = first).", minimum: 1, default: 1),
        ], ["text"]),
        "long_press": ([
            "x": number(xDesc, minimum: 0), "y": number(yDesc, minimum: 0),
            "duration_ms": integer("How long to hold, in milliseconds.", minimum: 100, maximum: maxDurationMs, default: defaultLongPressMs),
        ], ["x", "y"]),
        "swipe": ([
            "from_x": number("Start X in screenshot pixels.", minimum: 0), "from_y": number("Start Y in screenshot pixels.", minimum: 0),
            "to_x": number("End X in screenshot pixels.", minimum: 0), "to_y": number("End Y in screenshot pixels.", minimum: 0),
            "duration_ms": integer("Swipe duration in milliseconds. 500 or more doesn't coast; shorter flings.",
                                   minimum: 50, maximum: maxDurationMs, default: defaultSwipeMs),
        ], ["from_x", "from_y", "to_x", "to_y"]),
        "scroll": ([
            "direction": string("\"down\" reveals content below, \"up\" content above; left/right likewise.",
                                enumValues: ScrollDirection.allCases.map(\.rawValue)),
            "amount": number("Fraction of the screen to scroll, 0.1 to 1.0 (default 0.5).", minimum: 0.1, maximum: 1.0),
        ], ["direction"]),
        "type_text": ([
            "text": string("ASCII text to type with a US keyboard layout. Focus a text field first.", minLength: 1),
            "submit": ["type": "boolean", "description": "Press return after typing.", "default": false],
        ], ["text"]),
        "press_key": (["key": string(keyDescription, minLength: 1)], ["key"]),
        "open_app": (["name": string("App name as shown under its icon, e.g. \"Settings\". Opens it via Spotlight.", minLength: 1)], ["name"]),
        "wait": (["ms": integer("Milliseconds to wait.", minimum: 0, maximum: maxWaitMs)], ["ms"]),
    ]

    static var batchItemSchema: JSONValue {
        let names = ["tap", "tap_text", "long_press", "swipe", "scroll", "type_text", "press_key", "open_app", "wait"]
        let variants: [JSONValue] = names.map { name in
            let spec = actionProperties[name]!
            var props = spec.props
            props["action"] = ["const": .string(name)]
            return [
                "type": "object",
                "properties": .object(props),
                "required": .array((["action"] + spec.required).map { .string($0) }),
                "additionalProperties": false,
            ]
        }
        return [
            "type": "object",
            "description": "One step: {\"action\": \"tap\", \"x\": 100, \"y\": 200}. Same fields as the matching tool; \"wait\" takes {\"ms\"}.",
            "oneOf": .array(variants),
        ]
    }

    public static let definitions: [MCPToolDefinition] = {
        func def(_ name: String, _ title: String, _ description: String, readOnly: Bool = false) -> MCPToolDefinition {
            let spec = actionProperties[name]!
            return MCPToolDefinition(name: name, title: title, description: description,
                                     inputSchema: object(spec.props, required: spec.required), readOnly: readOnly)
        }
        return [
            MCPToolDefinition(name: "status", title: "Status",
                              description: "Health of every part (USB, screen, Bluetooth, AssistiveTouch, calibration, MCP) with what to fix. Call this first if anything fails.",
                              inputSchema: object([:]), readOnly: true),
            MCPToolDefinition(name: "screenshot", title: "Screenshot",
                              description: "Current iPhone screen as an image plus the recognized text with centre coordinates. Coordinates for every other tool use this image's pixels.",
                              inputSchema: object(["include_text": ["type": "boolean", "description": "Also return on-screen text with coordinates (default true).", "default": true]]),
                              readOnly: true),
            def("tap", "Tap", "Tap at a point of the latest screenshot. Returns a fresh screenshot."),
            def("tap_text", "Tap text", "Find visible text on screen (OCR) and tap its centre. Returns a fresh screenshot."),
            def("long_press", "Long press", "Press and hold at a point. Returns a fresh screenshot."),
            def("swipe", "Swipe", "Drag from one point to another. Returns a fresh screenshot."),
            def("scroll", "Scroll", "Scroll the content in a direction by a fraction of the screen. Returns a fresh screenshot."),
            def("type_text", "Type text", "Type ASCII text into the focused field, optionally pressing return. Returns a fresh screenshot."),
            def("press_key", "Press key", "Press a key or combo (return, backspace, escape, arrows, home, cmd+space...). Returns a fresh screenshot."),
            def("open_app", "Open app", "Go Home and open an app by name with Spotlight. Returns a fresh screenshot."),
            MCPToolDefinition(name: "calibrate", title: "Calibrate pointer",
                              description: "Measure how far the iPhone moves the pointer per mouse step (takes ~30 s). Needed once per iPhone, or when taps land in the wrong place. AssistiveTouch must be on.",
                              inputSchema: object([:])),
            MCPToolDefinition(name: "batch", title: "Batch",
                              description: "Run several actions in order with one screenshot at the end. Stops at the first failing step and says which.",
                              inputSchema: object([
                                  "actions": [
                                      "type": "array", "minItems": 1, "maxItems": .number(Double(maxBatchActions)),
                                      "description": "Steps to run in order.",
                                      "items": batchItemSchema,
                                  ],
                              ], required: ["actions"])),
        ]
    }()

    public static var names: [String] { definitions.map(\.name) }
    public static func definition(named name: String) -> MCPToolDefinition? { definitions.first { $0.name == name } }
    public static var listJSON: JSONValue { .array(definitions.map(\.json)) }

    // MARK: Argument parsing

    /// Parses the arguments of an action tool (tap, tap_text, ..., wait) into a PhoneAction.
    /// `context` prefixes argument names in errors (e.g. "actions[2].").
    public static func parseAction(_ tool: String, _ args: [String: JSONValue], context: String = "") throws -> PhoneAction {
        guard let spec = actionProperties[tool] else {
            throw OpenTapError.invalidArgument("\(context)action", why: "\"\(tool)\" is not an action",
                                               fix: "Use one of: \(actionProperties.keys.sorted().joined(separator: ", "))")
        }
        let allowed = Set(spec.props.keys).union(context.isEmpty ? [] : ["action"])
        if let extra = args.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw OpenTapError.invalidArgument("\(context)\(extra)", why: "\(tool) has no argument named \"\(extra)\"",
                                               fix: "Use only: \(spec.props.keys.sorted().joined(separator: ", "))")
        }
        let a = Args(args, context: context)
        switch tool {
        case "tap":
            return .tap(x: try a.coordinate("x"), y: try a.coordinate("y"))
        case "tap_text":
            return .tapText(text: try a.text("text"), occurrence: try a.int("occurrence", default: 1, range: 1...1000))
        case "long_press":
            return .longPress(x: try a.coordinate("x"), y: try a.coordinate("y"),
                              durationMs: try a.int("duration_ms", default: defaultLongPressMs, range: 100...maxDurationMs))
        case "swipe":
            return .swipe(fromX: try a.coordinate("from_x"), fromY: try a.coordinate("from_y"),
                          toX: try a.coordinate("to_x"), toY: try a.coordinate("to_y"),
                          durationMs: try a.int("duration_ms", default: defaultSwipeMs, range: 50...maxDurationMs))
        case "scroll":
            let raw = try a.text("direction").lowercased()
            guard let dir = ScrollDirection(rawValue: raw) else {
                throw OpenTapError.invalidArgument("\(context)direction", why: "\"\(raw)\" is not a direction",
                                                   fix: "Use up, down, left or right")
            }
            return .scroll(direction: dir, amount: try a.double("amount", default: defaultScrollAmount, range: 0.1...1.0))
        case "type_text":
            let text = try a.text("text", trim: false)
            guard text.count <= maxTextLength else {
                throw OpenTapError.invalidArgument("\(context)text", why: "The text is \(text.count) characters long; the limit is \(maxTextLength)",
                                                   fix: "Type it in several type_text calls")
            }
            return .typeText(text: text, submit: try a.bool("submit", default: false))
        case "press_key":
            let key = try a.text("key")
            do { _ = try KeyCombo.parse(key) } catch {
                let e = OpenTapError.wrap(error, what: "Invalid key")
                throw OpenTapError(.invalidArgument, what: "Invalid value for '\(context)key'",
                                   why: stepNote(context) + e.why, fix: e.fix)
            }
            return .pressKey(key: key)
        case "open_app":
            return .openApp(name: try a.text("name"))
        case "wait":
            return .wait(ms: try a.int("ms", default: nil, range: 0...maxWaitMs))
        default:
            throw OpenTapError(.internalError, what: "Unhandled action \(tool)", why: "The MCP module is missing a case",
                               fix: "Report this bug to the OpenTap project")
        }
    }

    /// "Step 3: " for a batch context like "actions[2].", plus a reminder that nothing ran; "" outside a batch.
    static func stepNote(_ context: String) -> String {
        guard context.hasPrefix("actions["), let close = context.firstIndex(of: "]"),
              let i = Int(context[context.index(context.startIndex, offsetBy: 8)..<close]) else { return "" }
        return "Step \(i + 1) (no steps were run): "
    }

    /// Parses `batch` arguments. Each item: {"action": "tap", "x": 1, "y": 2}. Also accepts
    /// {"tool"/"name": "tap", "arguments"/"args": {...}} for clients that nest arguments.
    public static func parseBatch(_ args: [String: JSONValue]) throws -> [PhoneAction] {
        if let extra = args.keys.sorted().first(where: { $0 != "actions" }) {
            throw OpenTapError.invalidArgument(extra, why: "batch has no argument named \"\(extra)\"", fix: "Pass only \"actions\"")
        }
        guard let value = args["actions"] else {
            throw OpenTapError.invalidArgument("actions", why: "It is missing",
                                               fix: "Pass \"actions\": [{\"action\": \"tap\", \"x\": 100, \"y\": 200}, ...]")
        }
        guard let items = value.arrayValue else {
            throw OpenTapError.invalidArgument("actions", why: "It is \(value.typeName), not an array",
                                               fix: "Pass a list of steps like [{\"action\": \"tap\", \"x\": 100, \"y\": 200}]")
        }
        guard !items.isEmpty else {
            throw OpenTapError.invalidArgument("actions", why: "The list is empty", fix: "Pass at least one step")
        }
        guard items.count <= maxBatchActions else {
            throw OpenTapError.invalidArgument("actions", why: "There are \(items.count) steps; the limit is \(maxBatchActions)",
                                               fix: "Split them into several batch calls")
        }
        return try items.enumerated().map { i, item in
            let ctx = "actions[\(i)]."
            guard var obj = item.objectValue else {
                throw OpenTapError.invalidArgument("actions[\(i)]", why: "Step \(i + 1) is \(item.typeName), not an object",
                                                   fix: "Write each step like {\"action\": \"tap\", \"x\": 100, \"y\": 200}")
            }
            // "action"/"tool" name the step; "name" only when arguments are nested ({"name": "tap", "arguments": {...}}),
            // because open_app has its own "name" argument.
            let hasNested = obj["arguments"] != nil || obj["args"] != nil
            let nameKey = ["action", "tool"].first { obj[$0] != nil } ?? (hasNested && obj["name"] != nil ? "name" : nil)
            guard let key = nameKey, let name = obj[key]?.stringValue else {
                throw OpenTapError.invalidArgument("\(ctx)action", why: "Step \(i + 1) has no \"action\"",
                                                   fix: "Add \"action\": one of \(actionProperties.keys.sorted().joined(separator: ", "))")
            }
            obj.removeValue(forKey: key)
            if let nested = (obj["arguments"] ?? obj["args"])?.objectValue {
                obj.removeValue(forKey: "arguments"); obj.removeValue(forKey: "args")
                for (k, v) in nested { obj[k] = v }
            }
            guard actionProperties[name] != nil else {
                let hint = (name == "batch" || name == "screenshot" || name == "status" || name == "calibrate")
                    ? "\(name) can't be a batch step" : "\"\(name)\" is not an action"
                throw OpenTapError.invalidArgument("\(ctx)action", why: "Step \(i + 1): \(hint)",
                                                   fix: "Use one of: \(actionProperties.keys.sorted().joined(separator: ", "))")
            }
            return try parseAction(name, obj, context: ctx)
        }
    }

    /// Typed argument reader with what/why/fix errors.
    struct Args {
        let values: [String: JSONValue]
        let context: String
        init(_ values: [String: JSONValue], context: String) { self.values = values; self.context = context }

        func label(_ k: String) -> String { context + k }

        func number(_ k: String) throws -> Double? {
            guard let v = values[k], !v.isNull else { return nil }
            switch v {
            case .number(let d) where d.isFinite: return d
            case .string(let s):
                if let d = Double(s.trimmingCharacters(in: .whitespaces)), d.isFinite { return d }
                throw OpenTapError.invalidArgument(label(k), why: "\"\(s.prefix(40))\" is not a number", fix: "Pass a number, e.g. \(k): 120")
            default:
                throw OpenTapError.invalidArgument(label(k), why: "It is \(v.typeName), not a number", fix: "Pass a number, e.g. \(k): 120")
            }
        }

        func coordinate(_ k: String) throws -> Double {
            guard let d = try number(k) else {
                throw OpenTapError.invalidArgument(label(k), why: "It is missing",
                                                   fix: "Pass \(k) in pixels of the latest screenshot (call screenshot to see its size)")
            }
            guard d >= 0 else {
                throw OpenTapError.invalidArgument(label(k), why: "\(JSONValue.format(d)) is negative",
                                                   fix: "Use a point inside the latest screenshot (origin is the top-left corner)")
            }
            guard d <= maxCoordinate else {
                throw OpenTapError.invalidArgument(label(k), why: "\(JSONValue.format(d)) is far outside any screenshot (limit \(Int(maxCoordinate)))",
                                                   fix: "Use pixel coordinates from the latest screenshot (about 590 px wide; call screenshot to see its size)")
            }
            return d
        }

        func double(_ k: String, default def: Double, range: ClosedRange<Double>) throws -> Double {
            let d = try number(k) ?? def
            guard range.contains(d) else {
                throw OpenTapError.invalidArgument(label(k), why: "\(JSONValue.format(d)) is outside \(JSONValue.format(range.lowerBound))...\(JSONValue.format(range.upperBound))",
                                                   fix: "Pass a value between \(JSONValue.format(range.lowerBound)) and \(JSONValue.format(range.upperBound))")
            }
            return d
        }

        func int(_ k: String, default def: Int?, range: ClosedRange<Int>) throws -> Int {
            guard let d = try number(k) else {
                if let def { return def }
                throw OpenTapError.invalidArgument(label(k), why: "It is missing", fix: "Pass a whole number between \(range.lowerBound) and \(range.upperBound)")
            }
            guard d == d.rounded(), abs(d) < 1e9 else {
                throw OpenTapError.invalidArgument(label(k), why: "\(JSONValue.format(d)) is not a whole number", fix: "Pass a whole number, e.g. \(range.lowerBound)")
            }
            let n = Int(d)
            guard range.contains(n) else {
                throw OpenTapError.invalidArgument(label(k), why: "\(n) is outside \(range.lowerBound)...\(range.upperBound)",
                                                   fix: "Pass a whole number between \(range.lowerBound) and \(range.upperBound)")
            }
            return n
        }

        func text(_ k: String, trim: Bool = true) throws -> String {
            guard let v = values[k], !v.isNull else {
                throw OpenTapError.invalidArgument(label(k), why: "It is missing", fix: "Pass \(k) as a string")
            }
            guard let s = v.stringValue else {
                throw OpenTapError.invalidArgument(label(k), why: "It is \(v.typeName), not a string", fix: "Pass \(k) as a string")
            }
            let t = trim ? s.trimmingCharacters(in: .whitespacesAndNewlines) : s
            guard !t.isEmpty else {
                throw OpenTapError.invalidArgument(label(k), why: "It is empty", fix: "Pass a non-empty \(k)")
            }
            return t
        }

        func bool(_ k: String, default def: Bool) throws -> Bool {
            guard let v = values[k], !v.isNull else { return def }
            switch v {
            case .bool(let b): return b
            case .string(let s) where ["true", "false"].contains(s.lowercased()): return s.lowercased() == "true"
            default:
                throw OpenTapError.invalidArgument(label(k), why: "It is \(v.typeName), not true/false", fix: "Pass \(k): true or \(k): false")
            }
        }
    }
}
