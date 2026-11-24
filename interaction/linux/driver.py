#!/usr/bin/env python3
"""Restricted interaction-session driver for an X11 guest desktop."""

import argparse
import base64
import ctypes
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone


DRIVER = "vm-evidence-lab/interaction-linux-x11-v1"
PLATFORM = "linux"
IDENTIFIER = re.compile(r"^[A-Za-z0-9._-]{1,128}$")
ARTIFACT_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
OPERATIONS = {
    "capabilities", "observe", "focus", "key", "text", "move", "click",
    "double-click", "drag", "scroll", "wait", "screenshot",
    "clipboard-set-sentinel", "video-start", "video-stop",
}
GRANTS = {
    "observe", "keyboard", "pointer", "wheel", "accessibility",
    "screenshot", "video", "clipboard-sentinel", "fixture-files",
}
KEYS = {
    "escape": "Escape", "tab": "Tab", "return": "Return", "space": "space",
    "backspace": "BackSpace", "delete": "Delete", "home": "Home",
    "end": "End", "page-up": "Prior", "page-down": "Next", "up": "Up",
    "down": "Down", "left": "Left", "right": "Right",
}
COMMAND_DEADLINE = None
MODIFIERS = {
    "shift": "Shift_L", "control": "Control_L", "alt": "Alt_L",
    "command": "Super_L", "meta": "Super_L",
}


class DriverError(Exception):
    def __init__(self, message, status="fail", native_error=None):
        super().__init__(message)
        self.status = status
        self.native_error = native_error


def exact_keys(value, required, optional=()):
    if not isinstance(value, dict):
        raise DriverError("expected a JSON object")
    keys = set(value)
    if not set(required).issubset(keys) or not keys.issubset(set(required) | set(optional)):
        raise DriverError("object has missing or unknown properties")


def integer(value, low, high):
    return isinstance(value, int) and not isinstance(value, bool) and low <= value <= high


def number(value, low, high):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and low <= value <= high


def validate_session(value):
    exact_keys(value, ("schema_version", "session_id", "platform", "run_id", "target",
                       "grants", "limits"))
    if not integer(value["schema_version"], 1, 1):
        raise DriverError("unsupported session schema_version")
    for key in ("session_id", "run_id"):
        if not isinstance(value[key], str) or not IDENTIFIER.fullmatch(value[key]):
            raise DriverError("invalid " + key)
    if value["platform"] != PLATFORM:
        raise DriverError("session platform is not linux", "unsupported")
    target = value["target"]
    exact_keys(target, ("pid",), ("window_index",))
    if not integer(target["pid"], 1, 2147483647):
        raise DriverError("target.pid is invalid")
    if "window_index" in target and not integer(target["window_index"], 0, 31):
        raise DriverError("target.window_index is invalid")
    grants = value["grants"]
    if not isinstance(grants, list) or not all(isinstance(x, str) and x in GRANTS for x in grants):
        raise DriverError("grants contains an unknown value")
    if len(grants) != len(set(grants)):
        raise DriverError("grants contains a duplicate")
    limits = value["limits"]
    exact_keys(limits, ("maximum_commands", "command_timeout_ms",
                        "maximum_artifact_bytes", "maximum_video_seconds"))
    checks = {
        "maximum_commands": (1, 10000), "command_timeout_ms": (100, 120000),
        "maximum_artifact_bytes": (1, 1073741824), "maximum_video_seconds": (1, 300),
    }
    if any(not integer(limits[key], *bounds) for key, bounds in checks.items()):
        raise DriverError("limits are invalid")


def validate_point(value):
    exact_keys(value, ("x", "y"), ("coordinate_space",))
    if not number(value["x"], 0, 100000) or not number(value["y"], 0, 100000):
        raise DriverError("point coordinates are invalid")
    if value.get("coordinate_space", "physical-screen") not in (
            "physical-screen", "target-relative"):
        raise DriverError("point coordinate_space is invalid")


