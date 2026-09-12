#!/usr/bin/env python3
"""
Roblox MCP Bridge — no third-party MCP lib required.
- HTTP :7821  <- executor POSTs remote events
- MCP stdio  -> Claude reads tools via JSON-RPC 2.0
"""

import json, sys, threading, os
from datetime import datetime
from collections import deque
from http.server import HTTPServer, BaseHTTPRequestHandler

SCRIPT_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "script.lua")  # ponytail: hardcoded in roblox_bridge.py copy — keep in sync

remote_log: deque = deque(maxlen=500)
object_tree: dict = {}
bridge_active = False
last_seen = None

# ── HTTP ingest ───────────────────────────────────────────────────────────────

class IngestHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        global bridge_active, object_tree, last_seen
        n = int(self.headers.get("Content-Length", 0))
        try:
            d = json.loads(self.rfile.read(n))
            k = d.get("kind")
            if k == "remote":
                remote_log.append({"ts": datetime.now().isoformat(), **d})
            elif k == "tree":
                object_tree = d.get("tree", {})
            bridge_active = True
            last_seen = datetime.now().isoformat()
        except Exception:
            pass
        self.send_response(200); self.end_headers(); self.wfile.write(b"ok")

    def do_GET(self):
        if self.path == "/script":
            try:
                with open(SCRIPT_PATH, "rb") as f:
                    data = f.read()
                self.send_response(200)
                self.send_header("Content-Type", "text/plain")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            except FileNotFoundError:
                self.send_response(404); self.end_headers(); self.wfile.write(b"script.lua not found")
        else:
            self.send_response(404); self.end_headers()

    def log_message(self, *_): pass

# ── MCP protocol (JSON-RPC 2.0 over stdio) ───────────────────────────────────

TOOLS = [
    {
        "name": "bridge_status",
        "description": "Is the Roblox MCP bridge active?",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "get_remotes",
        "description": "Recent remote events captured by SimpleSpy.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "limit": {"type": "integer", "default": 50},
                "filter": {"type": "string", "description": "Substring match on name/path"},
            },
        },
    },
    {
        "name": "get_object_tree",
        "description": "Roblox game object tree from DarkDex.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "clear_remotes",
        "description": "Wipe the remote log.",
        "inputSchema": {"type": "object", "properties": {}},
    },
]

def call_tool(name, args):
    global remote_log
    if name == "bridge_status":
        return json.dumps({"active": bridge_active, "last_seen": last_seen,
                           "remote_count": len(remote_log)})
    if name == "get_remotes":
        limit = int(args.get("limit", 50))
        filt  = args.get("filter", "").lower()
        out   = list(remote_log)[-limit:]
        if filt:
            out = [e for e in out if filt in e.get("name","").lower()
                                  or filt in e.get("path","").lower()]
        return json.dumps(out, indent=2)
    if name == "get_object_tree":
        return json.dumps(object_tree, indent=2)
    if name == "clear_remotes":
        remote_log.clear()
        return "cleared"
    return f"unknown tool: {name}"

def send(obj):
    line = json.dumps(obj) + "\n"
    sys.stdout.write(line)
    sys.stdout.flush()

def handle(req):
    rid    = req.get("id")
    method = req.get("method", "")
    params = req.get("params", {})

    if method == "initialize":
        send({"jsonrpc":"2.0","id":rid,"result":{
            "protocolVersion":"2024-11-05",
            "capabilities":{"tools":{}},
            "serverInfo":{"name":"roblox-bridge","version":"1.0.0"},
        }})
    elif method == "notifications/initialized":
        pass  # no response needed
    elif method == "tools/list":
        send({"jsonrpc":"2.0","id":rid,"result":{"tools":TOOLS}})
    elif method == "tools/call":
        name   = params.get("name","")
        args   = params.get("arguments", {})
        result = call_tool(name, args)
        send({"jsonrpc":"2.0","id":rid,"result":{
            "content":[{"type":"text","text":result}]
        }})
    elif rid is not None:
        send({"jsonrpc":"2.0","id":rid,"error":{"code":-32601,"message":"Method not found"}})

def mcp_loop():
    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        try:
            handle(json.loads(raw))
        except Exception as e:
            sys.stderr.write(f"[bridge] parse error: {e}\n")

if __name__ == "__main__":
    try:
        srv = HTTPServer(("127.0.0.1", 7821), IngestHandler)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        sys.stderr.write("bridge: http://127.0.0.1:7821\n")
    except OSError as e:
        sys.stderr.write(f"[bridge] HTTP bind failed ({e}) — another instance may be running\n")
    sys.stderr.flush()
    mcp_loop()
