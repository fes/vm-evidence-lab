import datetime
import math
import os
import subprocess
import threading
import time
from abc import ABC, abstractmethod
from dataclasses import dataclass
from typing import Any, Dict, Mapping, Optional, Sequence

from .errors import TransportError
from .validation import MAX_JSON_BYTES, dump_json, load_json


def utc_now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat(
        timespec="milliseconds").replace("+00:00", "Z")


@dataclass(frozen=True)
class TransportResponse:
    result: Dict[str, Any]
    sent_monotonic_ns: int
    received_monotonic_ns: int
    stderr: str = ""

    @property
    def elapsed_seconds(self) -> float:
        return max(0, self.received_monotonic_ns - self.sent_monotonic_ns) / 1e9


class Transport(ABC):
    @abstractmethod
    def exchange(self, command: Mapping[str, Any], timeout_seconds: float) -> TransportResponse:
        pass


class DryRunTransport(Transport):
    def __init__(
        self,
        capability_manifest: Optional[Mapping[str, Any]] = None,
        platform: str = "linux",
    ) -> None:
        self.capability_manifest = capability_manifest
        self.platform = (
            str(capability_manifest.get("platform", platform))
            if capability_manifest is not None else platform
        )
        self.commands = []

    def exchange(self, command: Mapping[str, Any], timeout_seconds: float) -> TransportResponse:
        if not math.isfinite(timeout_seconds) or timeout_seconds <= 0:
            raise TransportError("transport timeout must be positive")
        sent = time.monotonic_ns()
        timestamp = utc_now()
        self.commands.append(dict(command))
        result = {
            "schema_version": 1,
            "session_id": command["session_id"],
            "sequence": command["sequence"],
            "status": "pass",
            "operation": command["operation"],
            "started_at": timestamp,
            "completed_at": timestamp,
            "duration_ms": 0,
            "diagnostics": {
                "driver": "dry-run",
                "platform": self.platform,
                "target": {
                    "pid": 0,
                    "window_found": False,
                    "foreground": False,
                    "visible": False,
                },
                "message": "dry-run: no guest command was executed",
            },
            "artifacts": [],
        }
        if self.capability_manifest is not None and command["operation"] == "capabilities":
            result["observation"] = dict(self.capability_manifest)
        return TransportResponse(result, sent, time.monotonic_ns())


class TrustedSubprocessTransport(Transport):
    def __init__(
        self,
        trusted_argv: Sequence[str],
        *,
        maximum_stdin_bytes: int = 64 * 1024,
        maximum_stdout_bytes: int = MAX_JSON_BYTES,
        maximum_stderr_bytes: int = 64 * 1024,
    ) -> None:
        if not trusted_argv or any(not isinstance(item, str) or "\0" in item
                                    for item in trusted_argv):
            raise TransportError("trusted argv must be a non-empty sequence of strings")
        if any(limit <= 0 for limit in (
                maximum_stdin_bytes, maximum_stdout_bytes, maximum_stderr_bytes)):
            raise TransportError("transport byte limits must be positive")
        self.trusted_argv = tuple(trusted_argv)
        self.maximum_stdin_bytes = maximum_stdin_bytes
        self.maximum_stdout_bytes = maximum_stdout_bytes
        self.maximum_stderr_bytes = maximum_stderr_bytes

    def exchange(self, command: Mapping[str, Any], timeout_seconds: float) -> TransportResponse:
        if not math.isfinite(timeout_seconds) or timeout_seconds <= 0:
            raise TransportError("transport timeout must be positive")
        request = (dump_json(command) + "\n").encode("utf-8")
        if len(request) > self.maximum_stdin_bytes:
            raise TransportError(
                f"command JSON exceeds stdin limit of {self.maximum_stdin_bytes} bytes")
        sent = time.monotonic_ns()
        popen_options = {
            "stdin": subprocess.PIPE,
            "stdout": subprocess.PIPE,
            "stderr": subprocess.PIPE,
            "shell": False,
            "close_fds": os.name != "nt",
        }
        if os.name != "nt":
            popen_options["start_new_session"] = True
        try:
            process = subprocess.Popen(list(self.trusted_argv), **popen_options)
        except OSError as error:
            raise TransportError(f"could not start trusted transport: {error}") from error
        stdout = bytearray()
        stderr = bytearray()
        stdout_truncated = []
        stderr_truncated = []

        def read_stream(stream: Any, destination: bytearray, limit: int,
                        truncated: list) -> None:
            try:
                while True:
                    chunk = stream.read(8192)
                    if not chunk:
                        return
                    room = limit - len(destination)
                    if room > 0:
                        destination.extend(chunk[:room])
                    if len(chunk) > room:
                        truncated.append(True)
            except OSError:
                return

        def write_request() -> None:
            try:
                process.stdin.write(request)
                process.stdin.close()
            except (BrokenPipeError, OSError):
                pass

        readers = [
            threading.Thread(target=read_stream, args=(
                process.stdout, stdout, self.maximum_stdout_bytes, stdout_truncated),
                daemon=True),
            threading.Thread(target=read_stream, args=(
                process.stderr, stderr, self.maximum_stderr_bytes, stderr_truncated),
                daemon=True),
        ]
        writer = threading.Thread(target=write_request, daemon=True)
        for thread in readers + [writer]:
            thread.start()
        timed_out = False
        try:
            return_code = process.wait(timeout=timeout_seconds)
        except subprocess.TimeoutExpired:
            timed_out = True
            self._terminate(process)
            return_code = process.wait()
        for thread in readers:
            thread.join(timeout=1)
        writer.join(timeout=1)
        received = time.monotonic_ns()
        for stream in (process.stdin, process.stdout, process.stderr):
            if stream is not None and not stream.closed:
                try:
                    stream.close()
                except OSError:
                    pass
        if timed_out:
            raise TransportError(
                f"trusted transport exceeded {timeout_seconds:g} second timeout")
        stderr_text = self._decode(stderr, "stderr", stderr_truncated)
        if stdout_truncated:
            raise TransportError(
                f"transport stdout exceeds {self.maximum_stdout_bytes} bytes")
        if stderr_truncated:
            raise TransportError(
                f"transport stderr exceeds {self.maximum_stderr_bytes} bytes")
        stdout_text = self._decode(stdout, "stdout", [])
        if return_code != 0:
            detail = f": {dump_json(stderr_text)}" if stderr_text else ""
            raise TransportError(
                f"trusted transport exited with status {return_code}{detail}")
        result = load_json(stdout_text, "transport.stdout", self.maximum_stdout_bytes)
        if not isinstance(result, dict):
            raise TransportError("transport stdout must contain one JSON object")
        return TransportResponse(result, sent, received, stderr_text)

    @staticmethod
    def _decode(data: bytearray, stream: str, truncated: list) -> str:
        if truncated:
            raise TransportError(f"transport {stream} exceeded its byte limit")
        try:
            return bytes(data).decode("utf-8", errors="strict").strip()
        except UnicodeDecodeError as error:
            raise TransportError(f"transport {stream} is not valid UTF-8") from error

    @staticmethod
    def _terminate(process: subprocess.Popen) -> None:
        try:
            if os.name == "nt":
                process.kill()
            else:
                os.killpg(process.pid, 9)
        except (OSError, ProcessLookupError):
            try:
                process.kill()
            except OSError:
                pass