def validate_command(value):
    exact_keys(value, ("schema_version", "session_id", "sequence", "operation"),
               ("key", "text", "point", "destination", "button", "duration_ms", "scroll",
                "wait", "artifact", "clipboard", "video", "cursor"))
    if not integer(value["schema_version"], 1, 1):
        raise DriverError("unsupported command schema_version")
    if not isinstance(value["session_id"], str) or not IDENTIFIER.fullmatch(value["session_id"]):
        raise DriverError("invalid command session_id")
    if not integer(value["sequence"], 1, 2**31 - 1):
        raise DriverError("invalid command sequence")
    op = value["operation"]
    if op not in OPERATIONS:
        raise DriverError("unknown operation")
    expected = {
        "capabilities": (), "observe": (), "focus": (), "key": ("key",), "text": ("text",),
        "move": ("point",), "click": ("point",), "double-click": ("point",),
        "drag": ("point", "destination"), "scroll": ("scroll",),
        "wait": ("wait",), "screenshot": ("artifact",),
        "clipboard-set-sentinel": ("clipboard",), "video-start": ("video",),
        "video-stop": (),
    }[op]
    if any(key not in value for key in expected):
        raise DriverError("operation is missing a required payload")
    allowed = {"schema_version", "session_id", "sequence", "operation"} | set(expected)
    if op == "observe":
        allowed.add("cursor")
    if "cursor" in value and type(value["cursor"]) is not bool:
        raise DriverError("cursor must be boolean")
    if op in ("click", "double-click", "drag"):
        allowed.update({"button", "duration_ms"})
    if not set(value).issubset(allowed):
        raise DriverError("operation contains unrelated properties")
    if "key" in value:
        key = value["key"]
        exact_keys(key, ("name",), ("character", "modifiers", "phase"))
        name = key["name"]
        valid_key = name in set(KEYS) | {"a-z", "0-9"}
        if not valid_key:
            raise DriverError("key.name is invalid")
        if name in ("a-z", "0-9"):
            character = key.get("character")
            if not isinstance(character, str) or len(character) != 1 or (
                    name == "a-z" and character.lower() not in "abcdefghijklmnopqrstuvwxyz") or (
                    name == "0-9" and character not in "0123456789"):
                raise DriverError("key.character does not match key.name")
        elif "character" in key:
            raise DriverError("key.character is only valid for a-z or 0-9")
        modifiers = key.get("modifiers", [])
        if not isinstance(modifiers, list) or any(x not in MODIFIERS for x in modifiers):
            raise DriverError("key.modifiers is invalid")
        if len(modifiers) != len(set(modifiers)):
            raise DriverError("key.modifiers contains a duplicate")
        if key.get("phase", "press") not in ("press", "down", "up"):
            raise DriverError("key.phase is invalid")
    if "text" in value:
        exact_keys(value["text"], ("value",), ("sensitive",))
        if not isinstance(value["text"]["value"], str) or len(value["text"]["value"]) > 4096:
            raise DriverError("text.value is invalid")
        if "sensitive" in value["text"] and not isinstance(value["text"]["sensitive"], bool):
            raise DriverError("text.sensitive is invalid")
    for point in ("point", "destination"):
        if point in value:
            validate_point(value[point])
    if "button" in value and value["button"] not in ("primary", "secondary"):
        raise DriverError("button is invalid")
    if "duration_ms" in value and not integer(value["duration_ms"], 0, 120000):
        raise DriverError("duration_ms is invalid")
    if "scroll" in value:
        scroll = value["scroll"]
        exact_keys(scroll, ("delta_x", "delta_y", "unit"))
        if not number(scroll["delta_x"], -100000, 100000) or not number(
                scroll["delta_y"], -100000, 100000) or scroll["unit"] not in ("line", "pixel"):
            raise DriverError("scroll payload is invalid")
    if "wait" in value:
        wait = value["wait"]
        exact_keys(wait, ("condition", "timeout_ms"), ("stable_for_ms",))
        if wait["condition"] not in ("foreground-target", "target-visible",
                                     "target-geometry-stable", "frame-stable"):
            raise DriverError("wait.condition is invalid")
        if not integer(wait["timeout_ms"], 1, 120000):
            raise DriverError("wait.timeout_ms is invalid")
        if "stable_for_ms" in wait and not integer(wait["stable_for_ms"], 0, 30000):
            raise DriverError("wait.stable_for_ms is invalid")
    if "artifact" in value:
        exact_keys(value["artifact"], ("name",), ("scope",))
        if not isinstance(value["artifact"]["name"], str) or not ARTIFACT_NAME.fullmatch(
                value["artifact"]["name"]):
            raise DriverError("artifact.name is invalid")
        if value["artifact"].get("scope", "target-window") not in (
                "target-window", "guest-display"):
            raise DriverError("artifact.scope is invalid")
    if "clipboard" in value:
        clip = value["clipboard"]
        exact_keys(clip, ("value",), ("verify",))
        if not isinstance(clip["value"], str) or not re.fullmatch(
                r"vm-evidence-sentinel:[A-Za-z0-9._-]{1,256}", clip["value"]):
            raise DriverError("clipboard.value is invalid")
        if "verify" in clip and not isinstance(clip["verify"], bool):
            raise DriverError("clipboard.verify is invalid")
    if "video" in value:
        video = value["video"]
        exact_keys(video, ("artifact_name", "maximum_seconds"), ("frames_per_second",))
        if not isinstance(video["artifact_name"], str) or not ARTIFACT_NAME.fullmatch(
                video["artifact_name"]):
            raise DriverError("video.artifact_name is invalid")
        if not integer(video["maximum_seconds"], 1, 300):
            raise DriverError("video.maximum_seconds is invalid")
        if "frames_per_second" in video and not integer(video["frames_per_second"], 1, 30):
            raise DriverError("video.frames_per_second is invalid")


def load_json(path, kind):
    path = Path(path)
    if path.is_symlink() or not path.is_file():
        raise DriverError("%s path is not a regular, non-symlink file" % kind)
    try:
        raw = path.read_text(encoding="utf-8")
        if len(raw.encode("utf-8")) > 1024 * 1024:
            raise DriverError("%s JSON exceeds 1 MiB" % kind)
        def unique_object(pairs):
            value = {}
            for key, item in pairs:
                if key in value:
                    raise DriverError("%s JSON contains a duplicate field: %s" % (kind, key))
                value[key] = item
            return value
        return json.loads(raw, object_pairs_hook=unique_object)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise DriverError("could not read %s JSON" % kind, native_error=str(exc))


