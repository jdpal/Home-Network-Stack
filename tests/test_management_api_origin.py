import ast
import http.client
import http.server
import io
import ipaddress
import json
import subprocess as stdlib_subprocess
import threading
import types
import unittest
from email.message import Message
from pathlib import Path
from urllib.parse import urlsplit


ROOT = Path(__file__).resolve().parents[1]
SCRIPT_CASES = (
    ("clean installer", ROOT / "install.sh", "STATUS_API_PY"),
    ("v3.8.1 upgrade", ROOT / "upgrades" / "upgrade-v3.8.1.sh", "V37_STATUS"),
)


def extract_heredoc(path, marker):
    source = path.read_text()
    opener = f"<<'{marker}'\n"
    start = source.index(opener) + len(opener)
    end = source.index(f"\n{marker}\n", start)
    return source[start:end]


class FakeSubprocess:
    DEVNULL = stdlib_subprocess.DEVNULL

    def __init__(self):
        self.calls = []

    def run(self, command, **kwargs):
        self.calls.append((command, kwargs))
        return types.SimpleNamespace(returncode=0)


def load_handler(path, marker):
    module = ast.parse(extract_heredoc(path, marker), filename=str(path))
    handler_node = next(
        node for node in module.body if isinstance(node, ast.ClassDef) and node.name == "Handler"
    )
    fake_subprocess = FakeSubprocess()
    namespace = {
        "DASHBOARD_PORT": 3000,
        "LAN_CIDR": "192.168.0.0/24",
        "PORT": 9108,
        "TOKEN": "test-token",
        "active": lambda _service: False,
        "discovery_summary": lambda: {"total": 0, "scanning": False},
        "effective_classification": lambda record: record,
        "http": types.SimpleNamespace(server=http.server),
        "ipaddress": ipaddress,
        "json": json,
        "subprocess": fake_subprocess,
        "update_device": lambda payload, reset=False: payload,
        "urlsplit": urlsplit,
    }
    compiled = compile(ast.Module(body=[handler_node], type_ignores=[]), str(path), "exec")
    exec(compiled, namespace)
    return namespace["Handler"], fake_subprocess


def headers(**values):
    result = Message()
    for name, value in values.items():
        result[name.replace("_", "-")] = value
    return result


def request(handler_class, request_headers, client="192.168.0.50", path="/manage/scan"):
    handler = object.__new__(handler_class)
    handler.client_address = (client, 54321)
    handler.headers = request_headers
    handler.path = path
    handler.rfile = io.BytesIO(b"{}")
    responses = []

    def capture(payload, status=200, public=False, writable=False):
        responses.append(
            {"payload": payload, "status": status, "public": public, "writable": writable}
        )

    handler._json = capture
    handler.do_POST()
    return responses


def response_headers(handler_class, request_headers, client="192.168.0.50"):
    handler = object.__new__(handler_class)
    handler.client_address = (client, 54321)
    handler.headers = request_headers
    handler.wfile = io.BytesIO()
    status = []
    emitted = []
    handler.send_response = lambda value: status.append(value)
    handler.send_header = lambda name, value: emitted.append((name, value))
    handler.end_headers = lambda: None
    handler._json({"error": "denied"}, 403, writable=True)
    return status, emitted


def preflight(handler_class, request_headers, client="192.168.0.50"):
    handler = object.__new__(handler_class)
    handler.client_address = (client, 54321)
    handler.headers = request_headers
    handler.path = "/manage/scan"
    status = []
    emitted = []
    handler.send_response = lambda value: status.append(value)
    handler.send_header = lambda name, value: emitted.append((name, value))
    handler.end_headers = lambda: None
    handler.do_OPTIONS()
    return status, emitted


def http_scan(handler_class, origin, content_type="application/json"):
    server = http.server.HTTPServer(("127.0.0.1", 0), handler_class)
    port = server.server_address[1]
    handler_class._origin_allowed.__globals__["PORT"] = port
    thread = threading.Thread(target=server.handle_request, daemon=True)
    thread.start()
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
    request_headers = {"Content-Type": content_type}
    if origin is not None:
        request_headers["Origin"] = origin
    try:
        connection.request("POST", "/manage/scan", body="{}", headers=request_headers)
        response = connection.getresponse()
        status = response.status
        emitted = dict(response.getheaders())
        payload = json.loads(response.read().decode("utf-8"))
    finally:
        connection.close()
        thread.join(timeout=3)
        server.server_close()
    return status, emitted, payload


