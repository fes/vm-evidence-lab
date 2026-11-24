import json
import ctypes
import importlib.util
import time
import os
from unittest import mock
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from interaction.host import (  # noqa: E402
    InteractionError,
    SequenceError,
    TrustedSubprocessTransport,
    ValidationError,
    collect_artifacts,
    dry_run_controller,
    validate_command,
    validate_result,
    validate_session,
)


def session(**overrides):
    value = {
        "schema_version": 1,
        "session_id": "test-session",
        "platform": "linux",
        "run_id": "test-run",
        "target": {"pid": 1234},
        "grants": ["observe", "accessibility", "keyboard", "pointer", "wheel",
                   "screenshot"],
        "limits": {
            "maximum_commands": 20,
            "command_timeout_ms": 2000,
            "maximum_artifact_bytes": 4096,
            "maximum_video_seconds": 5,
        },
    }
    value.update(overrides)
    return value


def command(sequence=1, operation="capabilities", **fields):
    return {
        "schema_version": 1,
        "session_id": "test-session",
        "sequence": sequence,
        "operation": operation,
        **fields,
    }


def result(request, *, status="pass"):
    now = "2026-11-18T08:00:00Z"
    return {
        "schema_version": 1,
        "session_id": request["session_id"],
        "sequence": request["sequence"],
        "status": status,
        "operation": request["operation"],
        "started_at": now,
        "completed_at": now,
        "duration_ms": 0,
        "diagnostics": {
            "driver": "test-driver/1",
            "platform": "linux",
            "target": {
                "pid": 1234,
                "window_found": True,
                "foreground": True,
                "visible": True,
            },
            "message": "offline test",
            "native_error": None,
        },
        "artifacts": [],
    }