def now():
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def run_command(arguments, timeout=15, data=None, okay=(0,)):
    global COMMAND_DEADLINE
    if COMMAND_DEADLINE is not None:
        remaining = COMMAND_DEADLINE - time.monotonic()
        if remaining <= 0:
            raise DriverError("command timeout expired")
        timeout = min(timeout, remaining)
    try:
        proc = subprocess.run(
            arguments, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=timeout, check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise DriverError("native command failed: " + arguments[0], native_error=str(exc))
    if proc.returncode not in okay:
        raise DriverError(
            "native command failed: " + arguments[0],
            native_error=proc.stderr.decode("utf-8", "replace").strip()[:1024],
        )
    return proc.stdout


def require_tool(name):
    path = shutil.which(name)
    if not path:
        raise DriverError("required X11 tool is unavailable: " + name, "unsupported")
    return path


def xdotool(*args, timeout=15):
    return run_command([require_tool("xdotool")] + list(args), timeout=timeout)


class X11Target:
    def __init__(self, session):
        self.pid = session["target"]["pid"]
        self.index = session["target"].get("window_index", 0)
        self.window_id = None
        self.geometry = None
        self.foreground = False
        self.visible = False

    @staticmethod
    def _check_wayland():
        if os.environ.get("WAYLAND_DISPLAY") and not os.environ.get("DISPLAY"):
            raise DriverError(
                "Wayland-only sessions are unsupported by the X11 driver", "unsupported")
        if not os.environ.get("DISPLAY"):
            raise DriverError("no X11 display is available", "unsupported")

    def candidates(self):
        self._check_wayland()
        require_tool("xdotool")
        require_tool("wmctrl")
        require_tool("xwininfo")
        raw = run_command(["wmctrl", "-lp"]).decode("utf-8", "replace")
        ids = []
        for line in raw.splitlines():
            columns = line.split(None, 3)
            if len(columns) >= 3 and columns[2] == str(self.pid):
                try:
                    ids.append(str(int(columns[0], 16)))
                except ValueError:
                    continue
        if not ids:
            raw = run_command(["xdotool", "search", "--pid", str(self.pid)],
                              okay=(0, 1)).decode("ascii", "ignore")
            ids = [x.strip() for x in raw.splitlines() if re.fullmatch(r"[0-9]+", x.strip())]
        return ids

    def refresh(self):
        self.window_id = None
        self.geometry = None
        self.foreground = False
        self.visible = False
        ids = self.candidates()
        if self.index >= len(ids):
            return self
        window_id = ids[self.index]
        try:
            info = run_command(["xwininfo", "-id", window_id]).decode(
                "utf-8", "replace")
            pid = xdotool("getwindowpid", window_id).decode("ascii", "ignore").strip()
            if pid != str(self.pid):
                return self
            values = {}
            for line in info.splitlines():
                match = re.match(r"\s*Absolute upper-left X:\s+(-?[0-9]+)", line)
                if match:
                    values["x"] = int(match.group(1))
                match = re.match(r"\s*Absolute upper-left Y:\s+(-?[0-9]+)", line)
                if match:
                    values["y"] = int(match.group(1))
                match = re.match(r"\s*Width:\s+([0-9]+)", line)
                if match:
                    values["width"] = int(match.group(1))
                match = re.match(r"\s*Height:\s+([0-9]+)", line)
                if match:
                    values["height"] = int(match.group(1))
                match = re.match(r"\s*Map State:\s+(.+)", line)
                if match:
                    self.visible = match.group(1).strip().lower() == "isviewable"
            if {"x", "y", "width", "height"} <= set(values):
                self.geometry = values
                self.window_id = window_id
                active = xdotool("getactivewindow").decode("ascii", "ignore").strip()
                self.foreground = active == window_id
        except DriverError:
            self.window_id = None
        return self

    def require(self, visible=False, foreground=False):
        self.refresh()
        if not self.window_id:
            raise DriverError("no top-level window belongs to session target PID")
        if visible and not self.visible:
            raise DriverError("target window is not visible")
        if foreground and not self.foreground:
            raise DriverError("target window is not foreground")

    def diagnostics(self):
        result = {
            "pid": self.pid,
            "window_found": bool(self.window_id),
            "foreground": bool(self.foreground),
            "visible": bool(self.visible),
        }
        if self.window_id:
            result["window_id"] = self.window_id
        if self.geometry:
            result["geometry"] = self.geometry
        return result

    def focus(self):
        self.require(visible=True)
        xdotool("windowactivate", "--sync", self.window_id)
        self.refresh()
        if not self.foreground:
            raise DriverError("could not make the owned target window foreground")

    def point(self, point):
        self.require(visible=True, foreground=True)
        x, y = point["x"], point["y"]
        if point.get("coordinate_space", "physical-screen") == "target-relative":
            x += self.geometry["x"]
            y += self.geometry["y"]
        if x < self.geometry["x"] or y < self.geometry["y"] or x >= (
                self.geometry["x"] + self.geometry["width"]) or y >= (
                self.geometry["y"] + self.geometry["height"]):
            raise DriverError("pointer coordinate is outside the owned target window")
        return str(int(round(x))), str(int(round(y)))

    def require_cursor_owned(self):
        self.require(visible=True, foreground=True)
        self.cursor_window_pid()

    def cursor_window_pid(self):
        output = xdotool("getmouselocation", "--shell").decode("utf-8", "replace")
        location = {}
        for line in output.splitlines():
            key, separator, value = line.partition("=")
            if separator:
                location[key] = value
        try:
            x, y = int(location["X"]), int(location["Y"])
        except (KeyError, ValueError):
            raise DriverError("could not obtain cursor position")
        try:
            pointer_window = int(location["WINDOW"])
        except (KeyError, ValueError):
            raise DriverError("could not identify the native window beneath the cursor")
        if self.window_id is None or not self.window_is_ancestor(
                pointer_window, int(self.window_id)):
            raise DriverError("native hit-test does not belong to the selected window")
        if x < self.geometry["x"] or y < self.geometry["y"] or x >= (
                self.geometry["x"] + self.geometry["width"]) or y >= (
                self.geometry["y"] + self.geometry["height"]):
            raise DriverError("cursor is outside the owned target window")
        return x, y

    def window_is_ancestor(self, child, expected):
        current = child
        for _ in range(32):
            if current == expected:
                return True
            tree = run_command(["xwininfo", "-id", str(current)]).decode(
                "utf-8", "replace")
            match = re.search(
                r"Parent window id:\s+(0x[0-9a-fA-F]+|[0-9]+)", tree)
            if not match:
                return False
            parent = int(match.group(1), 0)
            if parent == 0 or parent == current:
                return False
            current = parent
        return False

    def move_cursor_owned(self, x, y):
        xdotool("mousemove", "--sync", str(x), str(y))
        self.cursor_window_pid()


def operation_grant(operation):
    return {
        "observe": "observe", "focus": "accessibility", "key": "keyboard", "text": "keyboard",
        "move": "pointer", "click": "pointer", "double-click": "pointer", "drag": "pointer",
        "scroll": "wheel", "wait": "observe", "screenshot": "screenshot",
        "clipboard-set-sentinel": "clipboard-sentinel", "video-start": "video",
        "video-stop": "video",
    }.get(operation)


def accessibility_observation(target):
    try:
        import gi  # type: ignore
        gi.require_version("Atspi", "2.0")
        from gi.repository import Atspi  # type: ignore
        desktop = Atspi.get_desktop(0)
        matches = []
        for app_index in range(desktop.get_child_count()):
            app = desktop.get_child_at_index(app_index)
            try:
                process_id = app.get_process_id()
                if process_id == target.pid and app.get_name() and len(matches) < 64:
                    matches.append(app.get_name())
            except Exception:
                continue
        return {"at_spi_available": True, "target_applications": matches}
    except Exception as exc:
        return {"at_spi_available": False, "native_error": str(exc)[:512]}


# Xlib uses unsigned long for each pixel, including LP64; only low ARGB32 bits
# are image data. No cursor-name pointer is read (theme names are untrusted).
class XFixesCursorImage(ctypes.Structure):
    _fields_ = [("x", ctypes.c_short), ("y", ctypes.c_short),
                ("width", ctypes.c_ushort), ("height", ctypes.c_ushort),
                ("xhot", ctypes.c_ushort), ("yhot", ctypes.c_ushort),
                ("serial", ctypes.c_ulong),
                ("pixels", ctypes.POINTER(ctypes.c_ulong))]


def cursor_argb(image):
    w, h = image.width, image.height
    if not (1 <= w <= 128 and 1 <= h <= 128 and
            image.xhot < w and image.yhot < h and image.pixels):
        raise DriverError("cursor bounds unavailable", "unsupported")
    return b"".join((int(image.pixels[i]) & 0xffffffff).to_bytes(4, "big")
                    for i in range(w * h))


def xfixes_cursor():
    # Called only in the bounded child below: even XOpenDisplay may block.
    # Existing system libraries only; never install or capture a screen.
    x11 = ctypes.CDLL("libX11.so.6")
    fixes = ctypes.CDLL("libXfixes.so.3")
    x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x11.XOpenDisplay.restype = ctypes.c_void_p
    x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
    x11.XFree.argtypes = [ctypes.c_void_p]
    fixes.XFixesQueryExtension.argtypes = [ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int)]
    fixes.XFixesQueryVersion.argtypes = fixes.XFixesQueryExtension.argtypes
    fixes.XFixesGetCursorImage.argtypes = [ctypes.c_void_p]
    fixes.XFixesGetCursorImage.restype = ctypes.POINTER(XFixesCursorImage)
    display = x11.XOpenDisplay(None)
    if not display:
        raise DriverError("cursor display unavailable", "unsupported")
    try:
        a, b = ctypes.c_int(), ctypes.c_int()
        if not fixes.XFixesQueryExtension(display, ctypes.byref(a), ctypes.byref(b)):
            raise DriverError("cursor extension unavailable", "unsupported")
        major, minor = ctypes.c_int(1), ctypes.c_int(0)
        if not fixes.XFixesQueryVersion(display, ctypes.byref(major), ctypes.byref(minor)) or major.value < 1:
            raise DriverError("cursor version unavailable", "unsupported")
        pointer = fixes.XFixesGetCursorImage(display)
        if not pointer:
            raise DriverError("cursor image unavailable", "unsupported")
        try:
            image = pointer.contents
            data = cursor_argb(image)
            return {"supported": True, "name_hint": "unknown",
                    "width": image.width, "height": image.height,
                    "hot_x": image.xhot, "hot_y": image.yhot,
                    "pixel_format": "premultiplied-ARGB32-big-endian",
                    "argb_base64": base64.b64encode(data).decode("ascii"),
                    "sha256": hashlib.sha256(data).hexdigest()}, (image.x, image.y)
        finally:
            x11.XFree(ctypes.cast(pointer, ctypes.c_void_p))
    finally:
        x11.XCloseDisplay(display)


