#!/usr/bin/env python3
"""End-to-end MCP check for OpenTap (owner: qa).

Drives an OpenTap MCP endpoint over Streamable HTTP (JSON-RPC 2.0 over POST, Mcp-Session-Id) and asserts
what comes back. Against `opentap-mock` (the default) it knows the simulated iPhone's screens, so it checks
real outcomes: tap_text opens the app, typed text shows up, scroll moves the list, and so on.

    python3 scripts/mcp_e2e.py --url http://127.0.0.1:47901/mcp           # mock (default)
    python3 scripts/mcp_e2e.py --url http://127.0.0.1:47900/mcp --live    # real phone: protocol checks only
    python3 scripts/mcp_e2e.py --scenario at-off --url ...                 # mock started with --fault at-off
    python3 scripts/mcp_e2e.py call screenshot '{"include_text":true}' --save-image /tmp/s.jpg

Prints a PASS/FAIL table and exits 1 if any check failed. Standard library only.
"""
import argparse
import base64
import json
import re
import sys
import time
import urllib.error
import urllib.request

PROTOCOL = "2025-06-18"
TOOLS = ["status", "screenshot", "tap", "tap_text", "long_press", "swipe", "scroll",
         "type_text", "press_key", "open_app", "calibrate", "batch"]
TEXT_LINE = re.compile(r'^("(?:[^"\\]|\\.)*") \((-?\d+), (-?\d+)\)$')


class MCPError(Exception):
    pass


class Client:
    def __init__(self, url, timeout):
        self.url = url
        self.timeout = timeout
        self.session = None
        self.next_id = 1

    def post(self, payload, session=True):
        data = json.dumps(payload).encode()
        req = urllib.request.Request(self.url, data=data, method="POST")
        req.add_header("Content-Type", "application/json")
        req.add_header("Accept", "application/json, text/event-stream")
        if session and self.session:
            req.add_header("Mcp-Session-Id", self.session)
            req.add_header("MCP-Protocol-Version", PROTOCOL)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                return resp.status, dict(resp.headers), resp.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            return e.code, dict(e.headers), e.read().decode("utf-8", "replace")

    @staticmethod
    def parse_body(headers, body, want_id):
        ctype = next((v for k, v in headers.items() if k.lower() == "content-type"), "")
        if "text/event-stream" in ctype:
            for line in body.splitlines():
                if line.startswith("data:"):
                    msg = json.loads(line[5:].strip())
                    if msg.get("id") == want_id:
                        return msg
            raise MCPError("SSE stream ended without a response for id %r" % want_id)
        return json.loads(body)

    def rpc(self, method, params=None, session=True):
        rid = self.next_id
        self.next_id += 1
        msg = {"jsonrpc": "2.0", "id": rid, "method": method}
        if params is not None:
            msg["params"] = params
        status, headers, body = self.post(msg, session=session)
        if status != 200:
            raise MCPError("HTTP %d for %s: %s" % (status, method, body[:300]))
        resp = self.parse_body(headers, body, rid)
        return resp, headers

    def initialize(self):
        resp, headers = self.rpc("initialize", {"protocolVersion": PROTOCOL, "capabilities": {},
                                                "clientInfo": {"name": "opentap-qa", "version": "1"}}, session=False)
        self.session = next((v for k, v in headers.items() if k.lower() == "mcp-session-id"), None)
        return resp

    def notify(self, method):
        status, _, body = self.post({"jsonrpc": "2.0", "method": method})
        return status, body

    def call(self, name, arguments=None):
        resp, _ = self.rpc("tools/call", {"name": name, "arguments": arguments or {}})
        if "error" in resp:
            raise MCPError("JSON-RPC error for %s: %s" % (name, json.dumps(resp["error"])[:400]))
        return ToolResult(resp["result"])


