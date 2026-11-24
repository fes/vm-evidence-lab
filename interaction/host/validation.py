import datetime
import json
import math
import re
from typing import Any, Dict, Iterable, List, Mapping, Optional, Set

from .errors import ValidationError


SAFE_ID = re.compile(r"^[A-Za-z0-9._-]{1,128}$")
ARTIFACT_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
PLATFORMS = {"windows", "linux", "macos"}
GRANTS = {
    "observe",
    "keyboard",
    "pointer",
    "wheel",
    "accessibility",
    "screenshot",
    "video",
    "clipboard-sentinel",
    "fixture-files",
}
OPERATIONS = {
    "capabilities",
    "observe",
    "focus",
    "key",
    "text",
    "move",
    "click",
    "double-click",
    "drag",
    "scroll",
    "wait",
    "screenshot",
    "clipboard-set-sentinel",
    "video-start",
    "video-stop",
}
BASE_FIELDS = {"schema_version", "session_id", "sequence", "operation"}
OPERATION_FIELDS = {
    "capabilities": set(),
    "observe": {"cursor"},
    "focus": set(),
    "key": {"key"},
    "text": {"text"},
    "move": {"point"},
    "click": {"point", "button", "duration_ms"},
    "double-click": {"point", "button", "duration_ms"},
    "drag": {"point", "destination", "button", "duration_ms"},
    "scroll": {"scroll", "point"},
    "wait": {"wait"},
    "screenshot": {"artifact"},
    "clipboard-set-sentinel": {"clipboard"},
    "video-start": {"video"},
    "video-stop": set(),
}
REQUIRED_OPERATION_FIELDS = {
    "key": {"key"},
    "text": {"text"},
    "move": {"point"},
    "click": {"point", "button"},
    "double-click": {"point", "button"},
    "drag": {"point", "destination"},
    "scroll": {"scroll"},
    "wait": {"wait"},
    "screenshot": {"artifact"},
    "clipboard-set-sentinel": {"clipboard"},
    "video-start": {"video"},
}
OPERATION_GRANTS = {
    "observe": ("observe",),
    "focus": ("accessibility",),
    "key": ("keyboard",),
    "text": ("keyboard",),
    "move": ("pointer",),
    "click": ("pointer",),
    "double-click": ("pointer",),
    "drag": ("pointer",),
    "scroll": ("wheel",),
    "wait": ("observe",),
    "screenshot": ("screenshot",),
    "clipboard-set-sentinel": ("clipboard-sentinel",),
    "video-start": ("video",),
    "video-stop": ("video",),
}
MAX_JSON_BYTES = 4 * 1024 * 1024


def _fail(path: str, message: str) -> None:
    raise ValidationError(path, message)


def _object(value: Any, path: str) -> Mapping[str, Any]:
    if not isinstance(value, dict):
        _fail(path, "expected object")
    return value


def _keys(
    value: Mapping[str, Any],
    path: str,
    required: Iterable[str],
    optional: Iterable[str] = (),
) -> None:
    required_set = set(required)
    allowed = required_set | set(optional)
    actual = set(value)
    missing = required_set - actual
    unknown = actual - allowed
    if missing:
        _fail(path, "missing field(s): " + ", ".join(sorted(missing)))
    if unknown:
        _fail(path, "unknown field(s): " + ", ".join(sorted(unknown)))


def _integer(value: Any, path: str, minimum: Optional[int] = None,
             maximum: Optional[int] = None) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        _fail(path, "expected integer")
    if minimum is not None and value < minimum:
        _fail(path, f"must be at least {minimum}")
    if maximum is not None and value > maximum:
        _fail(path, f"must be at most {maximum}")
    return value


def _number(value: Any, path: str, minimum: Optional[float] = None,
            maximum: Optional[float] = None) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        _fail(path, "expected number")
    number = float(value)
    if not math.isfinite(number):
        _fail(path, "must be finite")
    if minimum is not None and number < minimum:
        _fail(path, f"must be at least {minimum}")
    if maximum is not None and number > maximum:
        _fail(path, f"must be at most {maximum}")
    return number


def _string(value: Any, path: str, minimum: int = 0,
            maximum: Optional[int] = None) -> str:
    if not isinstance(value, str):
        _fail(path, "expected string")
    if len(value) < minimum:
        _fail(path, f"must contain at least {minimum} character(s)")
    if maximum is not None and len(value) > maximum:
        _fail(path, f"must contain at most {maximum} character(s)")
    return value


def _boolean(value: Any, path: str) -> bool:
    if not isinstance(value, bool):
        _fail(path, "expected boolean")
    return value