# Fixed child, not a new CLI operation or helper. run_command uses the remaining
# COMMAND_DEADLINE; subprocess.run kills and reaps this sole child on timeout.
# The child starts no descendants and emits at most one bounded JSON document.
CURSOR_CHILD = """
import importlib.util,json,sys
spec=importlib.util.spec_from_file_location('cursor_driver',sys.argv[1])
driver=importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)
try:
    sample,point=driver.xfixes_cursor()
    output=json.dumps({'sample':sample,'point':point},separators=(',',':')).encode()
    if len(output)>90000:
        raise ValueError()
except Exception:
    output=b'{"unsupported":true}'
sys.stdout.buffer.write(output)
"""


def bounded_cursor_sample():
    raw = run_command([sys.executable, "-c", CURSOR_CHILD,
                       str(Path(__file__).resolve())], timeout=2)
    if len(raw) > 90000:
        raise DriverError("cursor result exceeds bound", "unsupported")
    try:
        result = json.loads(raw)
        sample, point = result["sample"], result["point"]
        exact_keys(result, ("sample", "point"))
        exact_keys(sample, ("supported", "name_hint", "width", "height", "hot_x",
                            "hot_y", "pixel_format", "argb_base64", "sha256"))
        w, h = sample["width"], sample["height"]
        if not (sample["supported"] is True and sample["name_hint"] == "unknown" and
                integer(w, 1, 128) and integer(h, 1, 128) and
                integer(sample["hot_x"], 0, w - 1) and integer(sample["hot_y"], 0, h - 1) and
                sample["pixel_format"] == "premultiplied-ARGB32-big-endian" and
                isinstance(point, list) and len(point) == 2 and
                all(integer(v, -32768, 32767) for v in point) and
                isinstance(sample["argb_base64"], str) and
                len(sample["argb_base64"]) <= 87384):
            raise ValueError()
        data = base64.b64decode(sample["argb_base64"], validate=True)
        if len(data) != w * h * 4 or hashlib.sha256(data).hexdigest() != sample["sha256"]:
            raise ValueError()
        return sample, tuple(point)
    except (ValueError, KeyError, TypeError):
        raise DriverError("cursor result unavailable", "unsupported")