class InteractionValidationTests(unittest.TestCase):
    def test_windows_optional_cursor_metadata_uses_existing_observe_contract(self):
        owned = validate_session(session(platform="windows", grants=["observe"]))
        request = command(operation="observe")
        validate_command(request, owned)
        for cursor in (
            {"available": True, "shape": "size_we", "x": 10, "y": 20,
             "native_error_code": None},
            {"available": False, "shape": "unknown", "native_error_code": 5},
            {"available": False, "shape": "unknown", "native_error_code": None},
        ):
            document = result(request)
            document["diagnostics"]["platform"] = "windows"
            document["observation"] = {"window_id": "0x2", "cursor": cursor}
            validate_result(document, owned, request)
            self.assertEqual(document["status"], "pass")
        with self.assertRaises(ValidationError):
            validate_command(command(operation="move", point={"x": 10, "y": 20}), owned)

    def test_scroll_is_bounded_wheel_operation(self):
        request = command(
            operation="scroll",
            scroll={"delta_x": 0, "delta_y": -3, "unit": "line"},
        )
        self.assertEqual(validate_command(request, validate_session(session())), request)
        request["point"] = {"x": 10, "y": 20}
        with self.assertRaises(ValidationError):
            validate_command(request, validate_session(session()))

    def test_macos_scroll_accepts_bounded_point_with_only_existing_wheel_grant(self):
        for space in ("physical-screen", "target-relative"):
            request = command(operation="scroll", scroll={"delta_x": 0, "delta_y": -3, "unit": "line"},
                              point={"x": 10, "y": 20, "coordinate_space": space})
            owned = validate_session(session(platform="macos", grants=["wheel"]))
            self.assertEqual(validate_command(request, owned), request)
        for point in ({"x": -1, "y": 20}, {"x": 100001, "y": 20},
                      {"x": 10, "y": True}, {"x": 10, "y": 20, "coordinate_space": "unbounded"}):
            request["point"] = point
            with self.assertRaises(ValidationError):
                validate_command(request, owned)
        request["point"] = {"x": 10, "y": 20}
        with self.assertRaises(ValidationError):
            validate_command(request, validate_session(session(platform="macos", grants=["pointer"])))
        for field, payload in (("destination", {"x": 1, "y": 2}), ("button", "primary"), ("duration_ms", 5)):
            with self.assertRaises(ValidationError):
                validate_command({**request, field: payload}, owned)

    def test_scroll_point_requires_an_explicit_supported_platform_session(self):
        request = command(operation="scroll", scroll={"delta_x": 0, "delta_y": 1, "unit": "line"},
                          point={"x": 10, "y": 20})
        for platform in ("linux", "windows"):
            with self.assertRaises(ValidationError):
                validate_command(request, validate_session(session(platform=platform)))
        with self.assertRaises(ValidationError):
            validate_command(request)

    def test_operation_rejects_unrelated_fields(self):
        request = command(operation="observe", scroll={
            "delta_x": 0,
            "delta_y": 1,
            "unit": "line",
        })
        with self.assertRaises(ValidationError):
            validate_command(request, validate_session(session()))

    def test_focus_requires_accessibility_grant(self):
        reduced = session(grants=["observe"])
        request = command(operation="focus")
        with self.assertRaises(ValidationError):
            validate_command(request, validate_session(reduced))

    def test_character_key_requires_matching_payload(self):
        valid = command(operation="key", key={
            "name": "a-z",
            "character": "q",
        })
        validate_command(valid, validate_session(session()))
        invalid = command(operation="key", key={
            "name": "a-z",
            "character": "7",
        })
        with self.assertRaises(ValidationError):
            validate_command(invalid, validate_session(session()))

    def test_video_stop_has_no_payload(self):
        valid = command(operation="video-stop")
        with self.assertRaises(ValidationError):
            validate_command(valid, validate_session(session(grants=[])))
        validate_command(valid, validate_session(session(grants=["video"])))

    def test_result_matches_session_and_command(self):
        request = command(operation="scroll", scroll={
            "delta_x": 0, "delta_y": 1, "unit": "line",
        })
        document = result(request)
        validate_result(document, validate_session(session()), request)
        document["sequence"] = 2
        with self.assertRaises(ValidationError):
            validate_result(document, validate_session(session()), request)

    def test_clipboard_accepts_only_bounded_sentinels(self):
        with self.assertRaises(ValidationError):
            validate_command(command(
                operation="clipboard-set-sentinel",
                clipboard={"value": "arbitrary clipboard contents"},
            ), validate_session(session(grants=["clipboard-sentinel"])))
        validate_command(command(
            operation="clipboard-set-sentinel",
            clipboard={"value": "vm-evidence-sentinel:controlled-001"},
        ), validate_session(session(grants=["clipboard-sentinel"])))