def _enum(value: Any, path: str, values: Iterable[str]) -> str:
    if not isinstance(value, str) or value not in values:
        _fail(path, "must be one of: " + ", ".join(sorted(values)))
    return value


def _unique_array(value: Any, path: str) -> List[Any]:
    if not isinstance(value, list):
        _fail(path, "expected array")
    seen = set()
    for index, item in enumerate(value):
        marker = json.dumps(item, sort_keys=True, separators=(",", ":"))
        if marker in seen:
            _fail(f"{path}[{index}]", "duplicate item")
        seen.add(marker)
    return value


def validate_safe_id(value: Any, path: str = "id", maximum: int = 128) -> str:
    text = _string(value, path, 1, maximum)
    if SAFE_ID.fullmatch(text) is None or text in {".", ".."}:
        _fail(path, "contains an unsafe identifier")
    return text


def validate_artifact_name(value: Any, path: str = "artifact.name") -> str:
    text = _string(value, path, 1, 128)
    if ARTIFACT_ID.fullmatch(text) is None or text in {".", ".."}:
        _fail(path, "contains an unsafe artifact name")
    return text


def load_json(data: Any, path: str = "json", maximum_bytes: int = MAX_JSON_BYTES) -> Any:
    if isinstance(data, str):
        raw = data.encode("utf-8")
    elif isinstance(data, bytes):
        raw = data
    else:
        _fail(path, "expected JSON text")
    if len(raw) > maximum_bytes:
        _fail(path, f"exceeds {maximum_bytes} bytes")

    def pairs(items: List[tuple]) -> Dict[str, Any]:
        result: Dict[str, Any] = {}
        for key, value in items:
            if key in result:
                _fail(path, f"duplicate object member: {key}")
            result[key] = value
        return result

    def constant(token: str) -> Any:
        _fail(path, f"invalid JSON number: {token}")

    try:
        text = raw.decode("utf-8")
        return json.loads(text, object_pairs_hook=pairs, parse_constant=constant)
    except ValidationError:
        raise
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        _fail(path, f"invalid JSON: {error}")


def dump_json(value: Any) -> str:
    _json_value(value, "json")
    try:
        return json.dumps(value, ensure_ascii=True, allow_nan=False,
                          sort_keys=True, separators=(",", ":"))
    except (TypeError, ValueError) as error:
        raise ValidationError("json", f"cannot encode JSON: {error}") from error


def _json_value(value: Any, path: str) -> None:
    if value is None or isinstance(value, (str, bool, int)):
        return
    if isinstance(value, float):
        if not math.isfinite(value):
            _fail(path, "must be finite")
        return
    if isinstance(value, list):
        for index, item in enumerate(value):
            _json_value(item, f"{path}[{index}]")
        return
    if isinstance(value, dict):
        for key, item in value.items():
            if not isinstance(key, str):
                _fail(path, "object member names must be strings")
            _json_value(item, f"{path}.{key}")
        return
    _fail(path, f"is not a JSON value: {type(value).__name__}")


def validate_session(value: Any) -> Dict[str, Any]:
    _json_value(value, "session")
    root = _object(value, "session")
    _keys(root, "session", (
        "schema_version", "session_id", "platform", "run_id", "target",
        "grants", "limits",
    ))
    if type(root["schema_version"]) is not int or root["schema_version"] != 1:
        _fail("session.schema_version", "must equal 1")
    validate_safe_id(root["session_id"], "session.session_id")
    _enum(root["platform"], "session.platform", PLATFORMS)
    validate_safe_id(root["run_id"], "session.run_id")
    target = _object(root["target"], "session.target")
    _keys(target, "session.target", ("pid",), ("window_index",))
    _integer(target["pid"], "session.target.pid", 1)
    if "window_index" in target:
        _integer(target["window_index"], "session.target.window_index", 0, 31)
    grants = _unique_array(root["grants"], "session.grants")
    for index, grant in enumerate(grants):
        _enum(grant, f"session.grants[{index}]", GRANTS)
    limits = _object(root["limits"], "session.limits")
    _keys(limits, "session.limits", (
        "maximum_commands", "command_timeout_ms", "maximum_artifact_bytes",
        "maximum_video_seconds",
    ))
    _integer(limits["maximum_commands"], "session.limits.maximum_commands", 1, 10000)
    _integer(limits["command_timeout_ms"], "session.limits.command_timeout_ms",
             100, 120000)
    _integer(limits["maximum_artifact_bytes"],
             "session.limits.maximum_artifact_bytes", 1, 1073741824)
    _integer(limits["maximum_video_seconds"],
             "session.limits.maximum_video_seconds", 1, 300)
    return root


