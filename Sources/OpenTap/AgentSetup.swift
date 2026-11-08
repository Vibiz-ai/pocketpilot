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

/// Runs `claude mcp add ...` in a login shell so the user's PATH (Homebrew, npm, ~/.local/bin) applies.
enum ClaudeInstaller {
    static func install(command: String = MCPDefaults.claudeAddCommand) async throws -> String {
        let script = "command -v claude >/dev/null 2>&1 || exit 127; \(command)"
        let (status, output) = try await run("/bin/zsh", ["-lc", script])
        if status == 127 {
            throw OpenTapError(.frameworkUnavailable, what: "Claude Code isn't installed on this Mac",
                               why: "The `claude` command was not found in your shell's PATH",
                               fix: "Install Claude Code (npm install -g @anthropic-ai/claude-code), or copy the command and run it where claude is installed")
        }
        if output.localizedCaseInsensitiveContains("already exists") {
            return "OpenTap is already added to Claude Code"
        }
        guard status == 0 else {
            throw OpenTapError(.io, what: "`claude mcp add` failed (exit \(status))",
                               why: output.isEmpty ? "It printed nothing" : String(output.prefix(300)),
                               fix: "Copy the command and run it in Terminal to see the full message")
        }
        return output.isEmpty ? "Added OpenTap to Claude Code" : String(output.prefix(300))
    }

    private static func run(_ launchPath: String, _ args: [String]) async throws -> (Int32, String) {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: launchPath)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.terminationHandler = { proc in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let out = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                cont.resume(returning: (proc.terminationStatus, out))
            }
            do { try p.run() } catch {
                cont.resume(throwing: OpenTapError(.io, what: "Couldn't start a shell to run claude",
                                                   why: error.localizedDescription,
                                                   fix: "Copy the command and paste it into Terminal"))
            }
        }
    }
}