class ToolResult:
    def __init__(self, result):
        self.raw = result
        self.is_error = bool(result.get("isError"))
        content = result.get("content", [])
        self.text = "\n".join(c.get("text", "") for c in content if c.get("type") == "text")
        self.images = [c for c in content if c.get("type") == "image"]
        self.ocr = []
        for line in self.text.splitlines():
            m = TEXT_LINE.match(line.strip())
            if m:
                self.ocr.append((json.loads(m.group(1)), int(m.group(2)), int(m.group(3))))
        size = re.search(r"Screenshot (\d+)x(\d+) px", self.text)
        self.size = (int(size.group(1)), int(size.group(2))) if size else None

    def has(self, label):
        return any(t.lower() == label.lower() for t, _, _ in self.ocr)

    def find(self, label):
        for t, x, y in self.ocr:
            if t.lower() == label.lower():
                return x, y
        return None

    def labels(self):
        return [t for t, _, _ in self.ocr]

    def brief(self):
        if self.is_error:
            return self.text.replace("\n", " | ")[:240]
        return "ocr=%s" % self.labels()[:10]


class Runner:
    def __init__(self, verbose):
        self.rows = []
        self.verbose = verbose

    def check(self, name, fn):
        t0 = time.time()
        try:
            detail = fn() or ""
            ok = True
        except AssertionError as e:
            ok, detail = False, str(e) or "assertion failed"
        except Exception as e:  # network errors, bad JSON, ...
            ok, detail = False, "%s: %s" % (type(e).__name__, e)
        ms = int((time.time() - t0) * 1000)
        self.rows.append((name, ok, ms, detail))
        mark = "PASS" if ok else "FAIL"
        print("  %-4s %-28s %6d ms  %s" % (mark, name, ms, str(detail)[:150]), flush=True)
        return ok

    def table(self):
        w = max(len(r[0]) for r in self.rows) if self.rows else 10
        line = "+-%s-+------+---------+" % ("-" * w)
        print("\n" + line)
        print("| %-*s | %-4s | %7s |" % (w, "MCP end-to-end check", "", "time"))
        print(line)
        for name, ok, ms, _ in self.rows:
            print("| %-*s | %-4s | %5d ms |" % (w, name, "PASS" if ok else "FAIL", ms))
        print(line)
        failed = [r for r in self.rows if not r[1]]
        print("%d passed, %d failed" % (len(self.rows) - len(failed), len(failed)))
        for name, _, _, detail in failed:
            print("  FAILED %s: %s" % (name, detail))
        return not failed


