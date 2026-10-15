#!/usr/bin/env python3
"""The demo host's pairing page: a fresh `bleat pair` link behind a password.

App Review cannot run `bleat pair` at a terminal, so this runs it for them.
Every `bleat pair` sweeps other pending enrollment keys, so only one runs at a
time: a visitor while one is pending gets that same link, and a new one starts
once it is redeemed or expires.

Runs as `demo`. DEMO_PASSWORD gates it (HTTP Basic, any user name);
DEMO_ENDPOINT is the address the phone dials.
"""
import base64
import hmac
import html
import os
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PASSWORD = os.environ["DEMO_PASSWORD"].encode()
ENDPOINT = os.environ["DEMO_ENDPOINT"]
WINDOW = 600  # seconds a pairing code lives


class Pairing:
    """The one `bleat pair` that may be pending."""

    def __init__(self):
        self.lock = threading.Lock()
        self.process = None
        self.link = None
        self.subtitle = ""
        self.started = 0.0

    def current(self):
        with self.lock:
            if self.process is None or self.process.poll() is not None:
                self._start()
            return self.link, self.subtitle, self.started + WINDOW - time.time()

    def _start(self):
        self.process = subprocess.Popen(
            ["bleat", "pair", "--endpoint", ENDPOINT, "--timeout", str(WINDOW)],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )
        self.started = time.time()
        self.link, self.subtitle = None, ""
        lines = []
        # Not a terminal, so `bleat pair` prints the link and flushes it.
        for line in self.process.stdout:
            line = line.strip()
            lines.append(line)
            if line.startswith("host key"):
                self.subtitle = line
            if line.startswith("bleat://"):
                self.link = line
                break
        if self.link is None:
            raise RuntimeError("bleat pair printed no link: " + " | ".join(lines[-5:]))
        # Keep reading so the pipe never fills; log the outcome.
        threading.Thread(target=self._drain, args=(self.process,), daemon=True).start()

    @staticmethod
    def _drain(process):
        for line in process.stdout:
            if line.strip():
                print("pair:", line.strip(), flush=True)


pairing = Pairing()


def qr_svg(text):
    return subprocess.run(
        ["qrencode", "-t", "SVG", "-m", "2", "-s", "6", "-o", "-", text],
        capture_output=True, text=True, check=True,
    ).stdout


PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="{refresh}">
<title>Pair with the Bleat demo host</title>
<style>
  :root {{ color-scheme: light dark; font-family: -apple-system, system-ui, sans-serif; }}
  body {{ max-width: 34rem; margin: 2rem auto; padding: 0 1rem; line-height: 1.5; }}
  a.button {{ display: block; text-align: center; padding: 1rem; border-radius: 0.8rem;
             background: #e8735a; color: white; font-weight: 600; text-decoration: none; font-size: 1.1rem; }}
  .qr svg {{ width: 100%; max-width: 18rem; height: auto; display: block; margin: 1.5rem auto; background: white; }}
  .muted {{ opacity: 0.7; font-size: 0.9rem; overflow-wrap: anywhere; }}
</style></head><body>
<h1>Pair with the Bleat demo host</h1>
<p>On the iPhone or iPad with Bleat installed, tap:</p>
<p><a class="button" href="{link_attr}">Open in Bleat</a></p>
<p>Or, from another screen, open Bleat, tap <strong>Pair a host</strong> and scan:</p>
<div class="qr">{qr}</div>
<p class="muted">This code works once and expires in about {minutes} minutes; reload this page
for a new one. The demo host is reset every day, which removes every pairing.</p>
<p class="muted">{subtitle}</p>
</body></html>
"""


class Handler(BaseHTTPRequestHandler):
    def _authorized(self):
        header = self.headers.get("Authorization", "")
        if not header.startswith("Basic "):
            return False
        try:
            _, _, given = base64.b64decode(header[6:]).partition(b":")
        except Exception:
            return False
        return hmac.compare_digest(given, PASSWORD)

    def do_GET(self):
        if self.path == "/healthz":
            return self._send(200, "ok", "text/plain")
        if not self._authorized():
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="Bleat demo"')
            self.end_headers()
            return
        try:
            link, subtitle, left = pairing.current()
        except Exception as error:  # surfaced, not swallowed
            print("pair error:", error, flush=True)
            return self._send(503, "Pairing is unavailable right now. Try again in a minute.", "text/plain")
        body = PAGE.format(
            link_attr=html.escape(link, quote=True),
            qr=qr_svg(link),
            minutes=max(1, int(left // 60)),
            subtitle=html.escape(subtitle),
            refresh=max(30, int(left) + 5),
        )
        self._send(200, body, "text/html; charset=utf-8")

    def _send(self, code, body, kind):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        # The path only: a query string or header could carry the password.
        print("http:", self.command, self.path.split("?")[0], flush=True)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