def _point(value: Any, path: str) -> None:
    point = _object(value, path)
    _keys(point, path, ("x", "y"), ("coordinate_space",))
    _number(point["x"], path + ".x", 0, 100000)
    _number(point["y"], path + ".y", 0, 100000)
    if "coordinate_space" in point:
        _enum(point["coordinate_space"], path + ".coordinate_space",
              ("physical-screen", "target-relative"))


def _validate_operation_fields(command: Mapping[str, Any]) -> None:
    operation = command["operation"]
    payload_fields = set(command) - BASE_FIELDS
    allowed = OPERATION_FIELDS[operation]
    irrelevant = payload_fields - allowed
    if irrelevant:
        _fail("command", f"operation {operation} has irrelevant field(s): "
              + ", ".join(sorted(irrelevant)))
    missing = REQUIRED_OPERATION_FIELDS.get(operation, set()) - payload_fields
    if missing:
        _fail("command", f"operation {operation} is missing field(s): "
              + ", ".join(sorted(missing)))


def validate_command(value: Any, session: Optional[Mapping[str, Any]] = None) -> Dict[str, Any]:
    _json_value(value, "command")
    root = _object(value, "command")
    operation = root.get("operation")
    if operation is not None:
        _enum(operation, "command.operation", OPERATIONS)
    all_operation_fields = set().union(*OPERATION_FIELDS.values())
    _keys(root, "command", BASE_FIELDS, all_operation_fields)
    if type(root["schema_version"]) is not int or root["schema_version"] != 1:
        _fail("command.schema_version", "must equal 1")
    validate_safe_id(root["session_id"], "command.session_id")
    _integer(root["sequence"], "command.sequence", 1)
    _enum(root["operation"], "command.operation", OPERATIONS)
    _validate_operation_fields(root)
    # Only the existing macOS driver implements point-directed wheel events.
    # Never infer this platform capability during sessionless validation.
    if operation == "scroll" and "point" in root and (
            session is None or session.get("platform") != "macos"):
        _fail("command.point", "scroll point requires an explicit macos session")
    if "cursor" in root:
        if type(root["cursor"]) is not bool:
            _fail("command.cursor", "must be boolean")
        if session is None or session.get("platform") not in {"linux", "macos"}:
            _fail("command.cursor", "requires explicit linux or macos session")
    if "key" in root:
        key = _object(root["key"], "command.key")
        _keys(key, "command.key", ("name",), ("character", "modifiers", "phase"))
        _enum(key["name"], "command.key.name", (
            "escape", "tab", "return", "space", "backspace", "delete", "home",
            "end", "page-up", "page-down", "up", "down", "left", "right",
            "a-z", "0-9",
        ))
        if "character" in key:
            _string(key["character"], "command.key.character", 1, 1)
        if key["name"] in {"a-z", "0-9"}:
            character = key.get("character")
            valid_character = (
                isinstance(character, str)
                and len(character) == 1
                and (
                    (key["name"] == "a-z" and character.isascii()
                     and character.lower() in "abcdefghijklmnopqrstuvwxyz")
                    or (key["name"] == "0-9" and character in "0123456789")
                )
            )
            if not valid_character:
                _fail("command.key.character",
                      "must match the declared key name")
        elif "character" in key:
            _fail("command.key.character",
                  "is only valid for a-z or 0-9 key names")
        modifiers = key.get("modifiers", [])
        for index, modifier in enumerate(_unique_array(modifiers, "command.key.modifiers")):
            _enum(modifier, f"command.key.modifiers[{index}]",
                  ("shift", "control", "alt", "command", "meta"))
        if "phase" in key:
            _enum(key["phase"], "command.key.phase", ("press", "down", "up"))
    if "text" in root:
        text = _object(root["text"], "command.text")
        _keys(text, "command.text", ("value",), ("sensitive",))
        _string(text["value"], "command.text.value", 0, 4096)
        if "sensitive" in text:
            _boolean(text["sensitive"], "command.text.sensitive")
    for field in ("point", "destination"):
        if field in root:
            _point(root[field], "command." + field)
    if "button" in root:
        _enum(root["button"], "command.button", ("primary", "secondary"))
    if "duration_ms" in root:
        _integer(root["duration_ms"], "command.duration_ms", 0, 120000)
    if "scroll" in root:
        scroll = _object(root["scroll"], "command.scroll")
        _keys(scroll, "command.scroll", ("delta_x", "delta_y", "unit"))
        _number(scroll["delta_x"], "command.scroll.delta_x", -100000, 100000)
        _number(scroll["delta_y"], "command.scroll.delta_y", -100000, 100000)
        _enum(scroll["unit"], "command.scroll.unit", ("line", "pixel"))
    if "wait" in root:
        wait = _object(root["wait"], "command.wait")
        _keys(wait, "command.wait", ("condition", "timeout_ms"), ("stable_for_ms",))
        _enum(wait["condition"], "command.wait.condition", (
            "foreground-target", "target-visible", "target-geometry-stable",
            "frame-stable",
        ))
        _integer(wait["timeout_ms"], "command.wait.timeout_ms", 1, 120000)
        if "stable_for_ms" in wait:
            _integer(wait["stable_for_ms"], "command.wait.stable_for_ms", 0, 30000)
    if "artifact" in root:
        artifact = _object(root["artifact"], "command.artifact")
        _keys(artifact, "command.artifact", ("name",), ("scope",))
        validate_artifact_name(artifact["name"])
        if "scope" in artifact:
            _enum(artifact["scope"], "command.artifact.scope",
                  ("target-window", "guest-display"))
    if "clipboard" in root:
        clipboard = _object(root["clipboard"], "command.clipboard")
        _keys(clipboard, "command.clipboard", ("value",), ("verify",))
        sentinel = _string(clipboard["value"], "command.clipboard.value", 1, 277)
        if re.fullmatch(
                r"vm-evidence-sentinel:[A-Za-z0-9._-]{1,256}", sentinel) is None:
            _fail("command.clipboard.value",
                  "must contain a bounded vm-evidence-sentinel token")
        if "verify" in clipboard:
            _boolean(clipboard["verify"], "command.clipboard.verify")
    if "video" in root:
        video = _object(root["video"], "command.video")
        _keys(video, "command.video", ("artifact_name", "maximum_seconds"),
              ("frames_per_second",))
        validate_artifact_name(video["artifact_name"], "command.video.artifact_name")
        _integer(video["maximum_seconds"], "command.video.maximum_seconds", 1, 300)
        if "frames_per_second" in video:
            _integer(video["frames_per_second"], "command.video.frames_per_second", 1, 30)
    if session is not None:
        if root["session_id"] != session["session_id"]:
            _fail("command.session_id", "does not match the active session")
        required_grants = OPERATION_GRANTS.get(root["operation"], ())
        missing_grants = set(required_grants) - set(session["grants"])
        if missing_grants:
            _fail("command.operation", "operation is not granted: "
                  + ", ".join(sorted(missing_grants)))
        limit = session["limits"]
        if root["sequence"] > limit["maximum_commands"]:
            _fail("command.sequence", "exceeds session maximum_commands")
        if "wait" in root and root["wait"]["timeout_ms"] > limit["command_timeout_ms"]:
            _fail("command.wait.timeout_ms", "exceeds session command timeout")
        duration = root.get("duration_ms", 0)
        input_budget = duration * (2 if root["operation"] == "double-click" else 1)
        input_budget += 80 if root["operation"] == "double-click" else 0
        if input_budget > limit["command_timeout_ms"]:
            _fail("command.duration_ms", "exceeds session command timeout")
        if "video" in root and root["video"]["maximum_seconds"] > limit["maximum_video_seconds"]:
            _fail("command.video.maximum_seconds", "exceeds session video limit")
        if root["operation"] in {"focus"} and "accessibility" not in session["grants"]:
            _fail("command.operation", "accessibility is not granted")
    return root


