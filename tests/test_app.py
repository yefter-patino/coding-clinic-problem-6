import json
import threading
import urllib.request
from http.server import HTTPServer

from app.main import Handler, response_for


def test_health():
    assert response_for("/health") == (200, {"status": "ok"})


def test_root_reports_app_and_platform():
    status, body = response_for("/")
    assert status == 200
    assert {"app", "version", "platform"} <= body.keys()


def test_unknown_path_is_404():
    assert response_for("/nope")[0] == 404


def test_real_http_request():
    server = HTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        url = f"http://127.0.0.1:{server.server_port}/health"
        with urllib.request.urlopen(url, timeout=5) as reply:  # noqa: S310 (local test server)
            assert reply.status == 200
            assert json.loads(reply.read()) == {"status": "ok"}
    finally:
        server.shutdown()
