import json

from .controller import dry_run_controller
from .errors import SequenceError, ValidationError
from .transport import DryRunTransport
from .validation import load_json


def sample_session():
    return {
        "schema_version": 1,
        "session_id": "offline-session",
        "platform": "linux",
        "run_id": "offline-run",
        "target": {"pid": 42, "window_index": 0},
        "grants": ["observe", "wheel", "screenshot"],
        "limits": {
            "maximum_commands": 10,
            "command_timeout_ms": 1000,
            "maximum_artifact_bytes": 1024,
            "maximum_video_seconds": 5,
        },
    }


def command(sequence=1, operation="capabilities", **fields):
    return {
        "schema_version": 1,
        "session_id": "offline-session",
        "sequence": sequence,
        "operation": operation,
        **fields,
    }


def run() -> None:
    controller = dry_run_controller(sample_session())
    manifest_result = controller.execute(command())
    manifest = manifest_result["observation"]
    assert manifest["platform"] == "linux"
    assert any(item["operation"] == "scroll" and item["granted"]
               for item in manifest["operations"])
    assert any(item["operation"] == "key" and not item["granted"]
               for item in manifest["operations"])
    controller.execute(command(2, "scroll", scroll={
        "delta_x": 0,
        "delta_y": -3,
        "unit": "line",
    }))
    rejected = 0
    try:
        controller.execute(command(2, "capabilities"))
    except SequenceError:
        rejected += 1
    try:
        controller.execute(command(3, "scroll", point={"x": 1, "y": 2}))
    except ValidationError:
        rejected += 1
    try:
        controller.execute(command(4, "key", key={"name": "return"}))
    except ValidationError:
        rejected += 1
    try:
        load_json('{"schema_version":1,"schema_version":1}', "duplicate")
    except ValidationError:
        rejected += 1
    assert rejected == 4
    assert isinstance(controller.transport, DryRunTransport)
    json.dumps(manifest_result, allow_nan=False)
    print("interaction host self-check: ok")


if __name__ == "__main__":
    run()
