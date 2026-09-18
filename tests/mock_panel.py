#!/usr/bin/env python3
"""Mock 3x-ui panel used by the vpn-sanai test-suite.

It implements the subset of the panel API that vpn-sanai talks to, including
the parts that matter for correctness:

  * Bearer-token authentication on every /panel/api/* route
  * the {"success","msg","obj"} envelope, with HTTP 200 for validation errors
  * the inbound payload validation the real panel performs (protocol allow
    list, port range, unique tag, port already in use, REALITY key material
    required for security=reality, transport-specific settings)
  * clients/add semantics incl. duplicate-email rejection and inbound errors
    reported as "inbound <id>: <message>"
  * settings/streamSettings returned as JSON *strings* from /inbounds/list,
    exactly like the real panel does

Every request is appended to $MOCK_LOG as one JSON object per line, so tests
can assert on what vpn-sanai actually sent.

Usage:  mock_panel.py --port 0 [--base-path /secret/] [--token TOKEN] [--log FILE]
Prints "LISTENING <port>" on stdout once ready.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlparse

PROTOCOLS = {
    "vmess", "vless", "trojan", "shadowsocks", "wireguard", "hysteria", "http",
    "mixed", "tunnel", "tun", "mtproto", "amneziawg", "tuic",
}

STATE: dict = {
    "inbounds": {},      # id -> inbound dict
    "clients": {},       # email -> client dict
    "next_id": 1,
    "requests": [],
}


def envelope(success: bool, msg: str = "", obj=None) -> bytes:
    return json.dumps({"success": success, "msg": msg, "obj": obj}).encode()


def as_obj(value):
    """The panel accepts settings/streamSettings/sniffing as objects or strings."""
    if value is None:
        return {}
    if isinstance(value, str):
        try:
            return json.loads(value)
        except json.JSONDecodeError:
            return {}
    return value


class Handler(BaseHTTPRequestHandler):
    server_version = "mock-3x-ui/1.0"
    base_path = "/"
    token = "test-token"
    log_file = ""
    csrf_token = "mock-csrf-token"
    session_id = "mock-session-id"

    # --- plumbing ---------------------------------------------------------
    def log_message(self, *args):  # keep the test output clean
        pass

    def _record(self, method: str, path: str, body: bytes, code: int) -> None:
        if not self.log_file:
            return
        entry = {
            "method": method,
            "path": path,
            "auth": self.headers.get("Authorization", ""),
            "content_type": self.headers.get("Content-Type", ""),
            "code": code,
        }
        try:
            entry["body"] = json.loads(body.decode() or "null")
        except (json.JSONDecodeError, UnicodeDecodeError):
            entry["body"] = body.decode(errors="replace")
        STATE["requests"].append(entry)
        with open(self.log_file, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry, ensure_ascii=False) + "\n")

    def _send(self, payload: bytes, code: int = 200, headers=None) -> None:
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(payload)

    def _read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def _strip_base(self, path: str) -> str:
        base = self.base_path.rstrip("/")
        if base and path.startswith(base):
            path = path[len(base):]
        return path or "/"

    def _authorized(self) -> bool:
        return self.headers.get("Authorization", "") == f"Bearer {self.token}"

    def _route(self, method: str) -> None:
        raw_body = self._read_body()
        parsed = urlparse(self.path)
        path = self._strip_base(parsed.path)

        # Public routes
        if path == "/csrf-token":
            # The real panel stores the token in the session and the session
            # middleware answers with Set-Cookie ("3x-ui"), so browsers/clients
            # can present it back on /login.
            self._send(envelope(True, "ok", self.csrf_token),
                       headers={"Set-Cookie": f"3x-ui={self.session_id}; Path={self.base_path}"})
            self._record(method, path, raw_body, 200)
            return
        if path == "/login":
            if self.headers.get("X-CSRF-Token") != self.csrf_token:
                self._send(envelope(False, "csrf token mismatch", None), 403)
                self._record(method, path, raw_body, 403)
                return
            self._send(envelope(True, "login ok", None),
                       headers={"Set-Cookie": f"3x-ui={self.session_id}; Path={self.base_path}"})
            self._record(method, path, raw_body, 200)
            return

        if path.startswith("/panel/api"):
            cookie_ok = f"3x-ui={self.session_id}" in (self.headers.get("Cookie") or "")
            # The panel's CSRFMiddleware only checks unsafe methods (see
            # internal/web/middleware/security.go: isSafeMethod).
            csrf_ok = method in ("GET", "HEAD", "OPTIONS", "TRACE") or \
                self.headers.get("X-CSRF-Token") == self.csrf_token
            if not self._authorized() and not (cookie_ok and csrf_ok):
                self._send(envelope(False, "unauthorized", None), 401)
                self._record(method, path, raw_body, 401)
                return
            payload, code = self._api(method, path, raw_body)
            self._send(payload, code)
            self._record(method, path, raw_body, code)
            return

        self._send(envelope(False, "not found", None), 404)

    # --- API ---------------------------------------------------------------
    def _api(self, method: str, path: str, body: bytes):
        body_json = None
        if body:
            try:
                body_json = json.loads(body.decode())
            except (json.JSONDecodeError, UnicodeDecodeError):
                body_json = None

        if path == "/panel/api/server/status":
            return envelope(True, "ok", {"xray": {"state": "running", "version": "25.3.6"}}), 200

        if path == "/panel/api/server/getNewX25519Cert":
            return envelope(True, "ok", {
                "privateKey": "PRIVATE_KEY_TEST_BASE64=",
                "publicKey": "PUBLIC_KEY_TEST_BASE64=",
            }), 200

        if path == "/panel/api/server/restartXrayService":
            return envelope(True, "xray restarted", None), 200

        if path == "/panel/api/inbounds/list":
            items = []
            for inbound in STATE["inbounds"].values():
                copy = dict(inbound)
                # The real panel stores/serves these as JSON strings.
                copy["settings"] = json.dumps(inbound["settings"])
                copy["streamSettings"] = json.dumps(inbound["streamSettings"])
                copy["sniffing"] = json.dumps(inbound["sniffing"])
                items.append(copy)
            return envelope(True, "ok", items), 200

        if path == "/panel/api/inbounds/add":
            return self._add_inbound(body_json)

        if path.startswith("/panel/api/inbounds/get/"):
            inbound_id = int(path.rsplit("/", 1)[-1])
            inbound = STATE["inbounds"].get(inbound_id)
            if not inbound:
                return envelope(False, "inbound not found", None), 200
            copy = dict(inbound)
            copy["settings"] = json.dumps(copy["settings"])
            copy["streamSettings"] = json.dumps(copy["streamSettings"])
            copy["sniffing"] = json.dumps(copy["sniffing"])
            return envelope(True, "ok", copy), 200

        if path.startswith("/panel/api/inbounds/update/"):
            inbound_id = int(path.rsplit("/", 1)[-1])
            if inbound_id not in STATE["inbounds"]:
                return envelope(False, "inbound not found", None), 200
            updated = dict(body_json or {})
            updated["id"] = inbound_id
            for field in ("settings", "streamSettings", "sniffing"):
                updated[field] = as_obj(updated.get(field))
            STATE["inbounds"][inbound_id] = updated
            return envelope(True, "updated", updated), 200

        if path == "/panel/api/clients/add":
            return self._add_client(body_json)

        if path.startswith("/panel/api/clients/get/"):
            email = unquote(path.rsplit("/", 1)[-1])
            client = STATE["clients"].get(email)
            if not client:
                return envelope(False, "client not found", None), 200
            return envelope(True, "ok", {"client": client}), 200

        if path.startswith("/panel/api/clients/links/"):
            email = unquote(path.rsplit("/", 1)[-1])
            client = STATE["clients"].get(email)
            if not client:
                return envelope(False, "client not found", None), 200
            inbound = STATE["inbounds"].get(client["inboundIds"][0], {})
            link = (f"vless://{client['id']}@panel.example.com:{inbound.get('port', 443)}"
                    f"?type=tcp&security=reality# {email}")
            return envelope(True, "ok", [link]), 200

        if path.startswith("/panel/api/clients/del/"):
            email = unquote(path.rsplit("/", 1)[-1])
            STATE["clients"].pop(email, None)
            return envelope(True, "client deleted", None), 200

        if path.startswith("/panel/api/clients/") and path.endswith("/attach"):
            email = unquote(path.split("/")[4])
            if email not in STATE["clients"]:
                return envelope(False, "client not found", None), 200
            ids = body_json.get("inboundIds", []) if isinstance(body_json, dict) else []
            STATE["clients"][email]["inboundIds"] = sorted(set(STATE["clients"][email]["inboundIds"] + ids))
            return envelope(True, "attached", None), 200

        if path == "/panel/api/clients/list":
            return envelope(True, "ok", list(STATE["clients"].values())), 200

        return envelope(False, f"no mock route for {path}", None), 200

    # --- validation mirrors the real panel --------------------------------
    def _add_inbound(self, payload):
        if not isinstance(payload, dict):
            return envelope(False, "request body failed validation",
                            {"issues": ["body must be a JSON object"]}), 200

        issues = []
        protocol = payload.get("protocol")
        port = payload.get("port")
        if protocol not in PROTOCOLS:
            issues.append(f"protocol must be one of {sorted(PROTOCOLS)}")
        if not isinstance(port, int) or not 0 <= port <= 65535:
            issues.append("port must be between 0 and 65535")
        if issues:
            return envelope(False, "request body failed validation", {"issues": issues}), 200

        if any(i["port"] == port for i in STATE["inbounds"].values()):
            return envelope(False, f"Port {port} is already in use", None), 200

        tag = payload.get("tag") or f"inbound-{port}"
        if any(i.get("tag") == tag for i in STATE["inbounds"].values()):
            return envelope(False, "tag already exists", None), 200

        settings = as_obj(payload.get("settings"))
        stream = as_obj(payload.get("streamSettings"))
        sniffing = as_obj(payload.get("sniffing"))

        if stream.get("security") == "reality":
            reality = stream.get("realitySettings") or {}
            if not reality.get("privateKey"):
                return envelope(False, "realitySettings.privateKey is required", None), 200
            if not reality.get("shortIds"):
                return envelope(False, "realitySettings.shortIds is required", None), 200
            if not reality.get("serverNames"):
                return envelope(False, "realitySettings.serverNames is required", None), 200
            if not reality.get("target"):
                return envelope(False, "realitySettings.target is required", None), 200
        if stream.get("network") == "tcp" and "tcpSettings" not in stream:
            return envelope(False, "tcpSettings is required for the tcp transport", None), 200
        if stream.get("network") == "xhttp":
            if "xhttpSettings" not in stream:
                return envelope(False, "xhttpSettings is required for the xhttp transport", None), 200
            if not (stream.get("xhttpSettings") or {}).get("path"):
                return envelope(False, "xhttpSettings.path is required", None), 200

        inbound_id = STATE["next_id"]
        STATE["next_id"] += 1
        record = {
            "id": inbound_id,
            "up": payload.get("up", 0),
            "down": payload.get("down", 0),
            "total": payload.get("total", 0),
            "remark": payload.get("remark", ""),
            "enable": payload.get("enable", True),
            "expiryTime": payload.get("expiryTime", 0),
            "listen": payload.get("listen", ""),
            "port": port,
            "protocol": protocol,
            "tag": tag,
            "settings": settings,
            "streamSettings": stream,
            "sniffing": sniffing,
            "shareAddr": payload.get("shareAddr", ""),
            "shareAddrStrategy": payload.get("shareAddrStrategy", "node"),
        }
        STATE["inbounds"][inbound_id] = record
        return envelope(True, "inbound created", record), 200

    def _add_client(self, payload):
        if not isinstance(payload, dict) or "client" not in payload:
            return envelope(False, "request body failed validation",
                            {"issues": ["client is required"]}), 200
        client = dict(payload.get("client") or {})
        email = client.get("email")
        inbound_ids = payload.get("inboundIds") or []
        if not email:
            return envelope(False, "request body failed validation",
                            {"issues": ["client.email is required"]}), 200
        if not inbound_ids:
            return envelope(False, "request body failed validation",
                            {"issues": ["inboundIds requires at least one id"]}), 200

        for inbound_id in inbound_ids:
            if inbound_id not in STATE["inbounds"]:
                return envelope(False, f"inbound {inbound_id}: not found", None), 200

        if email in STATE["clients"]:
            return envelope(False, "Client email already exists", None), 200

        client.setdefault("id", f"uuid-{len(STATE['clients']) + 1}")
        client.setdefault("subId", f"sub{len(STATE['clients']) + 1:08d}")
        client["inboundIds"] = inbound_ids
        STATE["clients"][email] = client

        # The real panel attaches the client to each inbound's settings.
        for inbound_id in inbound_ids:
            inbound = STATE["inbounds"][inbound_id]
            inbound.setdefault("settings", {}).setdefault("clients", []).append(client)
        return envelope(True, "Client added", None), 200

    # --- HTTP verbs --------------------------------------------------------
    def do_GET(self):  # noqa: N802
        self._route("GET")

    def do_POST(self):  # noqa: N802
        self._route("POST")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--base-path", default="/")
    parser.add_argument("--token", default="test-token")
    parser.add_argument("--log", default="")
    args = parser.parse_args()

    Handler.base_path = args.base_path
    Handler.token = args.token
    Handler.log_file = args.log
    if args.log and os.path.exists(args.log):
        os.remove(args.log)

    httpd = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    port = httpd.server_address[1]
    print(f"LISTENING {port}", flush=True)

    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        thread.join()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
