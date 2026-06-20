#!/usr/bin/env python3
"""Verify the WASM map is interactive: screenshot, simulate a drag-pan, screenshot
again. Drive an already-running headless Chromium (--remote-debugging-port).

    cdp_interact.py <port> <wait_s> <before.png> <after.png> [host]
"""
import base64
import json
import sys
import time
import urllib.request

from websocket import create_connection

port = int(sys.argv[1])
wait = float(sys.argv[2])
before = sys.argv[3]
after = sys.argv[4]
host = sys.argv[5] if len(sys.argv) > 5 else "127.0.0.1"

targets = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list"))
pages = [t for t in targets if t.get("type") == "page" and t.get("webSocketDebuggerUrl")]
page = next((t for t in pages if host in t.get("url", "")), pages[0])
print("target:", page.get("url"))
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

def shot(path):
    r = cmd("Page.captureScreenshot", {"format": "png"})
    with open(path, "wb") as f:
        f.write(base64.b64decode(r["result"]["data"]))

cmd("Page.enable")
print(f"waiting {wait}s for the map to load...")
time.sleep(wait)
shot(before)
print("BEFORE captured")

# Drag-pan from the middle of the map leftwards.
cx, cy = 350, 420
cmd("Input.dispatchMouseEvent", {"type": "mousePressed", "x": cx, "y": cy, "button": "left", "buttons": 1, "clickCount": 1})
for i in range(1, 11):
    cmd("Input.dispatchMouseEvent", {"type": "mouseMoved", "x": cx - 22 * i, "y": cy, "button": "left", "buttons": 1})
    time.sleep(0.03)
cmd("Input.dispatchMouseEvent", {"type": "mouseReleased", "x": cx - 220, "y": cy, "button": "left", "buttons": 0})
print("drag dispatched")
time.sleep(2.5)
shot(after)
print("AFTER captured")
ws.close()
