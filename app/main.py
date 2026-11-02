"""A tiny web app to put in the container. It uses only the Python standard library,
so the image has no extra packages (fewer things for Trivy to find).

  GET /        -> {"app": ..., "version": ..., "platform": ...}
  GET /health  -> {"status": "ok"}
"""

import json
import os
import platform
from http.server import BaseHTTPRequestHandler, HTTPServer

APP_NAME = os.environ.get("APP_NAME", "yefter-demo-app")
APP_VERSION = os.environ.get("APP_VERSION", "dev")  # set at build time from the git commit


def response_for(path):
    """Return (status code, body dict) for a request path. Kept separate so it is easy to test."""
    if path == "/health":
        return 200, {"status": "ok"}
    if path == "/":
        return 200, {"app": APP_NAME, "version": APP_VERSION, "platform": platform.machine()}
    return 404, {"error": "not found"}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802 (name required by BaseHTTPRequestHandler)
        status, body = response_for(self.path)
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format, *args):  # noqa: A002
        print(f"{self.address_string()} {format % args}", flush=True)


def main():
    port = int(os.environ.get("PORT", "8080"))
    print(f"{APP_NAME} {APP_VERSION} listening on port {port}", flush=True)
    HTTPServer(("0.0.0.0", port), Handler).serve_forever()  # noqa: S104 (inside a container)


if __name__ == "__main__":
    main()
