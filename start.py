#!/usr/bin/env python3
"""Cross-platform launcher for SofterPlease backend and web UI."""

from __future__ import annotations

import argparse
import os
import signal
import socket
import subprocess
import sys
import threading
import time
import webbrowser
from pathlib import Path
from typing import Iterable


ROOT = Path(__file__).resolve().parent
BACKEND_DIR = ROOT / "backend"
WEB_DIR = ROOT / "web"
DEFAULT_BACKEND_PORT = 8000
DEFAULT_WEB_PORT = 8080


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Start SofterPlease backend and desktop web UI.",
    )
    parser.add_argument("--backend-host", default="0.0.0.0", help="Backend bind host.")
    parser.add_argument("--backend-port", type=int, default=DEFAULT_BACKEND_PORT, help="Backend port.")
    parser.add_argument("--web-host", default="127.0.0.1", help="Web UI bind host.")
    parser.add_argument("--web-port", type=int, default=DEFAULT_WEB_PORT, help="Web UI port.")
    parser.add_argument("--python", dest="python_bin", help="Python executable for backend/web commands.")
    parser.add_argument("--emotion-backend", help="Set EMOTION_BACKEND, for example sensevoice, caire, rule.")
    parser.add_argument("--install", action="store_true", help="Install backend requirements before starting.")
    parser.add_argument("--no-backend", action="store_true", help="Do not start the backend.")
    parser.add_argument("--no-web", action="store_true", help="Do not start the web UI.")
    parser.add_argument("--no-open", action="store_true", help="Do not open the web UI in a browser.")
    return parser.parse_args()


def find_python(explicit: str | None) -> str:
    if explicit:
        return explicit

    if os.name == "nt":
        venv_python = ROOT / ".venv" / "Scripts" / "python.exe"
    else:
        venv_python = ROOT / ".venv" / "bin" / "python"

    if venv_python.exists():
        return str(venv_python)

    return sys.executable


def local_url(port: int) -> str:
    return f"http://localhost:{port}"


def get_lan_ip() -> str | None:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.connect(("8.8.8.8", 80))
            return sock.getsockname()[0]
    except OSError:
        return None


def is_port_open(port: int, host: str = "127.0.0.1") -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(0.3)
        return sock.connect_ex((host, port)) == 0


def run_install(python_bin: str) -> None:
    requirements = BACKEND_DIR / "requirements.txt"
    print(f"[setup] Installing backend requirements from {requirements}")
    subprocess.run(
        [python_bin, "-m", "pip", "install", "-r", "requirements.txt"],
        cwd=BACKEND_DIR,
        check=True,
    )


def popen_kwargs() -> dict:
    kwargs: dict = {
        "stdout": subprocess.PIPE,
        "stderr": subprocess.STDOUT,
        "text": True,
        "encoding": "utf-8",
        "errors": "replace",
        "bufsize": 1,
    }
    if os.name == "nt":
        kwargs["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP
    else:
        kwargs["start_new_session"] = True
    return kwargs


def start_process(name: str, command: list[str], cwd: Path, env: dict[str, str]) -> subprocess.Popen:
    print(f"[{name}] {' '.join(command)}")
    process = subprocess.Popen(command, cwd=cwd, env=env, **popen_kwargs())
    thread = threading.Thread(target=stream_output, args=(name, process), daemon=True)
    thread.start()
    return process


def stream_output(name: str, process: subprocess.Popen) -> None:
    assert process.stdout is not None
    for line in process.stdout:
        print(f"[{name}] {line.rstrip()}")


def start_backend(args: argparse.Namespace, python_bin: str, env: dict[str, str]) -> subprocess.Popen | None:
    if args.no_backend:
        print("[backend] Skipped")
        return None

    if is_port_open(args.backend_port):
        print(f"[backend] Already running on {local_url(args.backend_port)}")
        return None

    command = [
        python_bin,
        "-m",
        "uvicorn",
        "app.main:app",
        "--reload",
        "--host",
        args.backend_host,
        "--port",
        str(args.backend_port),
    ]
    return start_process("backend", command, BACKEND_DIR, env)


def start_web(args: argparse.Namespace, python_bin: str, env: dict[str, str]) -> subprocess.Popen | None:
    if args.no_web:
        print("[web] Skipped")
        return None

    if is_port_open(args.web_port):
        print(f"[web] Already running on {local_url(args.web_port)}")
        return None

    command = [
        python_bin,
        "-m",
        "http.server",
        str(args.web_port),
        "--bind",
        args.web_host,
        "--directory",
        str(WEB_DIR),
    ]
    return start_process("web", command, ROOT, env)


def stop_processes(processes: Iterable[subprocess.Popen]) -> None:
    for process in processes:
        if process.poll() is not None:
            continue

        try:
            if os.name == "nt":
                process.send_signal(signal.CTRL_BREAK_EVENT)
            else:
                os.killpg(process.pid, signal.SIGTERM)
        except Exception:
            process.terminate()

    deadline = time.time() + 8
    for process in processes:
        while process.poll() is None and time.time() < deadline:
            time.sleep(0.1)
        if process.poll() is None:
            process.kill()


def print_urls(args: argparse.Namespace) -> None:
    lan_ip = get_lan_ip()
    print("")
    print("SofterPlease is starting.")
    print(f"- Web UI:      {local_url(args.web_port)}")
    print(f"- Backend API: {local_url(args.backend_port)}")
    print(f"- API docs:    {local_url(args.backend_port)}/docs")
    if lan_ip:
        print(f"- LAN backend: http://{lan_ip}:{args.backend_port}")
    print("")
    print("Press Ctrl+C to stop services started by this launcher.")
    print("")


def main() -> int:
    args = parse_args()
    python_bin = find_python(args.python_bin)
    env = os.environ.copy()
    env["PYTHONUNBUFFERED"] = "1"
    if args.emotion_backend:
        env["EMOTION_BACKEND"] = args.emotion_backend

    if args.install:
        run_install(python_bin)

    processes: list[subprocess.Popen] = []
    backend = start_backend(args, python_bin, env)
    if backend:
        processes.append(backend)

    web = start_web(args, python_bin, env)
    if web:
        processes.append(web)

    print_urls(args)

    if not args.no_open and not args.no_web:
        webbrowser.open(local_url(args.web_port))

    if not processes:
        print("No new process was started. Existing services may already be running.")
        return 0

    try:
        while True:
            time.sleep(0.5)
            if all(process.poll() is not None for process in processes):
                break
    except KeyboardInterrupt:
        print("\nStopping services...")
        stop_processes(processes)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
