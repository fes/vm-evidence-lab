#!/usr/bin/env python3
"""Validate and provision a pinned, host-specific Parallels VM lab."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any


PLATFORMS = ("windows", "linux", "macos")
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
VERSION_PATTERN = re.compile(r"^[0-9]+(?:\.[0-9]+){1,3}$")


class ProfileError(Exception):
    """Raised when a profile or the local host does not meet its pins."""


def fail(message: str) -> None:
    raise ProfileError(message)


def load_profile(path: Path) -> dict[str, Any]:
    try:
        profile = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot read profile {path}: {error}")
    validate_profile(profile)
    return profile


def validate_profile(profile: Any) -> None:
    if not isinstance(profile, dict) or profile.get("schema_version") != 1:
        fail("profile must be an object with schema_version 1")
    profile_id = profile.get("profile_id")
    if not isinstance(profile_id, str) or not re.fullmatch(
        r"[a-z][a-z0-9-]{0,31}", profile_id
    ):
        fail("profile_id must be a lowercase identifier")

    host = profile.get("host")
    if not isinstance(host, dict):
        fail("host must be an object")
    if host.get("architecture") != "arm64":
        fail("Apple Silicon host architecture must be pinned as arm64")
    for field in (
        "model_identifier",
        "macos_version",
        "macos_build",
        "parallels_version",
        "storage_root",
    ):
        value = host.get(field)
        if not isinstance(value, str) or not value or value.startswith("REPLACE_"):
            fail(f"host.{field} must be pinned to an exact value")
    if not VERSION_PATTERN.fullmatch(host["macos_version"]):
        fail("host.macos_version must be an exact dotted version")
    if type(host.get("minimum_free_bytes")) is not int or host["minimum_free_bytes"] <= 0:
        fail("host.minimum_free_bytes must be a positive integer")

    guests = profile.get("guests")
    if not isinstance(guests, dict) or set(guests) != set(PLATFORMS):
        fail("guests must define exactly windows, linux, and macos")
    names: set[str] = set()
    for guest_id in PLATFORMS:
        guest = guests[guest_id]
        if not isinstance(guest, dict):
            fail(f"guests.{guest_id} must be an object")
        for field in ("name", "os_version", "installer_path", "baseline_id"):
            value = guest.get(field)
            if not isinstance(value, str) or not value or value.startswith("REPLACE_"):
                fail(f"guests.{guest_id}.{field} must be pinned")
        if not guest["name"].startswith(f"{profile_id}-"):
            fail(f"guests.{guest_id}.name must start with {profile_id}-")
        if guest["name"] in names:
            fail(f"duplicate VM name: {guest['name']}")
        names.add(guest["name"])
        if guest.get("architecture") != "arm64":
            fail(f"guests.{guest_id}.architecture must be arm64")
        expected_suffix = ".ipsw" if guest_id == "macos" else ".iso"
        if Path(guest["installer_path"]).suffix.lower() != expected_suffix:
            fail(f"guests.{guest_id}.installer_path must point to a {expected_suffix} file")
        digest = guest.get("installer_sha256")
        if (
            not isinstance(digest, str)
            or not SHA256_PATTERN.fullmatch(digest)
            or digest == "0" * 64
        ):
            fail(f"guests.{guest_id}.installer_sha256 must be a pinned SHA-256")
        for field, minimum, maximum in (
            ("cpu_count", 1, 32),
            ("memory_mib", 1024, 262144),
            ("disk_gib", 32, 4096),
        ):
            value = guest.get(field)
            if type(value) is not int or not minimum <= value <= maximum:
                fail(
                    f"guests.{guest_id}.{field} must be between {minimum} and {maximum}"
                )
    macos_version = guests["macos"]["os_version"]
    if not VERSION_PATTERN.fullmatch(macos_version):
        fail("guests.macos.os_version must be an exact dotted version")
    if macos_version.split(".", 1)[0] != host["macos_version"].split(".", 1)[0]:
        fail("macOS guest and host must use the same major version")


def run_text(arguments: list[str]) -> str:
    try:
        completed = subprocess.run(
            arguments,
            check=True,
            capture_output=True,
            text=True,
        )
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or error.stdout or "").strip()
        suffix = f": {detail}" if detail else ""
        fail(
            f"command failed ({' '.join(arguments)}), "
            f"exit status {error.returncode}{suffix}"
        )
    except OSError as error:
        fail(f"cannot run {' '.join(arguments)}: {error}")
    return completed.stdout.strip()


def actual_host() -> dict[str, str]:
    if sys.platform != "darwin":
        fail("host checks and VM operations must run on macOS")
    return {
        "architecture": platform.machine(),
        "model_identifier": run_text(["sysctl", "-n", "hw.model"]),
        "macos_version": run_text(["sw_vers", "-productVersion"]),
        "macos_build": run_text(["sw_vers", "-buildVersion"]),
        "parallels_version": run_text(["prlctl", "--version"]),
    }


def verify_host(profile: dict[str, Any]) -> None:
    actual = actual_host()
    expected = profile["host"]
    mismatches = [
        f"{field}: expected {expected[field]!r}, found {actual[field]!r}"
        for field in (
            "architecture",
            "model_identifier",
            "macos_version",
            "macos_build",
            "parallels_version",
        )
        if actual[field] != expected[field]
    ]
    if mismatches:
        fail("host does not match profile:\n  " + "\n  ".join(mismatches))
    storage_root = Path(expected["storage_root"]).expanduser()
    if not storage_root.is_dir() or not os.access(storage_root, os.W_OK):
        fail(f"storage_root must exist and be writable: {storage_root}")
    free_bytes = shutil.disk_usage(storage_root).free
    if free_bytes < expected["minimum_free_bytes"]:
        fail(
            f"insufficient free space at {storage_root}: "
            f"{free_bytes} < {expected['minimum_free_bytes']} bytes"
        )


def verify_installer(guest: dict[str, Any]) -> None:
    path = Path(guest["installer_path"]).expanduser()
    if not path.is_file():
        fail(f"installer does not exist: {path}")
    hasher = hashlib.sha256()
    try:
        with path.open("rb") as installer:
            for block in iter(lambda: installer.read(1024 * 1024), b""):
                hasher.update(block)
    except OSError as error:
        fail(f"cannot read installer {path}: {error}")
    digest = hasher.hexdigest()
    if digest != guest["installer_sha256"]:
        fail(f"installer SHA-256 mismatch: {path}")


def list_vms() -> dict[str, dict[str, Any]]:
    output = run_text(["prlctl", "list", "--all", "--json"])
    try:
        records = json.loads(output)
    except json.JSONDecodeError as error:
        fail(f"prlctl returned invalid VM JSON: {error}")
    if not isinstance(records, list):
        fail("prlctl VM inventory must be a JSON array")
    result: dict[str, dict[str, Any]] = {}
    for record in records:
        if not isinstance(record, dict) or not isinstance(record.get("name"), str):
            fail("prlctl returned a VM entry without a name")
        if record["name"] in result:
            fail(f"prlctl returned duplicate VM name: {record['name']}")
        result[record["name"]] = record
    return result


def verify_guest_inputs(profile: dict[str, Any], guest_ids: tuple[str, ...]) -> None:
    for guest_id in guest_ids:
        verify_installer(profile["guests"][guest_id])


def preflight(profile: dict[str, Any]) -> None:
    verify_host(profile)
    verify_guest_inputs(profile, PLATFORMS)
    inventory = list_vms()
    for guest_id in PLATFORMS:
        guest = profile["guests"][guest_id]
        existing = inventory.get(guest["name"])
        state = existing.get("status", "unknown") if existing else "not created"
        print(f"{guest_id}: {guest['name']} ({state}), baseline {guest['baseline_id']}")


def create_macos(profile: dict[str, Any]) -> None:
    verify_host(profile)
    guest = profile["guests"]["macos"]
    verify_installer(guest)
    inventory = list_vms()
    if guest["name"] in inventory:
        fail(f"refusing to overwrite existing VM: {guest['name']}")
    run_text(
        [
            "prlctl",
            "create",
            guest["name"],
            "-o",
            "macos",
            "--no-hdd",
            "--restore-image",
            str(Path(guest["installer_path"]).expanduser()),
            "--dst",
            str(Path(profile["host"]["storage_root"]).expanduser()),
        ]
    )
    run_text(
        [
            "prlctl",
            "set",
            guest["name"],
            "--device-add",
            "hdd",
            "--type",
            "plain",
            "--size",
            str(guest["disk_gib"] * 1024),
        ]
    )
    set_guest_resources(profile, "macos")
    print(f"Created {guest['name']}; start it in Parallels to complete macOS setup.")


def set_guest_resources(profile: dict[str, Any], guest_id: str) -> None:
    guest = profile["guests"][guest_id]
    run_text(
        [
            "prlctl",
            "set",
            guest["name"],
            "--cpus",
            str(guest["cpu_count"]),
            "--memsize",
            str(guest["memory_mib"]),
            "--shared-profile",
            "off",
            "--shared-clipboard",
            "off",
            "--shared-cloud",
            "off",
        ]
    )


def harden(profile: dict[str, Any]) -> None:
    verify_host(profile)
    inventory = list_vms()
    for guest_id in PLATFORMS:
        guest = profile["guests"][guest_id]
        record = inventory.get(guest["name"])
        if record is None:
            fail(f"VM does not exist: {guest['name']}")
        state = record.get("status")
        if state != "stopped":
            fail(f"VM must be stopped before hardening: {guest['name']} ({state})")
    for guest_id in PLATFORMS:
        set_guest_resources(profile, guest_id)
        print(f"Applied pinned resources and disabled sharing: {profile['guests'][guest_id]['name']}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "command",
        choices=("validate", "preflight", "create-macos", "harden"),
    )
    parser.add_argument("profile", type=Path)
    args = parser.parse_args()
    try:
        profile = load_profile(args.profile)
        if args.command == "validate":
            print(f"Profile structure is valid: {profile['profile_id']}")
        elif args.command == "preflight":
            preflight(profile)
        elif args.command == "create-macos":
            create_macos(profile)
        else:
            harden(profile)
    except ProfileError as error:
        print(f"provisioning: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
