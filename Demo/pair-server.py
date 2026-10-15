#!/usr/bin/env python3
"""The demo host's pairing page: a fresh `bleat pair` link behind a password.

App Review cannot run `bleat pair` at a terminal, so this runs it for them.
Every `bleat pair` sweeps other pending enrollment keys, so only one runs at a
time: a visitor while one is pending gets that same link, and "New code"
cancels it and starts another.

Runs as `pairpage`, which `demo` cannot signal or inspect, and runs
`bleat pair` as demo through one sudo rule. DEMO_PASSWORD gates it (HTTP
Basic, any user name); DEMO_ENDPOINT is the address the phone dials.
The reasoning: docs/demo-host.md.
"""
import base64
import hmac
import html
import os
import queue
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PASSWORD = os.environ["DEMO_PASSWORD"].encode()
ENDPOINT = os.environ["DEMO_ENDPOINT"]
WINDOW = 600     # seconds a pairing code lives
STARTUP = 30     # seconds `bleat pair` gets to print its link


class Pairing:
    """The one `bleat pair` that may be pending."""

    def __init__(self):
        self.lock = threading.Lock()
        self.process = None
        self.link = None
        self.qr = ""
        self.subtitle = ""
        self.started = 0.0

    def current(self, fresh=False):
        with self.lock:
            if fresh:
                self._stop()
            if self.process is None or self.process.poll() is not None:
                self._start()
            return self.link, self.qr, self.subtitle, self.started + WINDOW - time.time()

    def _stop(self):
        # SIGTERM reaches `bleat pair` through sudo, and it removes its key.
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
        self.process = None

    def _start(self):
        process = subprocess.Popen(
            ["sudo", "-n", "-H", "-u", "demo", "/usr/local/bin/bleat", "pair",
             "--endpoint", ENDPOINT, "--timeout", str(WINDOW)],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )
        # Read on a thread, so a `bleat pair` that never prints a link cannot
        # hold the lock, and with it every other request, forever.
        lines = queue.Queue()
        threading.Thread(target=self._read, args=(process, lines), daemon=True).start()
        link, subtitle, seen = None, "", []
        deadline = time.time() + STARTUP
        while link is None:
            try:
                line = lines.get(timeout=max(0.1, deadline - time.time()))
            except queue.Empty:
                break
            if line is None:
                break
            seen.append(line)
            if line.startswith("host key"):
                subtitle = line
            elif line.startswith("bleat://"):
                link = line
        if link is None:
            process.kill()
            raise RuntimeError("bleat pair printed no link: " + " | ".join(seen[-5:]))
        self.process, self.link, self.subtitle = process, link, subtitle
        self.qr = qr_svg(link)
        self.started = time.time()

    @staticmethod
    def _read(process, lines):
        # Not a terminal, so `bleat pair` prints the link and flushes it. The
        # rest is drained so the pipe never fills, and logged.
        for raw in process.stdout:
            line = raw.strip()
            lines.put(line)
            if line and not line.startswith("bleat://"):
                print("pair:", line, flush=True)
        lines.put(None)


def qr_svg(text):
    return subprocess.run(
        ["qrencode", "-t", "SVG", "-m", "2", "-s", "6", "-o", "-", text],
        capture_output=True, text=True, check=True,
    ).stdout


pairing = Pairing()

PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="{refresh};url=/">
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
<p class="muted">This code works once and expires in about {minutes} minutes.
If it does not work, <a href="/new">get a new code</a>. The demo host is reset
every day, which removes every pairing.</p>
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
        path = self.path.split("?")[0]
        if path == "/healthz":
            return self._send(200, "ok", "text/plain")
        if path not in ("/", "/new"):
            return self._send(404, "Not found", "text/plain")
        if not self._authorized():
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="Bleat demo"')
            self.end_headers()
            return
        try:
            link, qr, subtitle, left = pairing.current(fresh=(path == "/new"))
        except Exception as error:  # surfaced, not swallowed
            print("pair error:", error, flush=True)
            return self._send(503, "Pairing is unavailable right now. Try again in a minute.", "text/plain")
        if path == "/new":
            # Back to /, so a reload does not cancel the code just made.
            self.send_response(303)
            self.send_header("Location", "/")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            return
        body = PAGE.format(
            link_attr=html.escape(link, quote=True),
            qr=qr,
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
