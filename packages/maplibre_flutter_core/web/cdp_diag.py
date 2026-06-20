#!/usr/bin/env python3
"""Diagnose the WASM map: capture the page console (console.* + Log + exceptions)
while driving several drag-pans, then screenshot. Reveals crashes/aborts vs a hang.

    cdp_diag.py <port> <out.png> [host]
"""
import base64
import json
import sys
import time
import urllib.request

from websocket import create_connection

port = int(sys.argv[1])
out = sys.argv[2]
host = sys.argv[3] if len(sys.argv) > 3 else "127.0.0.1"

targets = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list"))
pages = [t for t in targets if t.get("type") == "page" and t.get("webSocketDebuggerUrl")]
page = next((t for t in pages if host in t.get("url", "")), pages[0])
print("target:", page.get("url"))
ws = create_connection(page["webSocketDebuggerUrl"], max_size=None)

events = []
_id = 0
def send(method, params=None):
    global _id
    _id += 1
    ws.send(json.dumps({"id": _id, "method": method, "params": params or {}}))
    return _id
def wait_resp(rid):
    ws.settimeout(8)
    while True:
        msg = json.loads(ws.recv())
        if msg.get("id") == rid:
            return msg
        if "method" in msg:
            events.append(msg)
def pump(seconds):
    ws.settimeout(0.4)
    end = time.time() + seconds
    while time.time() < end:
        try:
            msg = json.loads(ws.recv())
        except Exception:
            continue
        if "method" in msg:
            events.append(msg)

for m in ("Log.enable", "Runtime.enable", "Page.enable"):
    wait_resp(send(m))

print("loading + collecting console (50s)...")
pump(50)

def mouse(t, x, y, buttons=1):
    wait_resp(send("Input.dispatchMouseEvent",
                   {"type": t, "x": x, "y": y, "button": "left", "buttons": buttons, "clickCount": 1}))

cx, cy = 350, 430
for rep in range(4):
    mouse("mousePressed", cx, cy)
    for k in range(1, 9):
        mouse("mouseMoved", cx - 18 * k, cy)
        time.sleep(0.02)
    mouse("mouseReleased", cx - 144, cy, buttons=0)
    pump(2)
print("drags done")

r = wait_resp(send("Page.captureScreenshot", {"format": "png"}))
with open(out, "wb") as f:
    f.write(base64.b64decode(r["result"]["data"]))
pump(2)

print("=== CONSOLE / LOG / EXCEPTIONS ===")
seen = 0
for e in events:
    m = e["method"]
    if m == "Runtime.consoleAPICalled":
        txt = " ".join(str(a.get("value", a.get("description", ""))) for a in e["params"].get("args", []))
        print(f"[{e['params']['type']}] {txt[:280]}")
        seen += 1
    elif m == "Log.entryAdded":
        en = e["params"]["entry"]
        print(f"[log:{en.get('level')}] {en.get('text','')[:280]}")
        seen += 1
    elif m == "Runtime.exceptionThrown":
        d = e["params"]["exceptionDetails"]
        print(f"[EXCEPTION] {d.get('text','')} {d.get('exception',{}).get('description','')[:280]}")
        seen += 1
print(f"=== {seen} console/log lines ===")
ws.close()