def cursor_binding(target):
    target.require_cursor_owned()
    point = target.cursor_window_pid()
    return target.pid, target.window_id, tuple(sorted(target.geometry.items())), point


def cursor_observation(target):
    try:
        before = cursor_binding(target)
        sample, point = bounded_cursor_sample()
        after = cursor_binding(target)
        if before != after or point != before[-1]:
            return {"supported": False, "reason": "ownership_changed"}
        return sample
    except DriverError:
        return {"supported": False, "reason": "ownership_or_cursor_unavailable"}
    except (OSError, AttributeError):
        return {"supported": False, "reason": "cursor_api_unavailable"}


def observe(target, accessibility=False, cursor=False):
    target.require()
    title = xdotool("getwindowname", target.window_id).decode("utf-8", "replace").rstrip("\n")
    result = {"window_id": target.window_id, "title": title, "accessibility": None}
    if accessibility:
        result["accessibility"] = accessibility_observation(target)
    if cursor:
        result["cursor"] = cursor_observation(target)
    return result


def screenshot_tool():
    for executable in ("import", "scrot"):
        path = shutil.which(executable)
        if path:
            return executable, path
    raise DriverError("no supported screenshot tool (import or scrot)", "unsupported")


def capture(target, output, scope, timeout, title=""):
    name, tool = screenshot_tool()
    output = Path(output)
    if name == "import":
        if scope == "target-window":
            arguments = [tool, "-window", target.window_id, str(output)]
        else:
            arguments = [tool, "-window", "root", str(output)]
    elif scope == "target-window":
        geometry = target.geometry
        selection = "{x},{y},{width},{height}".format(**geometry)
        arguments = [tool, "-a", selection, str(output)]
    else:
        arguments = [tool, str(output)]
    run_command(arguments, timeout=timeout)


def secure_artifact_path(root, logical_name):
    if not ARTIFACT_NAME.fullmatch(logical_name):
        raise DriverError("artifact name is invalid")
    root = Path(root).resolve()
    root.mkdir(parents=True, exist_ok=True)
    if not root.is_dir() or root.is_symlink():
        raise DriverError("artifact directory is not a safe directory")
    filename = logical_name if logical_name.lower().endswith(".png") else logical_name + ".png"
    final = root / filename
    if final.exists() and (final.is_symlink() or not final.is_file()):
        raise DriverError("artifact destination is unsafe")
    partial = root / ("." + filename + ".partial")
    if partial.exists() or final.exists():
        raise DriverError("artifact destination already exists")
    if final.parent.resolve() != root:
        raise DriverError("artifact path escapes the artifact directory")
    return final, partial


