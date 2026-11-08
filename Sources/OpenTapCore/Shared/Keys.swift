import Foundation

/// HID keyboard usage IDs (usage page 0x07) used by OpenTap.
public enum KeyUsage {
    public static let a: UInt8 = 0x04          // a...z = 0x04...0x1D
    public static let one: UInt8 = 0x1E        // 1...9 = 0x1E...0x26
    public static let zero: UInt8 = 0x27
    public static let returnKey: UInt8 = 0x28
    public static let escape: UInt8 = 0x29
    public static let backspace: UInt8 = 0x2A
    public static let tab: UInt8 = 0x2B
    public static let space: UInt8 = 0x2C
    public static let forwardDelete: UInt8 = 0x4C
    public static let right: UInt8 = 0x4F
    public static let left: UInt8 = 0x50
    public static let down: UInt8 = 0x51
    public static let up: UInt8 = 0x52
}

/// Consumer page (0x0C) usages.
public enum ConsumerUsage {
    public static let acHome: UInt16 = 0x0223
    public static let playPause: UInt16 = 0x00CD
    public static let volumeUp: UInt16 = 0x00E9
    public static let volumeDown: UInt16 = 0x00EA
    public static let mute: UInt16 = 0x00E2
}

public struct KeyStroke: Equatable, Hashable, Sendable {
    public var modifiers: KeyModifiers
    public var usage: UInt8
    public init(_ usage: UInt8, _ modifiers: KeyModifiers = []) { self.usage = usage; self.modifiers = modifiers }
}

/// US ANSI layout, printable ASCII + \n + \t.
public enum USKeyboardLayout {
    private static let table: [Character: KeyStroke] = {
        var t: [Character: KeyStroke] = [:]
        for (i, c) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
            t[c] = KeyStroke(KeyUsage.a + UInt8(i))
            t[Character(c.uppercased())] = KeyStroke(KeyUsage.a + UInt8(i), .shift)
        }
        for (i, c) in "123456789".enumerated() { t[c] = KeyStroke(KeyUsage.one + UInt8(i)) }
        t["0"] = KeyStroke(KeyUsage.zero)
        for (i, c) in "!@#$%^&*(".enumerated() { t[c] = KeyStroke(KeyUsage.one + UInt8(i), .shift) }
        t[")"] = KeyStroke(KeyUsage.zero, .shift)
        let pairs: [(Character, Character, UInt8)] = [
            ("-", "_", 0x2D), ("=", "+", 0x2E), ("[", "{", 0x2F), ("]", "}", 0x30), ("\\", "|", 0x31),
            (";", ":", 0x33), ("'", "\"", 0x34), ("`", "~", 0x35), (",", "<", 0x36), (".", ">", 0x37), ("/", "?", 0x38),
        ]
        for (plain, shifted, u) in pairs { t[plain] = KeyStroke(u); t[shifted] = KeyStroke(u, .shift) }
        t[" "] = KeyStroke(KeyUsage.space)
        t["\n"] = KeyStroke(KeyUsage.returnKey)
        t["\t"] = KeyStroke(KeyUsage.tab)
        return t
    }()

    public static func stroke(for c: Character) -> KeyStroke? { table[c] }

    /// Strokes for a whole string, or an `.invalidArgument` error naming the first unsupported character.
    public static func strokes(for text: String) throws -> [KeyStroke] {
        try text.map { c in
            guard let s = table[c] else {
                throw OpenTapError.invalidArgument("text",
                    why: "The character '\(c)' can't be typed with a US keyboard (only printable ASCII, newline and tab)",
                    fix: "Remove or replace '\(c)'; for emoji or accented text, paste it in another way")
            }
            return s
        }
    }
}

/// A key or combo as written by agents: "return", "backspace", "cmd+space", "shift+tab", "home", "a".
public struct KeyCombo: Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        case key(UInt8)
        case consumer(UInt16)
    }
    public var modifiers: KeyModifiers
    public var target: Target

    public init(modifiers: KeyModifiers = [], target: Target) { self.modifiers = modifiers; self.target = target }

    public static let supportedNames = [
        "return", "enter", "backspace", "delete", "forwarddelete", "tab", "escape", "esc", "space",
        "up", "down", "left", "right", "home", "volumeup", "volumedown", "mute", "playpause",
        "a-z", "0-9", "modifiers: cmd, shift, option/alt, ctrl joined with +",
    ]

    public static func parse(_ string: String) throws -> KeyCombo {
        let parts = string.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last, !last.isEmpty else {
            throw OpenTapError.invalidArgument("key", why: "No key was given", fix: "Pass a key like \"return\" or \"cmd+space\"")
        }
        var mods: KeyModifiers = []
        for m in parts.dropLast() {
            switch m {
            case "cmd", "command", "meta", "super": mods.insert(.command)
            case "shift": mods.insert(.shift)
            case "alt", "option", "opt": mods.insert(.option)
            case "ctrl", "control": mods.insert(.control)
            default:
                throw OpenTapError.invalidArgument("key", why: "'\(m)' is not a modifier",
                                                   fix: "Use cmd, shift, option or ctrl before '+', e.g. \"cmd+space\"")
            }
        }
        let named: [String: Target] = [
            "return": .key(KeyUsage.returnKey), "enter": .key(KeyUsage.returnKey),
            "backspace": .key(KeyUsage.backspace), "delete": .key(KeyUsage.backspace),
            "forwarddelete": .key(KeyUsage.forwardDelete), "tab": .key(KeyUsage.tab),
            "escape": .key(KeyUsage.escape), "esc": .key(KeyUsage.escape), "space": .key(KeyUsage.space),
            "up": .key(KeyUsage.up), "down": .key(KeyUsage.down), "left": .key(KeyUsage.left), "right": .key(KeyUsage.right),
            "home": .consumer(ConsumerUsage.acHome), "volumeup": .consumer(ConsumerUsage.volumeUp),
            "volumedown": .consumer(ConsumerUsage.volumeDown), "mute": .consumer(ConsumerUsage.mute),
            "playpause": .consumer(ConsumerUsage.playPause),
        ]
        if let t = named[last] { return KeyCombo(modifiers: mods, target: t) }
        if last.count == 1, let c = last.first, let s = USKeyboardLayout.stroke(for: c) {
            return KeyCombo(modifiers: mods.union(s.modifiers), target: .key(s.usage))
        }
        throw OpenTapError.invalidArgument("key", why: "'\(last)' is not a key OpenTap knows",
                                           fix: "Use one of: \(supportedNames.joined(separator: ", "))")
    }
}
