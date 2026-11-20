import datetime
import hashlib
import pathlib
import threading
from typing import Any, Dict, Mapping, Optional

from .errors import InteractionError, SequenceError
from .transport import DryRunTransport, Transport
from .validation import (
    OPERATIONS,
    OPERATION_GRANTS,
    validate_artifact_name,
    validate_result,
    validate_session,
    validate_command,
)


class InteractiveController:
    def __init__(
        self,
        session: Mapping[str, Any],
        transport: Transport,
        *,
        artifact_root: Optional[pathlib.Path] = None,
    ) -> None:
        self.session = validate_session(dict(session))
        self.transport = transport
        self.artifact_root = pathlib.Path(artifact_root) if artifact_root else None
        self.next_sequence = 1
        self._execution_lock = threading.Lock()

    def capability_manifest(self) -> Dict[str, Any]:
        grants = set(self.session["grants"])
        operations = []
        for operation in sorted(OPERATIONS):
            required = set(OPERATION_GRANTS.get(operation, ()))
            operations.append({
                "operation": operation,
                "granted": required.issubset(grants),
                "required_grants": sorted(required),
            })
        return {
            "schema_version": 1,
            "driver": "vm-evidence-interactive-controller",
            "platform": self.session["platform"],
            "session_id": self.session["session_id"],
            "run_id": self.session["run_id"],
            "limits": dict(self.session["limits"]),
            "capability_probe_required": True,
            "operations": operations,
        }

    def execute(self, command: Mapping[str, Any]) -> Dict[str, Any]:
        with self._execution_lock:
            return self._execute_locked(command)

    def _execute_locked(self, command: Mapping[str, Any]) -> Dict[str, Any]:
        request = validate_command(dict(command), self.session)
        if request["sequence"] != self.next_sequence:
            raise SequenceError(
                f"expected command sequence {self.next_sequence}, "
                f"received {request['sequence']}")
        self.next_sequence += 1
        if isinstance(self.transport, DryRunTransport) and \
                self.transport.capability_manifest is None:
            self.transport = DryRunTransport(
                self.capability_manifest(), self.session["platform"])
        timeout = self.session["limits"]["command_timeout_ms"] / 1000.0
        response = self.transport.exchange(request, timeout)
        result = validate_result(response.result, self.session, request)
        if result["diagnostics"].get("host_guest_clock_skew_ms") is None:
            result["diagnostics"]["host_guest_clock_skew_ms"] = (
                response_clock_skew_ms(response, result))
        result = validate_result(result, self.session, request)
        if self.artifact_root is not None:
            collect_artifacts(result, self.artifact_root,
                              self.session["limits"]["maximum_artifact_bytes"])
            result = validate_result(result, self.session, request)
        return result


def dry_run_controller(session: Mapping[str, Any]) -> InteractiveController:
    session_copy = dict(session)
    return InteractiveController(
        session_copy,
        DryRunTransport(platform=session_copy.get("platform", "linux")),
    )


def _safe_regular_file(root: pathlib.Path, reported_path: str) -> pathlib.Path:
    path = pathlib.Path(reported_path)
    if path.is_absolute():
        candidate = path
    else:
        candidate = root / path
    resolved_root = root.resolve(strict=True)
    try:
        resolved = candidate.resolve(strict=True)
        resolved.relative_to(resolved_root)
    except (OSError, ValueError) as error:
        raise InteractionError(
            f"artifact path escapes or is absent from artifact root: {reported_path}") from error
    if candidate.is_symlink() or resolved.is_symlink() or not resolved.is_file():
        raise InteractionError(f"artifact is not a regular file: {reported_path}")
    return resolved


def collect_artifacts(
    result: Dict[str, Any],
    artifact_root: pathlib.Path,
    maximum_bytes: int,
) -> Dict[str, Any]:
    root = pathlib.Path(artifact_root)
    total = 0
    for artifact in result["artifacts"]:
        validate_artifact_name(artifact["name"], "result.artifacts.name")
        path = _safe_regular_file(root, artifact["path"])
        digest = hashlib.sha256()
        size = 0
        with path.open("rb") as stream:
            while True:
                block = stream.read(1024 * 1024)
                if not block:
                    break
                size += len(block)
                if size > maximum_bytes or size + total > maximum_bytes:
                    raise InteractionError(
                        f"artifact exceeds session byte limit: {artifact['name']}")
                digest.update(block)
        total += size
        artifact["size"] = size
        artifact["sha256"] = digest.hexdigest()
    return result


def response_clock_skew_ms(response: Any, result: Mapping[str, Any]) -> float:
    import time

    host_received = datetime.datetime.now(datetime.timezone.utc).timestamp()
    monotonic_now = time.monotonic_ns()
    host_sent = host_received - (
        monotonic_now - response.sent_monotonic_ns) / 1e9
    host_received -= (monotonic_now - response.received_monotonic_ns) / 1e9
    guest_started = datetime.datetime.fromisoformat(
        result["started_at"].replace("Z", "+00:00")).timestamp()
    guest_completed = datetime.datetime.fromisoformat(
        result["completed_at"].replace("Z", "+00:00")).timestamp()
    return round((
        (guest_started - host_sent)
        + (guest_completed - host_received)
    ) * 500, 3)