def screenshot(session, command, target, artifacts):
    target.require(visible=True)
    scope = command["artifact"].get("scope", "target-window")
    if scope == "target-window" and not target.window_id:
        raise DriverError("target window is unavailable")
    final, partial = secure_artifact_path(artifacts, command["artifact"]["name"])
    try:
        capture(target, partial, scope, session["limits"]["command_timeout_ms"] / 1000.0)
        size = partial.stat().st_size
        maximum = session["limits"]["maximum_artifact_bytes"]
        if size > maximum:
            raise DriverError("screenshot exceeds maximum_artifact_bytes")
        digest = file_digest(partial)
        os.replace(partial, final)
        return [{
            "name": command["artifact"]["name"],
            "path": str(final.resolve()),
            "size": size,
            "sha256": digest,
        }]
    finally:
        if partial.exists():
            partial.unlink()


def clipboard(command):
    value = command["clipboard"]["value"].encode("utf-8")
    if shutil.which("xclip"):
        run_command(["xclip", "-selection", "clipboard", "-in"], data=value)
        if command["clipboard"].get("verify", True):
            actual = run_command(["xclip", "-selection", "clipboard", "-out"])
    elif shutil.which("xsel"):
        run_command(["xsel", "--clipboard", "--input"], data=value)
        if command["clipboard"].get("verify", True):
            actual = run_command(["xsel", "--clipboard", "--output"])
    else:
        raise DriverError("no clipboard utility (xclip or xsel)", "unsupported")
    if command["clipboard"].get("verify", True) and actual != value:
        raise DriverError("clipboard sentinel verification failed")
    return {"verified": bool(command["clipboard"].get("verify", True))}


def release_modifiers():
    if not shutil.which("xdotool"):
        return
    subprocess.run(
        ["xdotool", "keyup", "--"] + list(dict.fromkeys(MODIFIERS.values())),
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
    )


def send_key(command):
    payload = command["key"]
    name = payload["name"]
    key = payload.get("character", KEYS.get(name))
    modifiers = [MODIFIERS[x] for x in payload.get("modifiers", [])]
    phase = payload.get("phase", "press")
    try:
        release_modifiers()
        for modifier in modifiers:
            xdotool("keydown", "--", modifier)
        if phase == "press":
            xdotool("key", "--", key)
        elif phase == "down":
            xdotool("keydown", "--", key)
        else:
            xdotool("keyup", "--", key)
    finally:
        for modifier in reversed(modifiers):
            xdotool("keyup", "--", modifier)
        release_modifiers()


def execute_pointer(operation, command, target):
    if operation != "drag":
        x, y = target.point(command["point"])
    button = {"primary": "1", "secondary": "3"}.get(command.get("button", "primary"))
    if operation == "move":
        target.move_cursor_owned(x, y)
    elif operation == "click":
        target.move_cursor_owned(x, y)
        xdotool("mousedown", button)
        try:
            if command.get("duration_ms", 0):
                time.sleep(command["duration_ms"] / 1000.0)
        finally:
            xdotool("mouseup", button)
    elif operation == "double-click":
        target.move_cursor_owned(x, y)
        for click_index in range(2):
            xdotool("mousedown", button)
            try:
                if command.get("duration_ms", 0):
                    time.sleep(command["duration_ms"] / 1000.0)
            finally:
                xdotool("mouseup", button)
            if click_index == 0:
                time.sleep(0.08)
    elif operation == "drag":
        sx, sy = target.point(command["point"])
        dx, dy = target.point(command["destination"])
        duration = command.get("duration_ms", 0)
        steps = max(1, min(100, math.ceil(duration / 20)))
        target.move_cursor_owned(sx, sy)
        xdotool("mousedown", button)
        try:
            for step in range(1, steps + 1):
                px = int(round(int(sx) + (int(dx) - int(sx)) * step / steps))
                py = int(round(int(sy) + (int(dy) - int(sy)) * step / steps))
                target.move_cursor_owned(str(px), str(py))
                if duration:
                    time.sleep(duration / steps / 1000.0)
        finally:
            xdotool("mouseup", button)


def perform_scroll(command):
    payload = command["scroll"]
    scale = 1.0 if payload["unit"] == "line" else 1.0 / 40.0
    actions = []
    vertical = int(payload["delta_y"] * scale)
    horizontal = int(payload["delta_x"] * scale)
    if vertical:
        actions.extend((["click", "--repeat", str(abs(vertical)), "--", "5" if vertical > 0 else "4"]))
    if horizontal:
        actions.extend((["click", "--repeat", str(abs(horizontal)), "--", "7" if horizontal > 0 else "6"]))
    for action in actions:
        xdotool(*action)