def _date_time(value: Any, path: str) -> datetime.datetime:
    text = _string(value, path, 1)
    if not re.fullmatch(
            r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})",
            text):
        _fail(path, "expected RFC 3339 date-time")
    try:
        parsed = datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        _fail(path, "invalid date-time")
    if parsed.tzinfo is None:
        _fail(path, "date-time requires an offset")
    return parsed


def validate_result(value: Any, session: Optional[Mapping[str, Any]] = None,
                    command: Optional[Mapping[str, Any]] = None) -> Dict[str, Any]:
    _json_value(value, "result")
    root = _object(value, "result")
    _keys(root, "result", (
        "schema_version", "session_id", "sequence", "status", "operation",
        "started_at", "completed_at", "duration_ms", "diagnostics", "artifacts",
    ), ("observation",))
    if type(root["schema_version"]) is not int or root["schema_version"] != 1:
        _fail("result.schema_version", "must equal 1")
    validate_safe_id(root["session_id"], "result.session_id")
    _integer(root["sequence"], "result.sequence", 1)
    _enum(root["status"], "result.status", ("pass", "fail", "unsupported"))
    _string(root["operation"], "result.operation")
    started = _date_time(root["started_at"], "result.started_at")
    completed = _date_time(root["completed_at"], "result.completed_at")
    if completed < started:
        _fail("result.completed_at", "precedes started_at")
    duration = _integer(root["duration_ms"], "result.duration_ms", 0)
    elapsed = (completed - started).total_seconds() * 1000
    if abs(elapsed - duration) > 1000:
        _fail("result.duration_ms", "does not match the timestamp interval")
    diagnostics = _object(root["diagnostics"], "result.diagnostics")
    _keys(diagnostics, "result.diagnostics", (
        "driver", "platform", "target", "message",
    ), ("native_error", "host_guest_clock_skew_ms", "tcc", "metrics"))
    _string(diagnostics["driver"], "result.diagnostics.driver", 0, 256)
    _enum(diagnostics["platform"], "result.diagnostics.platform", PLATFORMS)
    target = _object(diagnostics["target"], "result.diagnostics.target")
    _keys(target, "result.diagnostics.target", (
        "pid", "window_found", "foreground", "visible",
    ), ("window_id", "geometry"))
    _integer(target["pid"], "result.diagnostics.target.pid", 0)
    for field in ("window_found", "foreground", "visible"):
        _boolean(target[field], "result.diagnostics.target." + field)
    if "window_id" in target:
        _string(target["window_id"], "result.diagnostics.target.window_id", 0, 128)
    if "geometry" in target:
        geometry = _object(target["geometry"], "result.diagnostics.target.geometry")
        _keys(geometry, "result.diagnostics.target.geometry",
              ("x", "y", "width", "height"), ("scale_factor",))
        _number(geometry["x"], "result.diagnostics.target.geometry.x")
        _number(geometry["y"], "result.diagnostics.target.geometry.y")
        _number(geometry["width"], "result.diagnostics.target.geometry.width", 0)
        _number(geometry["height"], "result.diagnostics.target.geometry.height", 0)
        if "scale_factor" in geometry:
            _number(geometry["scale_factor"],
                    "result.diagnostics.target.geometry.scale_factor", 0)
    _string(diagnostics["message"], "result.diagnostics.message", 0, 4096)
    if "native_error" in diagnostics and diagnostics["native_error"] is not None:
        _string(diagnostics["native_error"], "result.diagnostics.native_error", 0, 4096)
    if "host_guest_clock_skew_ms" in diagnostics and \
            diagnostics["host_guest_clock_skew_ms"] is not None:
        _number(diagnostics["host_guest_clock_skew_ms"],
                "result.diagnostics.host_guest_clock_skew_ms")
    if "tcc" in diagnostics:
        tcc = _object(diagnostics["tcc"], "result.diagnostics.tcc")
        _keys(tcc, "result.diagnostics.tcc", (), ("accessibility", "screen_recording"))
        for field in tcc:
            _boolean(tcc[field], "result.diagnostics.tcc." + field)
    if "metrics" in diagnostics:
        _object(diagnostics["metrics"], "result.diagnostics.metrics")
    if "observation" in root:
        _object(root["observation"], "result.observation")
    artifacts = root["artifacts"]
    if not isinstance(artifacts, list):
        _fail("result.artifacts", "expected array")
    if len(artifacts) > 256:
        _fail("result.artifacts", "must contain at most 256 items")
    names: Set[str] = set()
    for index, item in enumerate(artifacts):
        base = f"result.artifacts[{index}]"
        artifact = _object(item, base)
        _keys(artifact, base, ("name", "path", "size", "sha256"))
        name = validate_artifact_name(artifact["name"], base + ".name")
        if name in names:
            _fail(base + ".name", "duplicate artifact name")
        names.add(name)
        _string(artifact["path"], base + ".path", 1)
        _integer(artifact["size"], base + ".size", 0)
        digest = _string(artifact["sha256"], base + ".sha256")
        if SHA256.fullmatch(digest) is None:
            _fail(base + ".sha256", "expected lowercase SHA-256")
    if session is not None:
        if root["session_id"] != session["session_id"]:
            _fail("result.session_id", "does not match the active session")
        if diagnostics["platform"] != session["platform"]:
            _fail("result.diagnostics.platform", "does not match the active session")
        if diagnostics["target"]["pid"] not in {0, session["target"]["pid"]}:
            _fail("result.diagnostics.target.pid", "does not match the session target")
        for artifact in artifacts:
            if artifact["size"] > session["limits"]["maximum_artifact_bytes"]:
                _fail("result.artifacts", "artifact exceeds session size limit")
    if command is not None:
        if root["sequence"] != command["sequence"]:
            _fail("result.sequence", "does not match the command")
        if root["operation"] != command["operation"]:
            _fail("result.operation", "does not match the command")
    return root
