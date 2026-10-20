"""hello-devops: a small HTTP service built to demonstrate production habits.

Endpoints
  GET  /              service info (JSON)
  GET  /livez         process liveness - 200 as long as the process answers
  GET  /healthz       service health   - 503 while chaos mode is "broken"
  GET  /readyz        readiness        - 503 while broken OR draining on SIGTERM
  GET  /admin/chaos   current chaos state       (Bearer ADMIN_TOKEN)
  POST /admin/chaos   {"state":"break|recover"}  (Bearer ADMIN_TOKEN)

Chaos state is shared by every task through one SSM parameter
(CHAOS_SSM_PARAM) so "break" affects the whole service, and survives task
replacement. Without CHAOS_SSM_PARAM it is kept in process memory (local dev).
"""
import hmac
import json
import logging
import os
import signal
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = os.getenv("APP_VERSION", "dev")
MAX_BODY_BYTES = 1024
CHAOS_CACHE_SECONDS = 3.0

SECURITY_HEADERS = {
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Cache-Control": "no-store",
    "Content-Security-Policy": "default-src 'none'; frame-ancestors 'none'",
    "Referrer-Policy": "no-referrer",
}

log = logging.getLogger("hello-devops")


class JsonFormatter(logging.Formatter):
    """One JSON object per line so CloudWatch Logs Insights can query fields."""

    def format(self, record):
        entry = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(record.created)) + "Z",
            "level": record.levelname,
            "msg": record.getMessage(),
        }
        entry.update(getattr(record, "fields", {}))
        if record.exc_info:
            entry["exc"] = self.formatException(record.exc_info)
        return json.dumps(entry, separators=(",", ":"))


def setup_logging():
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    log.handlers[:] = [handler]
    log.setLevel(os.getenv("LOG_LEVEL", "INFO").upper())
    log.propagate = False


# --------------------------------------------------------------------------
# Chaos state
# --------------------------------------------------------------------------
class MemoryChaosStore:
    def __init__(self):
        self._broken = False

    def read(self):
        return self._broken

    def write(self, broken):
        self._broken = broken


class SsmChaosStore:
    """Chaos flag in one SSM String parameter: 'broken' or 'ok'."""

    def __init__(self, name, client=None):
        if client is None:
            import boto3  # imported lazily so local dev/tests need no AWS libs

            client = boto3.client("ssm")
        self.name = name
        self.client = client

    def read(self):
        value = self.client.get_parameter(Name=self.name)["Parameter"]["Value"]
        return value.strip().lower() == "broken"

    def write(self, broken):
        self.client.put_parameter(
            Name=self.name, Value="broken" if broken else "ok", Type="String", Overwrite=True
        )


class Chaos:
    """Cached view of the shared flag. If the store cannot be read we report
    the last known value but flag the read as failed (fail static, not open:
    a store outage must not by itself take the service down)."""

    def __init__(self, store, cache_seconds=CHAOS_CACHE_SECONDS, clock=time.monotonic):
        self.store = store
        self.cache_seconds = cache_seconds
        self.clock = clock
        self._lock = threading.Lock()
        self._value = False
        self._read_at = None
        self.last_error = None

    def is_broken(self):
        with self._lock:
            now = self.clock()
            if self._read_at is None or now - self._read_at >= self.cache_seconds:
                try:
                    self._value = self.store.read()
                    self.last_error = None
                except Exception as exc:  # noqa: BLE001 - any store failure is non-fatal
                    self.last_error = type(exc).__name__
                    log.error("chaos store read failed", extra={"fields": {"error": self.last_error}})
                self._read_at = now
            return self._value

    def set_broken(self, broken):
        self.store.write(broken)
        with self._lock:
            self._value = broken
            self._read_at = self.clock()
            self.last_error = None


class State:
    def __init__(self, chaos, admin_token):
        self.chaos = chaos
        self.admin_token = admin_token or ""
        self.draining = threading.Event()
        self.started = time.time()


# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "hello-devops"
    sys_version = ""
    state = None  # injected by make_server

    # -- plumbing ----------------------------------------------------------
    def log_message(self, format, *args):  # silence the default stderr access log
        return

    def _send(self, status, payload, extra_headers=None):
        body = (json.dumps(payload) + "\n").encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Request-Id", self._rid)
        for key, value in {**SECURITY_HEADERS, **(extra_headers or {})}.items():
            self.send_header(key, value)
        if self.state.draining.is_set() or (self.command == "POST" and status >= 400):
            # draining: shed keep-alive connections; failed POST: the body may be
            # unread, so the connection cannot be reused safely.
            self.send_header("Connection", "close")
            self.close_connection = True
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)
        self._status = status

    def _access_log(self):
        log.info(
            "request",
            extra={"fields": {
                "request_id": self._rid,
                "method": self.command,
                "path": self.path.split("?", 1)[0],
                "status": getattr(self, "_status", 0),
                "ms": round((time.monotonic() - self._t0) * 1000, 2),
                "ua": self.headers.get("User-Agent", "")[:100],
            }},
        )

    def _dispatch(self, routes):
        other = POST_ROUTES if routes is GET_ROUTES else GET_ROUTES
        self._t0 = time.monotonic()
        self._rid = uuid.uuid4().hex[:16]
        self._status = 0
        path = self.path.split("?", 1)[0]
        try:
            handler = routes.get(path)
            if handler is None:
                if path in other or (not routes and path in GET_ROUTES | POST_ROUTES):
                    self._send(405, {"error": "method_not_allowed"})
                else:
                    self._send(404, {"error": "not_found"})
            else:
                handler(self)
        except Exception:  # noqa: BLE001 - never leak internals to the client
            log.exception("unhandled error", extra={"fields": {"request_id": self._rid}})
            if not self._status:
                self._send(500, {"error": "internal_error", "request_id": self._rid})
        finally:
            self._access_log()

    def do_GET(self):
        self._dispatch(GET_ROUTES)

    do_HEAD = do_GET

    def do_POST(self):
        self._dispatch(POST_ROUTES)

    def do_PUT(self):
        self._dispatch({})

    do_DELETE = do_PATCH = do_PUT

    # -- auth --------------------------------------------------------------
    def _authorized(self):
        token = self.state.admin_token
        if not token:
            self._send(503, {"error": "admin_disabled"})
            return False
        header = self.headers.get("Authorization", "")
        supplied = header[7:] if header.startswith("Bearer ") else ""
        if not hmac.compare_digest(supplied.encode(), token.encode()):
            log.warning("admin auth failed", extra={"fields": {"request_id": self._rid}})
            self._send(401, {"error": "unauthorized"}, {"WWW-Authenticate": "Bearer"})
            return False
        return True

    # -- routes ------------------------------------------------------------
    def r_index(self):
        broken = self.state.chaos.is_broken()
        self._send(200, {
            "service": "hello-devops",
            "version": VERSION,
            "status": "degraded" if broken else "ok",
            "uptime_seconds": int(time.time() - self.state.started),
        })

    def r_livez(self):
        self._send(200, {"status": "ok"})

    def r_healthz(self):
        if self.state.chaos.is_broken():
            self._send(503, {"status": "broken", "reason": "chaos mode enabled"})
        else:
            self._send(200, {"status": "ok"})

    def r_readyz(self):
        if self.state.draining.is_set():
            self._send(503, {"status": "draining"})
        elif self.state.chaos.is_broken():
            self._send(503, {"status": "broken", "reason": "chaos mode enabled"})
        else:
            self._send(200, {"status": "ok"})

    def r_chaos_get(self):
        if self._authorized():
            self._send(200, {"state": "broken" if self.state.chaos.is_broken() else "ok"})

    def r_chaos_post(self):
        if not self._authorized():
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return self._send(400, {"error": "bad_content_length"})
        if length < 0 or length > MAX_BODY_BYTES:
            return self._send(413, {"error": "body_too_large"})
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
            action = body["state"] if isinstance(body, dict) else None
        except (ValueError, KeyError):
            action = None
        if action not in ("break", "recover"):
            return self._send(400, {"error": "state must be 'break' or 'recover'"})
        try:
            self.state.chaos.set_broken(action == "break")
        except Exception:  # noqa: BLE001
            log.exception("chaos write failed", extra={"fields": {"request_id": self._rid}})
            return self._send(502, {"error": "chaos_store_unavailable"})
        log.warning("chaos state changed", extra={"fields": {"request_id": self._rid, "action": action}})
        self._send(200, {"state": "broken" if action == "break" else "ok"})


GET_ROUTES = {
    "/": Handler.r_index,
    "/livez": Handler.r_livez,
    "/healthz": Handler.r_healthz,
    "/readyz": Handler.r_readyz,
    "/admin/chaos": Handler.r_chaos_get,
}
POST_ROUTES = {"/admin/chaos": Handler.r_chaos_post}


def make_server(state, host="0.0.0.0", port=8080):
    handler = type("BoundHandler", (Handler,), {"state": state})
    server = ThreadingHTTPServer((host, port), handler)
    server.daemon_threads = True
    return server


def build_state_from_env():
    param = os.getenv("CHAOS_SSM_PARAM")
    store = SsmChaosStore(param) if param else MemoryChaosStore()
    return State(Chaos(store), os.getenv("ADMIN_TOKEN"))


def main():
    setup_logging()
    port = int(os.getenv("PORT", "8080"))
    drain_seconds = float(os.getenv("DRAIN_SECONDS", "5"))
    state = build_state_from_env()
    server = make_server(state, port=port)

    def on_term(signum, _frame):
        # Flip /readyz to 503 first so the load balancer stops sending traffic,
        # wait for in-flight requests, then stop. Must not block the signal
        # handler (serve_forever lives on the main thread), so use a thread.
        log.info("shutdown signal", extra={"fields": {"signal": signum, "drain_seconds": drain_seconds}})
        state.draining.set()

        def stop():
            time.sleep(drain_seconds)
            server.shutdown()

        threading.Thread(target=stop, daemon=True).start()

    signal.signal(signal.SIGTERM, on_term)
    signal.signal(signal.SIGINT, on_term)
    log.info("starting", extra={"fields": {
        "port": port, "version": VERSION,
        "admin": "enabled" if state.admin_token else "disabled",
        "chaos_store": "ssm" if os.getenv("CHAOS_SSM_PARAM") else "memory",
    }})
    try:
        server.serve_forever()
    finally:
        server.server_close()
        log.info("stopped")


if __name__ == "__main__":
    main()