def file_digest(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as file:
        for block in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def wait_condition(session, command, target, artifacts):
    payload = command["wait"]
    condition = payload["condition"]
    deadline = time.monotonic() + min(
        payload["timeout_ms"], session["limits"]["command_timeout_ms"]) / 1000.0
    stable_ms = payload.get("stable_for_ms", 250)
    stable_since = None
    last = None
    if condition == "frame-stable":
        screenshot_tool()
    while time.monotonic() <= deadline:
        try:
            target.refresh()
            if condition == "foreground-target":
                ok = bool(target.window_id and target.foreground)
                current = True
            elif condition == "target-visible":
                ok = bool(target.window_id and target.visible)
                current = True
            elif condition == "target-geometry-stable":
                ok = bool(target.geometry)
                current = tuple(target.geometry[k] for k in ("x", "y", "width", "height"))
            else:
                if not target.window_id or not target.visible:
                    ok = False
                    current = None
                else:
                    with tempfile.NamedTemporaryFile(
                            prefix=".frame-", suffix=".png", dir=artifacts, delete=False) as file:
                        frame = Path(file.name)
                    frame.unlink()
                    try:
                        capture(target, frame, "target-window",
                                session["limits"]["command_timeout_ms"] / 1000.0)
                        current = file_digest(frame)
                        ok = True
                    finally:
                        if frame.exists():
                            frame.unlink()
            changed = current != last
            if condition in ("foreground-target", "target-visible") and ok:
                return {"condition": condition, "satisfied": True}
            if not ok:
                stable_since = None
            elif changed and last is not None:
                stable_since = time.monotonic()
            elif stable_since is None:
                stable_since = time.monotonic()
            last = current
            if ok and (time.monotonic() - stable_since) * 1000 >= stable_ms:
                return {"condition": condition, "satisfied": True}
        except DriverError:
            stable_since = None
        time.sleep(min(0.05, max(0.0, deadline - time.monotonic())))
    raise DriverError("wait condition timed out: " + condition)


def capabilities(session):
    X11Target._check_wayland()
    tools = {}
    for executable in ("xdotool", "wmctrl", "xwininfo", "import", "scrot", "xclip", "xsel"):
        tools[executable] = bool(shutil.which(executable))
    try:
        import gi  # type: ignore  # noqa: F401
        gi.require_version("Atspi", "2.0")
        from gi.repository import Atspi  # type: ignore  # noqa: F401
        at_spi = True
    except (ImportError, ValueError):
        at_spi = False
    return {
        "driver": DRIVER, "protocol": 1, "display": "x11",
        "tools": tools, "at_spi_available": at_spi,
        "operations": sorted(OPERATIONS - {"video-start", "video-stop"}),
        "unsupported": {"video": True, "wayland": True},
    }


def execute(session, command, artifact_directory, target):
    operation = command["operation"]
    if operation in ("video-start", "video-stop"):
        raise DriverError("video capture is explicitly unsupported", "unsupported")
    grant = operation_grant(operation)
    if grant and grant not in session["grants"]:
        raise DriverError("operation is not granted: " + grant)
    if operation == "capabilities":
        return capabilities(session), [], "capabilities enumerated"
    if operation == "observe":
        observation = observe(target, "accessibility" in session["grants"],
                              command.get("cursor", False))
    elif operation == "focus":
        target.focus()
        observation = {"focused": True}
    elif operation == "key":
        target.focus()
        try:
            send_key(command)
        finally:
            release_modifiers()
        observation = {"key": "sent"}
    elif operation == "text":
        target.focus()
        try:
            xdotool("type", "--clearmodifiers", "--file", "-", data=(
                command["text"]["value"].encode("utf-8")))
        finally:
            release_modifiers()
        observation = {"characters": len(command["text"]["value"])}
    elif operation in ("move", "click", "double-click", "drag"):
        target.focus()
        execute_pointer(operation, command, target)
        observation = {"pointer": operation}
    elif operation == "scroll":
        target.focus()
        target.refresh()
        target.require_cursor_owned()
        perform_scroll(command)
        observation = {"wheel": "sent"}
    elif operation == "wait":
        if command["wait"]["condition"] == "frame-stable" and "screenshot" not in session["grants"]:
            raise DriverError("frame-stable wait requires screenshot grant")
        observation = wait_condition(session, command, target, artifact_directory)
    elif operation == "screenshot":
        artifacts = screenshot(session, command, target, artifact_directory)
        return None, artifacts, "screenshot captured"
    elif operation == "clipboard-set-sentinel":
        observation = clipboard(command)
    else:
        raise DriverError("operation is unsupported", "unsupported")
    return observation, [], "operation completed"


def safe_result_path(path, artifact_directory):
    if path is None:
        return None
    result = Path(path)
    if result.is_symlink():
        raise DriverError("result path must not be a symlink")
    if result.exists() and not result.is_file():
        raise DriverError("result path is not a regular file")
    resolved = result.resolve()
    artifact = Path(artifact_directory).resolve()
    if resolved == artifact or artifact in resolved.parents:
        raise DriverError("result path must not be inside the artifact directory")
    return result


def write_result(path, result):
    encoded = json.dumps(result, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    if path is None:
        sys.stdout.write(encoded + "\n")
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    partial = path.with_name("." + path.name + ".partial")
    if partial.exists() or partial.is_symlink():
        raise DriverError("result temporary path already exists")
    try:
        with partial.open("x", encoding="utf-8") as file:
            file.write(encoded)
            file.write("\n")
        os.replace(partial, path)
    finally:
        if partial.exists():
            partial.unlink()


def failure_identity(session=None, command=None):
    session_id = session.get("session_id") if isinstance(session, dict) else "invalid"
    if not isinstance(session_id, str) or not IDENTIFIER.fullmatch(session_id):
        session_id = "invalid"
    sequence = command.get("sequence") if isinstance(command, dict) else 1
    operation = command.get("operation") if isinstance(command, dict) else "invalid"
    if not integer(sequence, 1, 2**31 - 1):
        sequence = 1
    if not isinstance(operation, str):
        operation = "invalid"
    return session_id, sequence, operation


def run(args):
    global COMMAND_DEADLINE
    started = now()
    started_clock = time.monotonic()
    session = command = None
    target = None
    artifacts = []
    native_error = None
    status = "fail"
    message = ""
    observation = None
    try:
        session = load_json(args.session, "session")
        validate_session(session)
        command = load_json(args.command, "command")
        validate_command(command)
        if command["session_id"] != session["session_id"]:
            raise DriverError("command session_id does not match session")
        if command["sequence"] > session["limits"]["maximum_commands"]:
            raise DriverError("command sequence exceeds maximum_commands")
        duration = command.get("duration_ms", 0)
        input_budget = duration * (2 if command["operation"] == "double-click" else 1)
        input_budget += 80 if command["operation"] == "double-click" else 0
        if input_budget > (
                session["limits"]["command_timeout_ms"]):
            raise DriverError("duration_ms exceeds command timeout")
        if args.operation is not None and command["operation"] != args.operation:
            raise DriverError("operation selector does not match command")
        if not Path(args.artifact_directory).exists():
            Path(args.artifact_directory).mkdir(parents=True)
        if Path(args.artifact_directory).is_symlink():
            raise DriverError("artifact directory must not be a symlink")
        COMMAND_DEADLINE = time.monotonic() + session["limits"]["command_timeout_ms"] / 1000
        target = X11Target(session)
        observation, artifacts, message = execute(
            session, command, args.artifact_directory, target)
        status = "pass"
        if command["operation"] != "capabilities":
            target.refresh()
    except DriverError as exc:
        message = str(exc)
        status = exc.status
        native_error = exc.native_error
    except Exception as exc:
        message = "unexpected driver failure"
        native_error = (type(exc).__name__ + ": " + str(exc))[:2048]
        status = "fail"
    finally:
        COMMAND_DEADLINE = None
    completed = now()
    session_id, sequence, operation = failure_identity(session, command)
    target_diagnostic = (
        target.diagnostics() if target is not None else {
            "pid": (
                session["target"]["pid"]
                if isinstance(session, dict)
                and isinstance(session.get("target"), dict)
                and integer(session["target"].get("pid"), 0, 2147483647)
                else 0
            ),
            "window_found": False, "foreground": False, "visible": False,
        })
    result = {
        "schema_version": 1, "session_id": session_id, "sequence": sequence,
        "status": status, "operation": operation, "started_at": started,
        "completed_at": completed,
        "duration_ms": max(0, int((time.monotonic() - started_clock) * 1000)),
        "diagnostics": {
            "driver": DRIVER, "platform": PLATFORM, "target": target_diagnostic,
            "message": message[:4096], "native_error": native_error,
            "host_guest_clock_skew_ms": None,
            "metrics": {"artifacts": len(artifacts)},
        },
        "artifacts": artifacts,
    }
    if observation is not None:
        result["observation"] = observation
    return write_result(safe_result_path(args.result, args.artifact_directory), result)


def self_test():
    session = {
        "schema_version": 1, "session_id": "self-test", "platform": "linux",
        "run_id": "self-test", "target": {"pid": 1},
        "grants": [], "limits": {
            "maximum_commands": 1, "command_timeout_ms": 100,
            "maximum_artifact_bytes": 1, "maximum_video_seconds": 1,
        },
    }
    command = {
        "schema_version": 1, "session_id": "self-test", "sequence": 1,
        "operation": "capabilities",
    }
    validate_session(session)
    validate_command(command)
    for invalid in ({"x": "../escape", "y": 1}, {"x": -1, "y": 0}):
        try:
            validate_point(invalid)
            raise RuntimeError("invalid point accepted")
        except DriverError:
            pass
    for name in ("good-name", "a.png"):
        if not ARTIFACT_NAME.fullmatch(name):
            raise RuntimeError("valid artifact rejected")
    if ARTIFACT_NAME.fullmatch("../escape"):
        raise RuntimeError("unsafe artifact accepted")
    print(json.dumps({
        "schema_version": 1, "driver": DRIVER, "status": "pass",
        "display_touched": False, "validated": ["session", "command", "paths"],
    }, sort_keys=True))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--session")
    parser.add_argument("--command")
    parser.add_argument("--artifact-directory")
    parser.add_argument("--result")
    parser.add_argument("--operation")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        if args.session or args.command or args.artifact_directory or args.result:
            parser.error("--self-test cannot be combined with request paths")
        self_test()
        return 0
    if not args.session or not args.command or not args.artifact_directory:
        parser.error("--session, --command, and --artifact-directory are required")
    try:
        run(args)
        return 0
    except DriverError:
        return 2


if __name__ == "__main__":
    sys.exit(main())
