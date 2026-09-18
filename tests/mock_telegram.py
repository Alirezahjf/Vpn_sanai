#!/usr/bin/env python3
"""Mock Telegram Bot API used by the vpn-sanai test-suite.

It implements exactly the surface lib/telegram.sh talks to:

  * POST /bot<token>/getUpdates — returns the queued updates whose update_id
    is >= the requested offset (updates are static JSON lines in --queue,
    each one a complete update object including its update_id, so tests have
    full control over ordering and ids)
  * POST /bot<token>/getMe
  * POST /bot<token>/sendMessage | sendPhoto | sendDocument | editMessageText
    | deleteMessage | answerCallbackQuery | sendChatAction
  * request bodies may be JSON or multipart/form-data (sendPhoto etc.)

Every request is appended to $MOCK_LOG as one JSON object per line with the
method, the parsed parameters and a monotonically increasing message_id, so
tests can assert on what the bot actually sent.

Usage:  mock_telegram.py --port 0 --token TOKEN [--queue FILE] [--log FILE]
Prints "LISTENING <port>" on stdout once ready.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from email.parser import BytesParser
from email.policy import HTTP
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

MSG_ID = [100]


def _ok(result=None) -> bytes:
    return json.dumps({"ok": True, "result": result if result is not None else {}}).encode()


def _err(code: int, description: str) -> bytes:
    return json.dumps({"ok": False, "error_code": code, "description": description}).encode()


def parse_body(headers, body: bytes) -> dict:
    """JSON, urlencoded and multipart bodies all become a flat dict."""
    ctype = headers.get("Content-Type", "")
    if "application/json" in ctype:
        try:
            data = json.loads(body.decode() or "{}")
            return data if isinstance(data, dict) else {}
        except (json.JSONDecodeError, UnicodeDecodeError):
            return {}
    if "application/x-www-form-urlencoded" in ctype:
        return {k: v[-1] for k, v in parse_qs(body.decode(errors="replace")).items()}
    if "multipart/form-data" in ctype:
        msg = BytesParser(policy=HTTP).parsebytes(
            b"Content-Type: " + ctype.encode() + b"\r\n\r\n" + body
        )
        out = {}
        for part in msg.iter_parts():
            name = part.get_param("name", header="content-disposition")
            if name is None:
                continue
            filename = part.get_filename()
            if filename is not None:
                out[name] = {
                    "filename": filename,
                    "size": len(part.get_payload(decode=True) or b""),
                }
            else:
                out[name] = part.get_payload(decode=True).decode(errors="replace")
        return out
    if not body:
        return {}
    # Some clients POST without a content type: try JSON as a best effort.
    try:
        data = json.loads(body.decode())
        return data if isinstance(data, dict) else {}
    except (json.JSONDecodeError, UnicodeDecodeError):
        return {}


class Handler(BaseHTTPRequestHandler):
    server_version = "mock-telegram/1.0"
    token = "test-telegram-token"
    queue_file = ""
    log_file = ""

    def log_message(self, *args):  # keep the test output clean
        pass

    # --- plumbing ---------------------------------------------------------
    def _send(self, payload: bytes, code: int = 200) -> None:
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def _record(self, method: str, params: dict, message_id=None) -> None:
        if not self.log_file:
            return
        entry = {"method": method, "params": params}
        if message_id is not None:
            entry["message_id"] = message_id
        with open(self.log_file, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry, ensure_ascii=False) + "\n")

    # --- routes -----------------------------------------------------------
    def do_POST(self):  # noqa: N802
        body = self._read_body()
        match = re.match(r"^/bot([^/]+)/([A-Za-z]+)$", self.path)
        if not match or match.group(1) != self.token:
            self._send(_err(401, "Unauthorized"), 401)
            return
        token, method = match.group(1), match.group(2)
        params = parse_body(self.headers, body)

        if method == "getMe":
            self._send(_ok({"id": 1, "is_bot": True, "first_name": "vpn-sanai",
                            "username": "vpn_sanai_test_bot"}))
            return

        if method == "getUpdates":
            # Offset may arrive in the JSON body or as a query parameter.
            offset = 0
            try:
                offset = int(params.get("offset", 0))
            except (TypeError, ValueError):
                offset = 0
            qs = parse_qs(urlparse(self.path).query)
            if "offset" in qs:
                try:
                    offset = int(qs["offset"][0])
                except (TypeError, ValueError):
                    pass
            updates = []
            if self.queue_file and os.path.exists(self.queue_file):
                with open(self.queue_file, encoding="utf-8") as fh:
                    for line in fh:
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            upd = json.loads(line)
                        except json.JSONDecodeError:
                            continue
                        if upd.get("update_id", 0) >= offset:
                            updates.append(upd)
            self._send(_ok(updates))
            return

        if method in ("sendMessage", "sendPhoto", "sendDocument", "editMessageText",
                      "deleteMessage", "answerCallbackQuery", "sendChatAction",
                      "copyMessage", "pinChatMessage"):
            MSG_ID[0] += 1
            self._record(method, params, MSG_ID[0])
            self._send(_ok({"message_id": MSG_ID[0], "chat": {"id": params.get("chat_id")}}))
            return

        # Unknown method: record it and fail like the real API would.
        self._record(f"unknown:{method}", params)
        self._send(_err(404, "Not Found"), 404)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--token", default="test-telegram-token")
    parser.add_argument("--queue", default="")
    parser.add_argument("--log", default="")
    args = parser.parse_args()

    Handler.token = args.token
    Handler.queue_file = args.queue
    Handler.log_file = args.log
    if args.log and os.path.exists(args.log):
        os.remove(args.log)

    httpd = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    port = httpd.server_address[1]
    print(f"LISTENING {port}", flush=True)

    thread = __import__("threading").Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        thread.join()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
