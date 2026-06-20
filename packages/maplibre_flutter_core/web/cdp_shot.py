#!/usr/bin/env python3
"""Capture a screenshot from an already-running headless Chromium (Edge/Chrome)
launched with --remote-debugging-port, after a real-time wait. Used to verify the
WASM map renders (the virtual-time --screenshot fires too early for a map that
loads tiles over the network).

    cdp_shot.py <port> <wait_seconds> <out.png>
"""
import base64
import json
import sys
import time
import urllib.request

from websocket import create_connection

port = int(sys.argv[1])
wait = float(sys.argv[2])
out = sys.argv[3]

host = sys.argv[4] if len(sys.argv) > 4 else "127.0.0.1"
targets = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list"))
pages = [t for t in targets if t.get("type") == "page" and t.get("webSocketDebuggerUrl")]
page = next((t for t in pages if host in t.get("url", "")), pages[0])
print("target url:", page.get("url"))
ws = create_connection(page["webSocketDebuggerUrl"], max_size=None)

_id = 0
def cmd(method, params=None):
    global _id
    _id += 1
    ws.send(json.dumps({"id": _id, "method": method, "params": params or {}}))
    while True:
        msg = json.loads(ws.recv())
        if msg.get("id") == _id:
            return msg

cmd("Page.enable")
print(f"waiting {wait}s for the map to load...")
time.sleep(wait)
res = cmd("Page.captureScreenshot", {"format": "png", "captureBeyondViewport": False})
data = base64.b64decode(res["result"]["data"])
with open(out, "wb") as f:
    f.write(data)
print(f"SHOT_OK bytes={len(data)} -> {out}")
ws.close()
