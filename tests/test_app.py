import http.client
import io
import json
import logging
import os
import sys
import threading
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import app  # noqa: E402

TOKEN = "s3cret-test-token"


class FakeSsm:
    def __init__(self, value="ok", fail=False):
        self.value, self.fail = value, fail

    def get_parameter(self, Name):
        if self.fail:
            raise RuntimeError("ssm down")
        return {"Parameter": {"Value": self.value}}

    def put_parameter(self, Name, Value, Type, Overwrite):
        if self.fail:
            raise RuntimeError("ssm down")
        self.value = Value


class ServerCase(unittest.TestCase):
    token = TOKEN
    store = None

    def setUp(self):
        self.store = self.store or app.MemoryChaosStore()
        self.state = app.State(app.Chaos(self.store, cache_seconds=0), self.token)
        self.server = app.make_server(self.state, "127.0.0.1", 0)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True).start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()

    def call(self, method, path, body=None, headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.request(method, path, body=body, headers=headers or {})
        resp = conn.getresponse()
        raw = resp.read()
        conn.close()
        return resp.status, (json.loads(raw) if raw else None), resp

    def auth(self, token=TOKEN):
        return {"Authorization": f"Bearer {token}"}


class HealthTests(ServerCase):
    def test_healthy_by_default(self):
        for path in ("/healthz", "/readyz", "/livez"):
            status, body, _ = self.call("GET", path)
            self.assertEqual((status, body["status"]), (200, "ok"), path)

    def test_index_reports_version_and_status(self):
        status, body, _ = self.call("GET", "/")
        self.assertEqual(status, 200)
        self.assertEqual(body["service"], "hello-devops")
        self.assertEqual(body["status"], "ok")

    def test_broken_fails_health_and_readiness_but_not_liveness(self):
        self.store.write(True)
        self.assertEqual(self.call("GET", "/healthz")[0], 503)
        self.assertEqual(self.call("GET", "/readyz")[0], 503)
        self.assertEqual(self.call("GET", "/livez")[0], 200)
        self.assertEqual(self.call("GET", "/")[1]["status"], "degraded")

    def test_draining_fails_readiness_only(self):
        self.state.draining.set()
        self.assertEqual(self.call("GET", "/readyz")[0], 503)
        self.assertEqual(self.call("GET", "/healthz")[0], 200)
        self.assertEqual(self.call("GET", "/readyz")[1]["status"], "draining")

    def test_unknown_path_404_and_wrong_method_405(self):
        self.assertEqual(self.call("GET", "/health")[0], 404)
        self.assertEqual(self.call("POST", "/healthz", body="{}")[0], 405)
        self.assertEqual(self.call("DELETE", "/admin/chaos")[0], 405)
        self.assertEqual(self.call("DELETE", "/nope")[0], 404)

    def test_security_headers_and_request_id_on_every_response(self):
        for path in ("/", "/nope", "/healthz"):
            _, _, resp = self.call("GET", path)
            self.assertEqual(resp.getheader("X-Content-Type-Options"), "nosniff")
            self.assertEqual(resp.getheader("X-Frame-Options"), "DENY")
            self.assertTrue(resp.getheader("X-Request-Id"))
            self.assertNotIn("Python", resp.getheader("Server"))


class AdminTests(ServerCase):
    def post(self, payload, headers=None):
        return self.call("POST", "/admin/chaos", body=payload,
                         headers={"Content-Type": "application/json", **(headers or {})})

    def test_admin_requires_token(self):
        self.assertEqual(self.post('{"state":"break"}')[0], 401)
        self.assertEqual(self.post('{"state":"break"}', self.auth("wrong"))[0], 401)
        self.assertEqual(self.call("GET", "/admin/chaos")[0], 401)
        self.assertFalse(self.store.read(), "unauthenticated call must not change state")

    def test_break_then_recover_roundtrip(self):
        self.assertEqual(self.post('{"state":"break"}', self.auth())[0], 200)
        self.assertEqual(self.call("GET", "/healthz")[0], 503)
        self.assertEqual(self.call("GET", "/admin/chaos", headers=self.auth())[1]["state"], "broken")
        self.assertEqual(self.post('{"state":"recover"}', self.auth())[0], 200)
        self.assertEqual(self.call("GET", "/healthz")[0], 200)

    def test_rejects_bad_input(self):
        for payload in ('{"state":"explode"}', "not json", "[]", "{}", '{"state":1}'):
            self.assertEqual(self.post(payload, self.auth())[0], 400, payload)
        self.assertFalse(self.store.read())

    def test_rejects_oversized_body(self):
        big = '{"state":"break","pad":"' + "x" * 5000 + '"}'
        self.assertEqual(self.post(big, self.auth())[0], 413)
        self.assertFalse(self.store.read())

    def test_store_failure_returns_502(self):
        self.state.chaos.store = app.SsmChaosStore("/p", client=FakeSsm(fail=True))
        self.assertEqual(self.post('{"state":"break"}', self.auth())[0], 502)


class AdminDisabledTests(ServerCase):
    token = ""

    def test_no_token_configured_disables_admin(self):
        self.assertEqual(self.call("POST", "/admin/chaos", body='{"state":"break"}',
                                   headers=self.auth(""))[0], 503)
        self.assertEqual(self.call("POST", "/admin/chaos", body='{"state":"break"}',
                                   headers={"Authorization": "Bearer "})[0], 503)


class ChaosStoreTests(unittest.TestCase):
    def test_ssm_store_parses_values(self):
        ssm = FakeSsm("broken")
        store = app.SsmChaosStore("/p", client=ssm)
        self.assertTrue(store.read())
        store.write(False)
        self.assertEqual(ssm.value, "ok")
        self.assertFalse(store.read())

    def test_cache_limits_store_reads(self):
        calls = []

        class Store(app.MemoryChaosStore):
            def read(self):
                calls.append(1)
                return super().read()

        now = [0.0]
        chaos = app.Chaos(Store(), cache_seconds=3, clock=lambda: now[0])
        chaos.is_broken(); chaos.is_broken(); chaos.is_broken()
        self.assertEqual(len(calls), 1)
        now[0] = 3.5
        chaos.is_broken()
        self.assertEqual(len(calls), 2)

    def test_store_outage_keeps_last_known_value(self):
        ssm = FakeSsm("broken")
        now = [0.0]
        chaos = app.Chaos(app.SsmChaosStore("/p", client=ssm), cache_seconds=1, clock=lambda: now[0])
        self.assertTrue(chaos.is_broken())
        ssm.fail = True
        now[0] = 5
        self.assertTrue(chaos.is_broken())
        self.assertEqual(chaos.last_error, "RuntimeError")


class LoggingTests(ServerCase):
    def test_access_log_is_single_json_line_with_fields(self):
        buf = io.StringIO()
        handler = logging.StreamHandler(buf)
        handler.setFormatter(app.JsonFormatter())
        app.log.handlers[:] = [handler]
        app.log.setLevel(logging.INFO)
        self.call("GET", "/healthz")
        lines = [json.loads(line) for line in buf.getvalue().splitlines()]
        self.assertEqual(len(lines), 1)
        self.assertEqual((lines[0]["method"], lines[0]["path"], lines[0]["status"]),
                         ("GET", "/healthz", 200))
        self.assertIn("request_id", lines[0])

    def test_token_never_logged(self):
        buf = io.StringIO()
        handler = logging.StreamHandler(buf)
        handler.setFormatter(app.JsonFormatter())
        app.log.handlers[:] = [handler]
        self.call("GET", "/admin/chaos", headers=self.auth("wrong-" + TOKEN))
        self.assertNotIn(TOKEN, buf.getvalue())


if __name__ == "__main__":
    unittest.main()