class ManagementApiOriginTests(unittest.TestCase):
    def test_real_http_boundary_denies_cross_site_scan_and_keeps_trusted_scan_working(self):
        for script_name, path, marker in SCRIPT_CASES:
            handler_class, fake_subprocess = load_handler(path, marker)
            with self.subTest(script=script_name, origin="untrusted"):
                status, emitted, payload = http_scan(handler_class, "https://evil.example")
                self.assertEqual(status, 403)
                self.assertEqual(payload["error"], "management request origin is not allowed")
                self.assertNotIn("Access-Control-Allow-Origin", emitted)
                self.assertFalse(fake_subprocess.calls)

            with self.subTest(script=script_name, origin="trusted"):
                status, emitted, payload = http_scan(handler_class, "http://127.0.0.1:3000")
                self.assertEqual(status, 202)
                self.assertTrue(payload["started"])
                self.assertEqual(
                    emitted.get("Access-Control-Allow-Origin"), "http://127.0.0.1:3000"
                )
                self.assertEqual(len(fake_subprocess.calls), 1)

    def test_scan_allows_supported_clients_and_denies_untrusted_browser_origins(self):
        scenarios = (
            (
                "dashboard IP origin",
                headers(
                    Host="192.168.0.10:9108",
                    Origin="http://192.168.0.10:3000",
                    Content_Type="application/json",
                    Content_Length="2",
                ),
                202,
                True,
            ),
            (
                "Device Manager same origin",
                headers(
                    Host="192.168.0.10:9108",
                    Origin="http://192.168.0.10:9108",
                    Content_Type="application/json; charset=utf-8",
                    Content_Length="2",
                ),
                202,
                True,
            ),
            (
                "JSON command-line client without Origin",
                headers(
                    Host="192.168.0.10:9108",
                    Content_Type="application/json",
                    Content_Length="2",
                ),
                202,
                True,
            ),
            (
                "untrusted website",
                headers(
                    Host="192.168.0.10:9108",
                    Origin="https://evil.example",
                    Content_Type="application/json",
                    Content_Length="2",
                ),
                403,
                False,
            ),
            (
                "DNS-rebinding hostname",
                headers(
                    Host="evil.example:9108",
                    Origin="http://evil.example:3000",
                    Content_Type="application/json",
                    Content_Length="2",
                ),
                403,
                False,
            ),
            (
                "different LAN host",
                headers(
                    Host="192.168.0.10:9108",
                    Origin="http://192.168.0.20:3000",
                    Content_Type="application/json",
                    Content_Length="2",
                ),
                403,
                False,
            ),
            (
                "unsupported origin port",
                headers(
                    Host="192.168.0.10:9108",
                    Origin="http://192.168.0.10:8080",
                    Content_Type="application/json",
                    Content_Length="2",
                ),
                403,
                False,
            ),
            (
                "opaque origin",
                headers(
                    Host="192.168.0.10:9108",
                    Origin="null",
                    Content_Type="application/json",
                    Content_Length="2",
                ),
                403,
                False,
            ),
        )

        for script_name, path, marker in SCRIPT_CASES:
            handler_class, fake_subprocess = load_handler(path, marker)
            for scenario, request_headers, expected_status, should_start in scenarios:
                with self.subTest(script=script_name, scenario=scenario):
                    fake_subprocess.calls.clear()
                    responses = request(handler_class, request_headers)
                    self.assertEqual(responses[-1]["status"], expected_status)
                    self.assertEqual(bool(fake_subprocess.calls), should_start)

    def test_scan_rejects_non_json_content_before_starting_discovery(self):
        for script_name, path, marker in SCRIPT_CASES:
            handler_class, fake_subprocess = load_handler(path, marker)
            request_headers = headers(
                Host="192.168.0.10:9108",
                Origin="http://192.168.0.10:3000",
                Content_Type="text/plain",
                Content_Length="2",
            )
            with self.subTest(script=script_name):
                responses = request(handler_class, request_headers)
                self.assertEqual(responses[-1]["status"], 415)
                self.assertFalse(fake_subprocess.calls)

    def test_scan_preserves_loopback_and_tailscale_ip_access_but_denies_other_clients(self):
        scenarios = (
            ("loopback", "127.0.0.1", "127.0.0.1", 202, True),
            ("Tailscale", "100.64.1.50", "100.64.1.10", 202, True),
            ("outside trusted networks", "203.0.113.50", "192.168.0.10", 403, False),
        )
        for script_name, path, marker in SCRIPT_CASES:
            handler_class, fake_subprocess = load_handler(path, marker)
            for scenario, client, host, expected_status, should_start in scenarios:
                request_headers = headers(
                    Host=f"{host}:9108",
                    Origin=f"http://{host}:3000",
                    Content_Type="application/json",
                    Content_Length="2",
                )
                with self.subTest(script=script_name, scenario=scenario):
                    fake_subprocess.calls.clear()
                    responses = request(handler_class, request_headers, client=client)
                    self.assertEqual(responses[-1]["status"], expected_status)
                    self.assertEqual(bool(fake_subprocess.calls), should_start)

    def test_preflight_allows_only_a_trusted_origin(self):
        for script_name, path, marker in SCRIPT_CASES:
            handler_class, _ = load_handler(path, marker)
            with self.subTest(script=script_name, origin="trusted"):
                status, emitted = preflight(
                    handler_class,
                    headers(Host="192.168.0.10:9108", Origin="http://192.168.0.10:3000"),
                )
                self.assertEqual(status, [204])
                self.assertIn(
                    ("Access-Control-Allow-Origin", "http://192.168.0.10:3000"), emitted
                )
            with self.subTest(script=script_name, origin="untrusted"):
                status, emitted = preflight(
                    handler_class,
                    headers(Host="192.168.0.10:9108", Origin="https://evil.example"),
                )
                self.assertEqual(status, [403])
                self.assertNotIn("Access-Control-Allow-Origin", dict(emitted))

    def test_writable_error_response_never_reflects_an_untrusted_origin(self):
        for script_name, path, marker in SCRIPT_CASES:
            handler_class, _ = load_handler(path, marker)
            for origin, expected in (
                ("http://192.168.0.10:3000", "http://192.168.0.10:3000"),
                ("https://evil.example", None),
                (None, None),
            ):
                request_headers = headers(Host="192.168.0.10:9108")
                if origin is not None:
                    request_headers["Origin"] = origin
                with self.subTest(script=script_name, origin=origin):
                    status, emitted = response_headers(handler_class, request_headers)
                    self.assertEqual(status, [403])
                    self.assertEqual(dict(emitted).get("Access-Control-Allow-Origin"), expected)


if __name__ == "__main__":
    unittest.main()
