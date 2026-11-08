import Foundation

/// Owner: mcp. Ready-to-paste setup for MCP clients (Claude Code, Cursor, Codex, generic).
public enum MCPClientConfig {
    public enum Client: String, CaseIterable, Sendable {
        case claudeCode, cursor, codex, generic

        public var title: String {
            switch self {
            case .claudeCode: return "Claude Code"
            case .cursor: return "Cursor"
            case .codex: return "Codex"
            case .generic: return "Other MCP clients"
            }
        }
    }

    public struct Snippet: Equatable, Sendable, Identifiable {
        public var id: String { "\(client.rawValue).\(kind)" }
        public var client: Client
        /// "command", "json" or "toml".
        public var kind: String
        public var title: String
        /// Where it goes, e.g. "Run in Terminal" or "~/.cursor/mcp.json".
        public var location: String
        public var content: String
    }

    public static func url(host: String = MCPDefaults.host, port: UInt16 = MCPDefaults.port) -> String {
        "http://\(host):\(port)\(MCPDefaults.path)"
    }

    /// `claude mcp add --transport http --scope user opentap <url>`
    public static func claudeCommand(url: String = MCPDefaults.url, scope: String = "user") -> String {
        "claude mcp add --transport http --scope \(scope) \(MCPDefaults.serverName) \(url)"
    }

    /// Removes a previous entry first so re-running onboarding never fails with "already exists".
    public static func claudeReplaceCommand(url: String = MCPDefaults.url) -> String {
        "claude mcp remove --scope user \(MCPDefaults.serverName) 2>/dev/null; \(claudeCommand(url: url))"
    }

    /// The argv for running the claude CLI directly (no shell).
    public static func claudeArguments(url: String = MCPDefaults.url, scope: String = "user") -> [String] {
        ["mcp", "add", "--transport", "http", "--scope", scope, MCPDefaults.serverName, url]
    }

    /// Project `.mcp.json` for Claude Code.
    public static func claudeCodeJSON(url: String = MCPDefaults.url) -> String {
        """
        {
          "mcpServers": {
            "\(MCPDefaults.serverName)": {
              "type": "http",
              "url": "\(url)"
            }
          }
        }
        """
    }

    /// `~/.cursor/mcp.json`.
    public static func cursorJSON(url: String = MCPDefaults.url) -> String {
        """
        {
          "mcpServers": {
            "\(MCPDefaults.serverName)": {
              "url": "\(url)"
            }
          }
        }
        """
    }

    /// `codex mcp add opentap --url <url>`
    public static func codexCommand(url: String = MCPDefaults.url) -> String {
        "codex mcp add \(MCPDefaults.serverName) --url \(url)"
    }

    /// `~/.codex/config.toml`.
    public static func codexTOML(url: String = MCPDefaults.url) -> String {
        """
        [mcp_servers.\(MCPDefaults.serverName)]
        url = "\(url)"
        """
    }

    public static func genericJSON(url: String = MCPDefaults.url) -> String {
        """
        {
          "name": "\(MCPDefaults.serverName)",
          "transport": "streamable-http",
          "url": "\(url)"
        }
        """
    }

    public static func snippets(url: String = MCPDefaults.url) -> [Snippet] {
        [
            Snippet(client: .claudeCode, kind: "command", title: "Claude Code (all projects)", location: "Run in Terminal",
                    content: claudeCommand(url: url)),
            Snippet(client: .claudeCode, kind: "json", title: "Claude Code (one project)", location: ".mcp.json in the project folder",
                    content: claudeCodeJSON(url: url)),
            Snippet(client: .cursor, kind: "json", title: "Cursor", location: "~/.cursor/mcp.json",
                    content: cursorJSON(url: url)),
            Snippet(client: .codex, kind: "command", title: "Codex", location: "Run in Terminal",
                    content: codexCommand(url: url)),
            Snippet(client: .codex, kind: "toml", title: "Codex (config file)", location: "~/.codex/config.toml",
                    content: codexTOML(url: url)),
            Snippet(client: .generic, kind: "json", title: "Any Streamable-HTTP MCP client", location: "Your client's MCP settings",
                    content: genericJSON(url: url)),
        ]
    }

    /// Locations to search for the claude CLI when the GUI app's PATH is minimal.
    public static func claudeCandidatePaths(home: String = NSHomeDirectory()) -> [String] {
        [
            "\(home)/.claude/local/claude",
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.bun/bin/claude",
        ]
    }

    public static func findClaudeCLI(home: String = NSHomeDirectory(), fileManager: FileManager = .default) -> String? {
        claudeCandidatePaths(home: home).first { fileManager.isExecutableFile(atPath: $0) }
    }
}