class InteractionControllerTests(unittest.TestCase):
    def test_dry_run_enforces_grants_and_sequence(self):
        controller = dry_run_controller(session())
        controller.execute(command())
        with self.assertRaises(SequenceError):
            controller.execute(command())
        with self.assertRaises(ValidationError):
            controller.execute(command(
                2, "clipboard-set-sentinel",
                clipboard={"value": "vm-evidence-sentinel:test"},
            ))

    def test_dry_run_never_executes_transport(self):
        controller = dry_run_controller(session())
        response = controller.execute(command(operation="scroll", scroll={
            "delta_x": 0, "delta_y": -1, "unit": "line",
        }))
        self.assertEqual(len(controller.transport.commands), 1)
        self.assertIn("dry-run", response["diagnostics"]["message"])

    def test_macos_scroll_point_reaches_dry_run_transport_unchanged(self):
        controller = dry_run_controller(session(platform="macos", grants=["wheel"]))
        request = command(operation="scroll", scroll={"delta_x": 0, "delta_y": 1, "unit": "pixel"},
                          point={"x": 10, "y": 20, "coordinate_space": "target-relative"})
        response = controller.execute(request)
        self.assertEqual(controller.transport.commands, [request])
        self.assertEqual(response["diagnostics"]["platform"], "macos")
        self.assertIn("dry-run", response["diagnostics"]["message"])

    def test_actual_cli_scroll_point_uses_session_in_every_command_entry(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = pathlib.Path(folder)
            session_file = folder / "session.json"
            command_file = folder / "command.json"
            result_file = folder / "result.json"
            request = command(operation="scroll", scroll={"delta_x": 0, "delta_y": 1, "unit": "line"},
                              point={"x": 10, "y": 20})
            command_file.write_text(json.dumps(request), encoding="utf-8")
            for platform, grants, expected in (("macos", ["wheel"], 0), ("linux", ["wheel"], 2),
                                                ("windows", ["wheel"], 2), ("macos", ["pointer"], 2)):
                session_file.write_text(json.dumps(session(platform=platform, grants=grants)), encoding="utf-8")
                response = result(request)
                response["diagnostics"]["platform"] = platform
                result_file.write_text(json.dumps(response), encoding="utf-8")
                for mode in (["--validate-request"], ["--dry-run"], ["--validate-result", str(result_file)]):
                    with self.subTest(platform=platform, grants=grants, mode=mode):
                        completed = subprocess.run([sys.executable, str(ROOT / "host/interactive.py"),
                            "--session", str(session_file), "--command", str(command_file), *mode],
                            text=True, capture_output=True, timeout=5)
                        self.assertEqual(completed.returncode, expected, completed.stderr)

    def test_trusted_argv_transport_rejects_nonsuccess_and_timeout(self):
        executable = sys.executable
        failing = TrustedSubprocessTransport(
            [executable, "-c", "import sys; print('failure', file=sys.stderr); raise SystemExit(3)"]
        )
        with self.assertRaises(InteractionError):
            failing.exchange(command(), 2)
        hanging = TrustedSubprocessTransport(
            [executable, "-c", "import time; time.sleep(5)"]
        )
        with self.assertRaises(InteractionError):
            hanging.exchange(command(), 0.05)

    def test_controller_bounded_exec_terminates_process_group(self):
        completed = subprocess.run(
            [
                sys.executable, str(ROOT / "host/bounded_exec.py"),
                "--timeout-ms", "50", "--",
                sys.executable, "-c", "import time; time.sleep(5)",
            ],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=2,
            text=True,
        )
        self.assertEqual(completed.returncode, 124)
        self.assertIn("exceeded 50 ms", completed.stderr)

    def test_current_user_windows_driver_hides_only_its_own_console(self):
        controller = (ROOT / "host/controller.sh").read_text(encoding="utf-8")
        invocation = controller[controller.index('prlctl exec "$(vm_name "$platform")" --current-user \\\n                powershell.exe'):]
        invocation = invocation[:invocation.index('>"$host_result"')]
        self.assertIn("-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File", invocation)
        self.assertIn('"$root\\\\driver.ps1"', invocation)
        self.assertNotIn("Set-ExecutionPolicy", invocation)

    def test_shell_artifact_fields_preserve_windows_backslashes(self):
        controller = (ROOT / "host/controller.sh").read_text(encoding="utf-8")
        start = controller.index("    jq -r '.artifacts[] | @base64'")
        end = controller.index('        case "$platform" in', start)
        decoder = controller[start:end]
        # Execute the production transport decoder, without guest I/O.
        script = ('host_result=$1\n' + decoder +
                  "        printf '%s\\0%s\\0%s\\0%s\\0' "+
                  '\"$name\" \"$path\" \"$size\" \"$digest\"\n    done\n')
        artifact = {"name": "screen.png",
                    "path": r"C:\Users\evidence\private folder\screen.png",
                    "size": 123, "sha256": "a" * 64}
        with tempfile.TemporaryDirectory() as temporary:
            document = pathlib.Path(temporary) / "result.json"
            document.write_text(json.dumps({"artifacts": [artifact]}))
            result = subprocess.run(["sh", "-eu", "-c", script, "test", str(document)],
                                    check=True, capture_output=True)
        self.assertEqual(result.stdout.split(b"\0")[:-1],
                         [str(artifact[key]).encode() for key in
                          ("name", "path", "size", "sha256")])
        start = controller.index('        scp_path=$path')
        end = controller.index('        guest_scp_from', start)
        conversion = controller[start:end]
        script = 'platform=windows; path=$1\n' + conversion + 'printf \"%s\" \"$scp_path\"'
        result = subprocess.run(["sh", "-eu", "-c", script, "test", artifact["path"]],
                                check=True, capture_output=True)
        self.assertEqual(result.stdout.decode(), artifact["path"].replace("\\", "/"))


    def test_artifact_result_cannot_escape_root(self):
        request = command(operation="screenshot", artifact={"name": "screen.png"})
        with tempfile.TemporaryDirectory() as temporary:
            parent = pathlib.Path(temporary)
            root = parent / "artifacts"
            root.mkdir()
            outside = parent / "outside.png"
            outside.write_bytes(b"not-contained")
            document = result(request)
            document["artifacts"] = [{
                "name": "screen.png",
                "path": str(outside),
                "size": outside.stat().st_size,
                "sha256": "0" * 64,
            }]
            validate_result(document, validate_session(session()), request)
            with self.assertRaises(InteractionError):
                collect_artifacts(document, root, 4096)


class CursorObservationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location(
            "linux_cursor_driver", ROOT / "interaction/linux/driver.py")
        cls.driver = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.driver)

    def test_cursor_opt_in_is_boolean_observe_only_and_platform_bound(self):
        for value in (False, True):
            request = command(operation="observe", cursor=value)
            validate_command(request, session())
            self.driver.validate_command(request)
        for value in (1, "true", None):
            with self.assertRaises(ValidationError):
                validate_command(command(operation="observe", cursor=value), session())
            with self.assertRaises(self.driver.DriverError):
                self.driver.validate_command(command(operation="observe", cursor=value))
        for request, target in ((command(cursor=True), session()),
                                (command(operation="observe", cursor=True), session(platform="windows"))):
            with self.assertRaises(ValidationError):
                validate_command(request, target)
        with self.assertRaises(ValidationError):
            validate_command(command(operation="observe", cursor=True))

    def test_lp64_pixels_are_normalized_to_four_argb_bytes(self):
        pixels = (ctypes.c_ulong * 2)(0x12345678, ctypes.c_ulong(-1).value)
        image = self.driver.XFixesCursorImage(0, 0, 2, 1, 1, 0, 0, pixels)
        self.assertEqual(self.driver.cursor_argb(image), bytes.fromhex("12345678ffffffff"))
        # C unsigned-long ABI, not a uint32 pointer on 64-bit Linux.
        self.assertEqual(self.driver.XFixesCursorImage._fields_[-1][1]._type_, ctypes.c_ulong)

    def test_bounds_refuse_before_reading_any_pixel(self):
        image = self.driver.XFixesCursorImage()
        for w, h, x, y in ((0, 1, 0, 0), (129, 1, 0, 0),
                            (1, 129, 0, 0), (1, 1, 1, 0)):
            image.width, image.height, image.xhot, image.yhot = w, h, x, y
            with self.assertRaises(self.driver.DriverError):
                self.driver.cursor_argb(image)
        pixels = (ctypes.c_ulong * 16384)(0)
        image.width = image.height = 128
        image.xhot = image.yhot = 127
        image.pixels = pixels
        self.assertEqual(len(self.driver.cursor_argb(image)), 65536)

    def test_ownership_race_and_unavailable_api_never_return_image(self):
        binding = (1234, "123", (("width", 10),), (2, 3))
        sample = {"supported": True, "argb_base64": "private-cursor"}
        for changed in ((9999, binding[1], binding[2], binding[3]),
                        (binding[0], "other", binding[2], binding[3]),
                        (binding[0], binding[1], (("width", 11),), binding[3]),
                        (binding[0], binding[1], binding[2], (3, 3))):
            with mock.patch.object(self.driver, "cursor_binding", side_effect=[binding, changed]), \
                 mock.patch.object(self.driver, "bounded_cursor_sample", return_value=(sample, (2, 3))):
                result = self.driver.cursor_observation(object())
                self.assertFalse(result["supported"])
                self.assertNotIn("argb_base64", result)
        with mock.patch.object(self.driver, "cursor_binding", return_value=binding), \
             mock.patch.object(self.driver, "bounded_cursor_sample", side_effect=OSError("not installed")):
            self.assertEqual(self.driver.cursor_observation(object()),
                             {"supported": False, "reason": "cursor_api_unavailable"})
        with mock.patch.object(self.driver, "cursor_binding", side_effect=[binding, binding]), \
             mock.patch.object(self.driver, "bounded_cursor_sample", return_value=(sample, (2, 3))):
            self.assertEqual(self.driver.cursor_observation(object()), sample)

    def test_bounded_child_uses_remaining_deadline_and_is_reaped(self):
        with tempfile.TemporaryDirectory() as tmp:
            pidfile = pathlib.Path(tmp) / "child.pid"
            script = ("import os,time,pathlib;pathlib.Path(" + repr(str(pidfile)) +
                      ").write_text(str(os.getpid()));time.sleep(30)")
            previous = self.driver.COMMAND_DEADLINE
            self.driver.COMMAND_DEADLINE = time.monotonic() + 0.5
            try:
                with mock.patch.object(self.driver, "CURSOR_CHILD", script):
                    with self.assertRaises(self.driver.DriverError):
                        self.driver.bounded_cursor_sample()
                self.assertTrue(pidfile.exists(), "child must actually start")
                with self.assertRaises(ProcessLookupError):
                    os.kill(int(pidfile.read_text()), 0)
            finally:
                self.driver.COMMAND_DEADLINE = previous

    def test_child_result_cap_and_strict_finite_schema(self):
        for raw in (b"x" * 90001, b'{"unsupported":true}',
                    b'{"sample":{},"point":[0,0]}'):
            with mock.patch.object(self.driver, "run_command", return_value=raw):
                with self.assertRaises(self.driver.DriverError):
                    self.driver.bounded_cursor_sample()
        data = bytes.fromhex("ff123456")
        sample = {"supported": True, "name_hint": "unknown", "width": 1, "height": 1,
                  "hot_x": 0, "hot_y": 0, "pixel_format": "premultiplied-ARGB32-big-endian",
                  "argb_base64": " /xI0Vg==".strip(),
                  "sha256": __import__("hashlib").sha256(data).hexdigest()}
        raw = json.dumps({"sample": sample, "point": [2, 3]}).encode()
        with mock.patch.object(self.driver, "run_command", return_value=raw):
            self.assertEqual(self.driver.bounded_cursor_sample(), (sample, (2, 3)))

    def test_default_observation_does_not_touch_cursor_api(self):
        target = mock.Mock(window_id="123")
        with mock.patch.object(self.driver, "xdotool", return_value=b"title\n"), \
             mock.patch.object(self.driver, "cursor_observation") as cursor:
            self.assertEqual(self.driver.observe(target),
                             {"window_id": "123", "title": "title", "accessibility": None})
            cursor.assert_not_called()
            self.driver.observe(target, cursor=True)
            cursor.assert_called_once_with(target)


class DriverSelfTestTests(unittest.TestCase):
    def test_linux_driver_self_test_does_not_require_display(self):
        completed = subprocess.run(
            [sys.executable, str(ROOT / "interaction/linux/driver.py"), "--self-test"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        report = json.loads(completed.stdout)
        self.assertEqual(report["status"], "pass")
        self.assertFalse(report["display_touched"])

    def test_provider_and_controller_do_not_expose_generic_command(self):
        provider = (ROOT / "providers/parallels.sh").read_text(encoding="utf-8")
        controller = (ROOT / "host/controller.sh").read_text(encoding="utf-8")
        self.assertIn("provider_vm_running", provider)
        self.assertIn("interactive control never starts it", controller)
        self.assertIn("bounded_exec.py", controller)
        self.assertNotIn("interaction_exec_arbitrary", controller)


if __name__ == "__main__":
    unittest.main()