def expect_ok(r, what):
    assert not r.is_error, "%s returned an error: %s" % (what, r.text.replace("\n", " | ")[:400])
    assert r.images, "%s returned no image" % what
    return r


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--url", default="http://127.0.0.1:47901/mcp")
    ap.add_argument("--live", action="store_true", help="real phone: skip checks that assume the mock's screens")
    ap.add_argument("--timeout", type=float, default=180)
    ap.add_argument("--scenario", choices=["normal", "no-bluetooth", "at-off", "no-frames"], default="normal",
                    help="the fault the mock was started with (opentap-mock --fault ...): checks the error path instead")
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args()

    c = Client(a.url, a.timeout)
    run = Runner(a.verbose)
    st = {}

    def initialize():
        resp = c.initialize()
        assert "result" in resp, "initialize failed: %s" % resp
        res = resp["result"]
        assert res.get("protocolVersion") == PROTOCOL, "protocolVersion %r" % res.get("protocolVersion")
        assert res.get("serverInfo", {}).get("name") == "opentap", "serverInfo %r" % res.get("serverInfo")
        assert "tools" in res.get("capabilities", {}), "no tools capability"
        assert c.session, "no Mcp-Session-Id header on the initialize response"
        return "session %s..." % c.session[:8]

    def initialized():
        status, body = c.notify("notifications/initialized")
        assert status in (200, 202, 204), "notification got HTTP %d %s" % (status, body[:200])
        return "HTTP %d" % status

    def no_session():
        status, _, body = c.post({"jsonrpc": "2.0", "id": 999, "method": "tools/list"}, session=False)
        assert status in (400, 404), "tools/list without a session should be rejected, got HTTP %d" % status
        assert len(body) > 20, "rejection should explain what to do: %r" % body
        return "HTTP %d" % status

    def tools_list():
        resp, _ = c.rpc("tools/list", {})
        tools = resp["result"]["tools"]
        names = [t["name"] for t in tools]
        missing = [t for t in TOOLS if t not in names]
        assert not missing, "missing tools: %s" % missing
        for t in tools:
            assert t.get("inputSchema", {}).get("type") == "object", "%s has no object inputSchema" % t["name"]
            assert t.get("description"), "%s has no description" % t["name"]
        return "%d tools" % len(tools)

    def status():
        r = c.call("status")
        assert not r.is_error, r.text
        for part in ["USB", "Screen", "Bluetooth", "AssistiveTouch", "Calibration", "MCP"]:
            assert part in r.text, "status doesn't mention %s: %s" % (part, r.text[:300])
        if not a.live:
            assert "Mock iPhone" in r.text, "status doesn't name the device: %s" % r.text[:300]
        return r.text.splitlines()[0][:80]

    def screenshot():
        r = expect_ok(c.call("screenshot", {"include_text": True}), "screenshot")
        img = r.images[0]
        assert img.get("mimeType") in ("image/jpeg", "image/png"), "mimeType %r" % img.get("mimeType")
        raw = base64.b64decode(img["data"])
        assert raw[:3] == b"\xff\xd8\xff" or raw[:8] == b"\x89PNG\r\n\x1a\n", "image data is not JPEG/PNG"
        assert r.size, "no screenshot size in text"
        assert 300 <= r.size[0] <= 1300, "unexpected screenshot width %d" % r.size[0]
        st["size"] = r.size
        if not a.live:
            assert r.size[0] == 590, "mock screenshot should be 590 wide, got %d" % r.size[0]
            for label in ["Settings", "Notes", "Safari"]:
                assert r.has(label), "home screen text missing %r: %s" % (label, r.labels())
        return "%dx%d, %d KB, %d texts" % (r.size[0], r.size[1], len(raw) // 1024, len(r.ocr))

    def screenshot_no_text():
        r = expect_ok(c.call("screenshot", {"include_text": False}), "screenshot")
        assert not r.ocr, "include_text=false still returned text"

    def bad_args():
        r = c.call("tap", {"x": "left"})
        assert r.is_error, "tap with a bad x should fail"
        assert "Fix:" in r.text or "fix" in r.text.lower(), "error doesn't say how to fix: %s" % r.text
        return r.text.splitlines()[0][:80]

    def calibrate():
        r = c.call("calibrate")
        assert not r.is_error, "calibrate failed: %s" % r.text.replace("\n", " | ")[:400]
        return r.text.splitlines()[0][:100]

    def home():
        r = expect_ok(c.call("press_key", {"key": "home"}), "press_key home")
        if not a.live:
            assert r.has("Settings") and r.has("Notes"), "not on the home screen: %s" % r.labels()
        return r.brief()

    def tap_text_notes():
        r = expect_ok(c.call("tap_text", {"text": "Notes"}), "tap_text Notes")
        assert r.has("Tap to type"), "Notes didn't open: %s" % r.labels()
        return r.brief()

    def tap_field_and_type():
        pos = None
        r = expect_ok(c.call("screenshot", {"include_text": True}), "screenshot")
        pos = r.find("Tap to type")
        assert pos, "no text field on screen: %s" % r.labels()
        expect_ok(c.call("tap", {"x": pos[0], "y": pos[1]}), "tap the field")
        r = expect_ok(c.call("type_text", {"text": "Hello OpenTap 42!", "submit": True}), "type_text")
        assert r.has("Hello OpenTap 42!"), "typed text not on screen: %s" % r.labels()
        assert r.has("Tap to type"), "submit should have saved and cleared the field: %s" % r.labels()
        return r.brief()

    def long_press():
        expect_ok(c.call("press_key", {"key": "home"}), "home")
        r = expect_ok(c.call("screenshot", {"include_text": True}), "screenshot")
        pos = r.find("Mail")
        assert pos, "no Mail icon: %s" % r.labels()
        r = expect_ok(c.call("long_press", {"x": pos[0], "y": pos[1] - 40, "duration_ms": 900}), "long_press")
        assert r.has("Edit Home Screen"), "long press didn't open the context menu: %s" % r.labels()
        r = expect_ok(c.call("press_key", {"key": "escape"}), "escape")
        assert not r.has("Edit Home Screen"), "escape didn't close the menu"
        return "context menu shown"

    def open_app_settings():
        r = expect_ok(c.call("open_app", {"name": "Settings"}), "open_app Settings")
        assert r.has("Airplane Mode"), "Settings didn't open: %s" % r.labels()
        st["settings_top"] = r.labels()
        return r.brief()

    def scroll():
        r = expect_ok(c.call("scroll", {"direction": "down", "amount": 0.8}), "scroll down")
        assert not r.has("Airplane Mode"), "list didn't scroll (Airplane Mode still visible): %s" % r.labels()
        down = r.labels()
        r = expect_ok(c.call("scroll", {"direction": "up", "amount": 1.0}), "scroll up")
        assert r.has("Wi-Fi"), "scroll up didn't return to the top: %s" % r.labels()
        return "down -> %s" % down[1:4]

    def tap_row_and_back():
        r = expect_ok(c.call("tap_text", {"text": "General"}), "tap_text General")
        assert r.has("General settings"), "row didn't open: %s" % r.labels()
        r = expect_ok(c.call("tap_text", {"text": "< Settings"}), "tap back")
        assert r.has("Airplane Mode"), "back didn't return: %s" % r.labels()

    def swipe_home():
        assert st.get("size"), "needs the screenshot check first"
        w, h = st["size"]
        r = expect_ok(c.call("swipe", {"from_x": w // 2, "from_y": h - 6, "to_x": w // 2, "to_y": int(h * 0.45),
                                       "duration_ms": 300}), "swipe up from bottom")
        assert r.has("Notes") and r.has("Safari"), "bottom-edge swipe didn't go home: %s" % r.labels()

    def batch():
        r = expect_ok(c.call("batch", {"actions": [
            {"action": "press_key", "key": "cmd+space"},
            {"action": "type_text", "text": "safa"},
            {"action": "press_key", "key": "return"},
            {"action": "wait", "ms": 100},
        ]}), "batch")
        assert r.has("Safari is open"), "batch didn't open Safari via Spotlight: %s" % r.labels()
        return r.brief()

    def batch_failure():
        r = c.call("batch", {"actions": [
            {"action": "press_key", "key": "home"},
            {"action": "tap_text", "text": "No Such App 123"},
            {"action": "press_key", "key": "home"},
        ]})
        assert r.is_error, "batch with a missing label should fail"
        assert "Step 2" in r.text and "tap_text" in r.text, "error doesn't name the failing step: %s" % r.text[:300]
        assert "Fix:" in r.text, "error has no fix: %s" % r.text[:300]
        return r.text.splitlines()[0][:100]

    def tap_text_missing():
        r = c.call("tap_text", {"text": "Definitely Not On Screen"})
        assert r.is_error, "tap_text of a missing label should fail"
        assert "Definitely Not On Screen" in r.text, "error doesn't name the text: %s" % r.text[:300]
        assert "Why:" in r.text and "Fix:" in r.text, "error doesn't say why/fix: %s" % r.text[:300]
        assert r.images, "a textNotFound error should attach a screenshot"

    def unknown_tool():
        resp, _ = c.rpc("tools/call", {"name": "teleport", "arguments": {}})
        if "error" in resp:
            msg = json.dumps(resp["error"])
        else:
            assert resp["result"].get("isError"), "unknown tool should be an error"
            msg = json.dumps(resp["result"])
        assert "teleport" in msg, "error doesn't name the tool: %s" % msg[:200]

    def fault_status(component, words):
        def f():
            r = c.call("status")
            assert not r.is_error, r.text
            line = next((l for l in r.text.splitlines() if l.startswith("- %s:" % component)), "")
            assert line and "OK" not in line.split(" - ")[0], "%s should not be OK: %r" % (component, line)
            assert any(w.lower() in r.text.lower() for w in words), "status doesn't explain the %s problem: %s" % (component, r.text[:400])
            return line[:100]
        return f

    def fault_action(name, args, codes, fix_words):
        def f():
            r = c.call(name, args)
            assert r.is_error, "%s should fail in this scenario, got: %s" % (name, r.brief())
            assert "Why:" in r.text and "Fix:" in r.text, "error lacks why/fix: %s" % r.text[:300]
            m = re.search(r"\(error code: (\w+)\)", r.text)
            assert m and m.group(1) in codes, "error code %s, expected one of %s" % (m and m.group(1), codes)
            fix = r.text.split("Fix:", 1)[1].split("\n", 1)[0]
            assert any(w.lower() in fix.lower() for w in fix_words), "fix doesn't mention %s: %s" % (fix_words, fix)
            return "%s: %s" % (m.group(1), fix.strip()[:90])
        return f

    if a.scenario != "normal":
        print("OpenTap MCP fault scenario '%s' against %s" % (a.scenario, a.url))
        if not run.check("initialize", initialize):
            run.table()
            return 1
        c.notify("notifications/initialized")
        if a.scenario == "no-bluetooth":
            run.check("status shows Bluetooth", fault_status("Bluetooth", ["Bluetooth", "OpenTap"]))
            run.check("press_key fails helpfully", fault_action("press_key", {"key": "home"}, ["hidNotConnected"], ["Bluetooth"]))
        elif a.scenario == "at-off":
            run.check("calibrate fails helpfully", fault_action("calibrate", {}, ["assistiveTouchOff", "pointerNotFound", "calibrationFailed"],
                                                                ["AssistiveTouch"]))
            run.check("status shows AssistiveTouch", fault_status("AssistiveTouch", ["AssistiveTouch"]))
        elif a.scenario == "no-frames":
            run.check("status shows Screen", fault_status("Screen", ["screen", "iPhone"]))
            run.check("screenshot fails helpfully", fault_action("screenshot", {}, ["noFrame", "noDevice", "timeout"],
                                                                 ["USB", "unlock", "cable", "iPhone"]))
        return 0 if run.table() else 1

    print("OpenTap MCP end-to-end against %s%s" % (a.url, " (live phone)" if a.live else " (mock)"))
    if not run.check("initialize", initialize):
        run.table()
        return 1
    run.check("notifications/initialized", initialized)
    run.check("request without session", no_session)
    run.check("tools/list", tools_list)
    run.check("status", status)
    run.check("screenshot", screenshot)
    run.check("screenshot include_text=false", screenshot_no_text)
    run.check("invalid arguments", bad_args)
    run.check("unknown tool", unknown_tool)
    if not a.live:
        run.check("calibrate", calibrate)
        run.check("press_key home", home)
        run.check("tap_text Notes", tap_text_notes)
        run.check("tap + type_text submit", tap_field_and_type)
        run.check("long_press", long_press)
        run.check("open_app Settings", open_app_settings)
        run.check("scroll down/up", scroll)
        run.check("tap_text row + back", tap_row_and_back)
        run.check("swipe up from bottom", swipe_home)
        run.check("batch (spotlight)", batch)
        run.check("batch failure names step", batch_failure)
        run.check("tap_text missing text", tap_text_missing)
    return 0 if run.table() else 1


def call_main(argv):
    """`mcp_e2e.py call TOOL [JSON_ARGS] [--url URL] [--save-image PATH]`: one tool call, prints the text
    content (used by hardware-smoke.sh). Exit 0 = tool succeeded, 1 = tool returned an error, 2 = no server."""
    ap = argparse.ArgumentParser(prog="mcp_e2e.py call")
    ap.add_argument("tool")
    ap.add_argument("arguments", nargs="?", default="{}")
    ap.add_argument("--url", default="http://127.0.0.1:47900/mcp")
    ap.add_argument("--save-image", default=None)
    ap.add_argument("--timeout", type=float, default=180)
    a = ap.parse_args(argv)
    c = Client(a.url, a.timeout)
    try:
        c.initialize()
        c.notify("notifications/initialized")
        r = c.call(a.tool, json.loads(a.arguments))
    except (urllib.error.URLError, ConnectionError, OSError, MCPError) as e:
        print("Couldn't reach OpenTap at %s: %s" % (a.url, e))
        print("Fix: open OpenTap.app, finish onboarding, and check the MCP pill is green.")
        return 2
    if a.save_image and r.images:
        img = r.images[0]
        with open(a.save_image, "wb") as f:
            f.write(base64.b64decode(img["data"]))
    print(r.text)
    return 1 if r.is_error else 0


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "call":
        sys.exit(call_main(sys.argv[2:]))
    sys.exit(main())
