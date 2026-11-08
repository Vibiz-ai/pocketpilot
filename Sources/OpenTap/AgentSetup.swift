import Foundation
import OpenTapCore

/// Talks to OpenTap's own MCP endpoint exactly like an agent would: initialize, then tools/call status.
enum MCPSelfTest {
    static func run(url: String = MCPDefaults.url) async throws -> String {
        guard let endpoint = URL(string: url) else {
            throw OpenTapError.invalidArgument("url", why: "\(url) is not a valid URL", fix: "Restart OpenTap")
        }
        let initialize: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": [
                "protocolVersion": MCPDefaults.protocolVersion,
                "capabilities": [String: Any](),
                "clientInfo": ["name": "opentap-self-test", "version": "1"],
            ],
        ]
        let (initBody, initResponse) = try await post(endpoint, initialize, session: nil)
        guard initBody["result"] != nil else { throw rpcError(initBody, step: "initialize") }
        let session = initResponse.value(forHTTPHeaderField: "Mcp-Session-Id")

        _ = try? await post(endpoint, ["jsonrpc": "2.0", "method": "notifications/initialized"], session: session)

        let call: [String: Any] = ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
                                   "params": ["name": "status", "arguments": [String: Any]()]]
        let (body, _) = try await post(endpoint, call, session: session)
        guard let result = body["result"] as? [String: Any] else { throw rpcError(body, step: "tools/call status") }
        let text = ((result["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.first) ?? ""
        if result["isError"] as? Bool == true {
            throw OpenTapError(.network, what: "The status tool returned an error",
                               why: text.isEmpty ? "No details were returned" : text,
                               fix: "Fix the step it mentions, then press Test it again")
        }
        return text.isEmpty ? "The status tool answered" : String(text.prefix(400))
    }

    private static func post(_ url: URL, _ json: [String: Any], session: String?) async throws -> ([String: Any], HTTPURLResponse) {
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue(MCPDefaults.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let session { req.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
        req.httpBody = try JSONSerialization.data(withJSONObject: json)
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw OpenTapError(.network, what: "Couldn't reach the OpenTap MCP server",
                               why: "\(url.absoluteString) did not answer (\(error.localizedDescription))",
                               fix: "Press Start server on this step; if port \(MCPDefaults.port) is taken, quit the other app using it")
        }
        guard let http = response as? HTTPURLResponse else {
            throw OpenTapError(.network, what: "The MCP server sent a non-HTTP reply", why: "Unexpected response type",
                               fix: "Restart the server from the Phone menu")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenTapError(.network, what: "The MCP server answered HTTP \(http.statusCode)",
                               why: String(data: data, encoding: .utf8).map { String($0.prefix(200)) } ?? "No body",
                               fix: "Restart the server from the Phone menu and test again")
        }
        if data.isEmpty { return ([:], http) }
        return (try parse(data, contentType: http.value(forHTTPHeaderField: "Content-Type") ?? ""), http)
    }

    /// Accepts plain JSON or an SSE stream (uses the last `data:` event that is a JSON-RPC response).
    static func parse(_ data: Data, contentType: String) throws -> [String: Any] {
        if contentType.contains("text/event-stream") {
            let text = String(decoding: data, as: UTF8.self)
            let events = text.components(separatedBy: "\n").filter { $0.hasPrefix("data:") }
                .map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
            for event in events.reversed() {
                if let obj = try? JSONSerialization.jsonObject(with: Data(event.utf8)) as? [String: Any],
                   obj["result"] != nil || obj["error"] != nil { return obj }
            }
        } else if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        throw OpenTapError(.network, what: "The MCP server sent a reply OpenTap couldn't read",
                           why: "It was not JSON-RPC (\(String(decoding: data.prefix(120), as: UTF8.self)))",
                           fix: "Restart the server from the Phone menu and test again")
    }

    private static func rpcError(_ body: [String: Any], step: String) -> OpenTapError {
        let message = (body["error"] as? [String: Any])?["message"] as? String ?? "No result in the reply"
        return OpenTapError(.network, what: "MCP \(step) failed", why: message,
                            fix: "Restart the server from the Phone menu and test again")
    }
}

/// Finds the claude CLI the way a Terminal would (an app opened from Finder only has the minimal system PATH),
/// then runs it directly: checks for an existing "opentap" entry, replaces it when it points elsewhere, adds it.
enum ClaudeInstaller {
    enum Registration: Equatable {
        case notInstalled(searched: [String])
        case notAdded
        case added(url: String)
        case otherURL(String)
    }

    /// claude's absolute path, or nil plus the places searched.
    static func locate() async -> (String?, [String]) {
        let fm = FileManager.default
        var searched = MCPClientConfig.claudeCandidatePaths()
        if let p = MCPClientConfig.findClaudeCLI() { return (p, searched) }
        // Login shell, then interactive login shell (reads ~/.zshrc, where installers and nvm add to PATH).
        for flags in ["-lc", "-ilc"] {
            searched.append("zsh \(flags) 'command -v claude'")
            if let (status, out) = try? await run("/bin/zsh", [flags, "command -v claude"], timeout: 8), status == 0,
               let line = out.components(separatedBy: .newlines).last(where: { $0.hasPrefix("/") }),
               fm.isExecutableFile(atPath: line.trimmingCharacters(in: .whitespaces)) {
                return (line.trimmingCharacters(in: .whitespaces), searched)
            }
        }
        if let (status, out) = try? await run("/bin/zsh", ["-lc", "npm prefix -g"], timeout: 8), status == 0,
           let prefix = out.components(separatedBy: .newlines).last(where: { $0.hasPrefix("/") }) {
            let p = prefix.trimmingCharacters(in: .whitespaces) + "/bin/claude"
            searched.append(p)
            if fm.isExecutableFile(atPath: p) { return (p, searched) }
        }
        return (nil, searched)
    }

    static func notInstalledError(_ searched: [String]) -> OpenTapError {
        OpenTapError(.frameworkUnavailable, what: "Couldn't find Claude Code on this Mac",
                     why: "The `claude` command isn't in any of: \(searched.joined(separator: ", "))",
                     fix: "Install Claude Code (npm install -g @anthropic-ai/claude-code, or the installer from claude.com/code), or copy the command above and run it in Terminal")
    }

    /// Whether Claude Code has an "opentap" server, and where it points.
    static func registration(url: String = MCPDefaults.url) async -> Registration {
        let (path, searched) = await locate()
        guard let path else { return .notInstalled(searched: searched) }
        guard let (_, out) = try? await runClaude(path, ["mcp", "get", MCPDefaults.serverName]),
              let reg = MCPClientConfig.parseClaudeGet(out), let current = reg.url else { return .notAdded }
        return MCPClientConfig.sameEndpoint(current, url) ? .added(url: current) : .otherURL(current)
    }

    static func install(url: String = MCPDefaults.url) async throws -> String {
        let (found, searched) = await locate()
        guard let path = found else { throw notInstalledError(searched) }
        var replaced: String?
        if let (_, out) = try? await runClaude(path, ["mcp", "get", MCPDefaults.serverName]),
           let reg = MCPClientConfig.parseClaudeGet(out) {
            if let current = reg.url, MCPClientConfig.sameEndpoint(current, url) {
                return "OpenTap is already added to Claude Code (\(current))"
            }
            // An old entry pointing somewhere else (another port, the mock, a typo): replace it.
            let scope = reg.scope ?? "user"
            let (rs, rout) = try await runClaude(path, ["mcp", "remove", MCPDefaults.serverName, "-s", scope])
            guard rs == 0 else {
                throw OpenTapError(.io, what: "opentap is configured in Claude Code for \(reg.url ?? "another address")",
                                   why: "It was added earlier with another address, and removing it failed: \(rout.prefix(200))",
                                   fix: "Run in Terminal: claude mcp remove opentap -s \(scope), then press Add to Claude Code again")
            }
            replaced = reg.url ?? "another address"
        }
        let (status, output) = try await runClaude(path, MCPClientConfig.claudeArguments(url: url))
        guard status == 0 else {
            throw OpenTapError(.io, what: "`claude mcp add` failed (exit \(status))",
                               why: output.isEmpty ? "It printed nothing" : String(output.prefix(300)),
                               fix: "Copy the command and run it in Terminal to see the full message")
        }
        if let old = replaced { return "Replaced the old opentap entry (it pointed at \(old)) with \(url)" }
        return "Added OpenTap to Claude Code (\(url))"
    }

    private static func runClaude(_ path: String, _ args: [String]) async throws -> (Int32, String) {
        // npm installs are `#!/usr/bin/env node` scripts: node usually sits next to claude (nvm) or in Homebrew.
        let dir = (path as NSString).deletingLastPathComponent
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = [dir, "/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"].joined(separator: ":")
        return try await run(path, args, environment: env, timeout: 60)
    }

    private static func run(_ launchPath: String, _ args: [String], environment: [String: String]? = nil,
                            timeout: TimeInterval) async throws -> (Int32, String) {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: launchPath)
            p.arguments = args
            if let environment { p.environment = environment }
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            p.terminationHandler = { proc in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let out = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                cont.resume(returning: (proc.terminationStatus, out))
            }
            do { try p.run() } catch {
                cont.resume(throwing: OpenTapError(.io, what: "Couldn't run \((launchPath as NSString).lastPathComponent)",
                                                   why: error.localizedDescription,
                                                   fix: "Copy the command and paste it into Terminal"))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
        }
    }
}
