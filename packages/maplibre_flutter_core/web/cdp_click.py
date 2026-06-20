#!/usr/bin/env python3
"""Click a viewport coordinate in a running headless Chromium, wait, screenshot.
    cdp_click.py <port> <x> <y> <wait_s> <out.png> [host]
"""
import base64
import json
import sys
import time
import urllib.request

from websocket import create_connection

port = int(sys.argv[1])
x = int(sys.argv[2])
y = int(sys.argv[3])
wait = float(sys.argv[4])
out = sys.argv[5]
host = sys.argv[6] if len(sys.argv) > 6 else "127.0.0.1"

targets = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list"))
pages = [t for t in targets if t.get("type") == "page" and t.get("webSocketDebuggerUrl")]
page = next((t for t in pages if host in t.get("url", "")), pages[0])
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
cmd("Input.dispatchMouseEvent", {"type": "mousePressed", "x": x, "y": y, "button": "left", "buttons": 1, "clickCount": 1})
cmd("Input.dispatchMouseEvent", {"type": "mouseReleased", "x": x, "y": y, "button": "left", "buttons": 0, "clickCount": 1})
print(f"clicked ({x},{y}); waiting {wait}s...")
time.sleep(wait)
r = cmd("Page.captureScreenshot", {"format": "png"})
with open(out, "wb") as f:
    f.write(base64.b64decode(r["result"]["data"]))
print(f"SHOT_OK -> {out}")
ws.close()
