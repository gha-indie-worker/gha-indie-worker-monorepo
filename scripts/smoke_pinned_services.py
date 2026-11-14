#!/usr/bin/env python3
"""Real pinned binary startup, HTTP, collision and shutdown smoke tests.

Only localhost is used. The service binaries were built separately from the
two publicly materialized, exact Gitlinks. No secrets or network backends.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
API = "gha-indie-worker-api-server"
WEB = "gha-indie-worker-web-server"
DEADLINE_SECONDS = 15.0


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def exchange(port: int, path: str) -> tuple[int, dict[str, str], bytes]:
    with socket.create_connection(("127.0.0.1", port), timeout=2) as conn:
        conn.settimeout(2)
        conn.sendall(
            ("GET " + path + " HTTP/1.1\r\nHost: localhost\r\n"
             "Connection: close\r\n\r\n").encode("ascii")
        )
        conn.shutdown(socket.SHUT_WR)
        data = bytearray()
        while True:
            part = conn.recv(4096)
            if not part:
                break
            data.extend(part)
            if len(data) > 64 * 1024:
                raise AssertionError("unbounded HTTP response")
    headers_raw, separator, body = bytes(data).partition(b"\r\n\r\n")
    if not separator:
        raise AssertionError("HTTP response has no CRLF header boundary")
    lines = headers_raw.split(b"\r\n")
    first = lines[0].split(b" ")
    if len(first) < 3 or first[0] != b"HTTP/1.1":
        raise AssertionError("invalid HTTP status line")
    status = int(first[1])
    headers: dict[str, str] = {}
    for line in lines[1:]:
        name, sep, value = line.partition(b":")
        if not sep:
            raise AssertionError("invalid HTTP header")
        key = name.decode("ascii").lower()
        if key in headers:
            raise AssertionError("duplicate HTTP response header")
        headers[key] = value.strip().decode("ascii")
    if int(headers.get("content-length", "-1")) != len(body):
        raise AssertionError("incorrect HTTP Content-Length")
    if headers.get("connection", "").lower() != "close":
        raise AssertionError("response is not connection-close bounded")
    return status, headers, body


def ready(process: subprocess.Popen[bytes], port: int, service: str) -> None:
    deadline = time.monotonic() + DEADLINE_SECONDS
    last: Exception | None = None
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise AssertionError(f"{service} exited before readiness: {process.returncode}")
        try:
            status, headers, body = exchange(port, "/readyz")
            assert status == 200, (service, status)
            assert headers["content-type"].startswith("application/json"), headers
            payload = json.loads(body)
            assert payload["ok"] is True, payload
            print(f"PASS {service} /readyz HTTP 200 application/json")
            return
        except (OSError, TimeoutError) as exc:
            last = exc
            time.sleep(0.05)
    raise AssertionError(f"{service} readiness timed out: {type(last).__name__}")


def assert_response(port: int, path: str, expected_status: int, content_type: str,
                    expected_body: bytes | None = None) -> None:
    status, headers, body = exchange(port, path)
    assert status == expected_status, (path, status)
    assert headers["content-type"].startswith(content_type), (path, headers)
    if expected_body is not None:
        assert body == expected_body, (path, body)
    print(f"PASS {path} HTTP {status} {content_type}")


def stop(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=4)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=4)


def verify_bind_collision(binary: Path, env: dict[str, str], port: int,
                          live: subprocess.Popen[bytes], service: str) -> None:
    # The existing service must retain ownership of this port. A second startup
    # must fail, not silently switch address or steal the live listener.
    attempt = subprocess.run([str(binary)], cwd=ROOT, env=env,
                             capture_output=True, timeout=6, check=False)
    assert attempt.returncode != 0, f"{service} unexpectedly bound occupied port"
    assert live.poll() is None, f"{service} crashed during bind collision"
    status, _, body = exchange(port, "/readyz")
    assert status == 200 and json.loads(body)["ok"] is True
    print(f"PASS {service} bind collision fails closed and original remains healthy")


def main() -> int:
    api_port, web_port = free_port(), free_port()
    while web_port == api_port:
        web_port = free_port()
    outdir = Path(os.environ["CARGO_TARGET_DIR"])
    api_bin, web_bin = outdir / "debug" / API, outdir / "debug" / WEB
    for binary in (api_bin, web_bin):
        if not binary.is_file():
            raise AssertionError(f"binary missing: {binary.name}")
    env = os.environ.copy()
    for name in ("GHA_INDIE_WORKER_API_BIND", "GHA_INDIE_WORKER_API_TCP_BIND",
                 "GHA_INDIE_WORKER_NATS_URL", "GHA_INDIE_WORKER_WEB_BIND",
                 "GHA_INDIE_WORKER_API_HTTP_BASE", "GHA_INDIE_WORKER_DATABASE_URL"):
        env.pop(name, None)
    api_env = {**env, "GHA_INDIE_WORKER_API_BIND": f"127.0.0.1:{api_port}"}
    web_env = {**env, "GHA_INDIE_WORKER_WEB_BIND": f"127.0.0.1:{web_port}"}
    processes: list[subprocess.Popen[bytes]] = []
    with tempfile.TemporaryDirectory(prefix="gha-pinned-smoke-") as temp:
        try:
            api_log = open(Path(temp) / "api.log", "wb")
            web_log = open(Path(temp) / "web.log", "wb")
            try:
                api = subprocess.Popen([str(api_bin)], cwd=ROOT, env=api_env,
                                       stdout=api_log, stderr=subprocess.STDOUT,
                                       start_new_session=True)
                processes.append(api)
                web = subprocess.Popen([str(web_bin)], cwd=ROOT, env=web_env,
                                       stdout=web_log, stderr=subprocess.STDOUT,
                                       start_new_session=True)
                processes.append(web)
            finally:
                api_log.close()
                web_log.close()
            ready(api, api_port, API)
            ready(web, web_port, WEB)
            assert_response(api_port, "/healthz", 200, "application/json")
            assert_response(api_port, "/does-not-exist", 404,
                            "text/plain", b"not found\n")
            assert_response(web_port, "/", 200, "text/html")
            assert_response(web_port, "/does-not-exist", 404,
                            "text/plain", b"not found\n")
            for _ in range(4):
                ready(api, api_port, API)
                ready(web, web_port, WEB)
            verify_bind_collision(api_bin, api_env, api_port, api, API)
            verify_bind_collision(web_bin, web_env, web_port, web, WEB)
            print("PASS both pinned binaries started, served and retained independent listeners")
        finally:
            for process in reversed(processes):
                stop(process)
            if processes and any(process.poll() is None for process in processes):
                raise AssertionError("process cleanup failed")
    print("PASS bounded cleanup and process-group shutdown")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, OSError, subprocess.TimeoutExpired, KeyError, ValueError) as exc:
        print(f"FAIL: startup smoke: {type(exc).__name__}: {exc}", file=sys.stderr)
        raise SystemExit(1) from None
