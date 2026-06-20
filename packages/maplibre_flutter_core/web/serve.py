#!/usr/bin/env python3
"""Static file server that sends the COOP/COEP headers required for SharedArrayBuffer
(Emscripten pthreads). Use it to run the WASM probe / the example's built web output,
which the default Flutter / simple HTTP servers don't set.

    python serve.py [directory] [port]      # default: . on :8099
"""
import http.server
import os
import socketserver
import sys

directory = sys.argv[1] if len(sys.argv) > 1 else "."
port = int(sys.argv[2]) if len(sys.argv) > 2 else 8099


class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        # credentialless (not require-corp) so cross-origin tile/style fetches work
        # without the servers needing to send CORP headers, while still enabling
        # SharedArrayBuffer (Emscripten pthreads).
        self.send_header("Cross-Origin-Embedder-Policy", "credentialless")
        self.send_header("Cross-Origin-Resource-Policy", "cross-origin")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def translate_path(self, path):
        # Serve relative to the requested directory.
        rel = super().translate_path(path)
        return os.path.join(directory, os.path.relpath(rel, os.getcwd()))


socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", port), Handler) as httpd:
    print(f"Serving {os.path.abspath(directory)} on http://127.0.0.1:{port} (COOP/COEP on)")
    httpd.serve_forever()
