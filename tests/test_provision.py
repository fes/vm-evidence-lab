#!/usr/bin/env python3

import hashlib
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("vm_lab", ROOT / "provision/lab.py")
assert SPEC is not None and SPEC.loader is not None
vm_lab = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(vm_lab)


def profile_fixture(root: Path) -> dict:
    guests = {}
    for guest_id, version in (
        ("windows", "11.0.26100"),
        ("linux", "24.04.3"),
        ("macos", "15.7.2"),
    ):
        suffix = ".ipsw" if guest_id == "macos" else ".iso"
        image = root / f"{guest_id}{suffix}"
        image.write_bytes(f"{guest_id} installer".encode("utf-8"))
        digest = hashlib.sha256(image.read_bytes()).hexdigest()
        guests[guest_id] = {
            "name": f"test-{guest_id}",
            "architecture": "arm64",
            "os_version": version,
            "installer_path": str(image),
            "installer_sha256": digest,
            "baseline_id": f"test-{guest_id}-v1",
            "cpu_count": 4,
            "memory_mib": 4096,
            "disk_gib": 80,
        }
    return {
        "schema_version": 1,
        "profile_id": "test",
        "host": {
            "architecture": "arm64",
            "model_identifier": "Mac14,12",
            "macos_version": "15.7.2",
            "macos_build": "24G99",
            "parallels_version": "Parallels Desktop 20",
            "storage_root": str(root),
            "minimum_free_bytes": 1,
        },
        "guests": guests,
    }


class ProvisionProfileTests(unittest.TestCase):
    def test_profile_requires_three_arm64_guests_and_host_matching_macos_major(self):
        with tempfile.TemporaryDirectory() as temporary:
            profile = profile_fixture(Path(temporary))
            vm_lab.validate_profile(profile)
            profile["guests"]["macos"]["os_version"] = "14.7.2"
            with self.assertRaisesRegex(vm_lab.ProfileError, "same major"):
                vm_lab.validate_profile(profile)

    def test_profile_rejects_duplicate_names_and_unpinned_installer(self):
        with tempfile.TemporaryDirectory() as temporary:
            profile = profile_fixture(Path(temporary))
            profile["guests"]["linux"]["name"] = profile["guests"]["windows"]["name"]
            with self.assertRaisesRegex(vm_lab.ProfileError, "duplicate VM name"):
                vm_lab.validate_profile(profile)
            profile["guests"]["linux"]["name"] = "test-linux"
            profile["guests"]["linux"]["installer_sha256"] = "0" * 64
            with self.assertRaisesRegex(vm_lab.ProfileError, "pinned SHA-256"):
                vm_lab.validate_profile(profile)

    def test_installer_hash_mismatch_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            profile = profile_fixture(Path(temporary))
            profile["guests"]["linux"]["installer_sha256"] = "a" * 64
            with self.assertRaisesRegex(vm_lab.ProfileError, "SHA-256 mismatch"):
                vm_lab.verify_installer(profile["guests"]["linux"])

    def test_macos_creation_refuses_existing_vm(self):
        with tempfile.TemporaryDirectory() as temporary:
            profile = profile_fixture(Path(temporary))
            with (
                patch.object(vm_lab, "verify_host"),
                patch.object(vm_lab, "list_vms", return_value={"test-macos": {}}),
                patch.object(vm_lab, "run_text") as run_text,
            ):
                with self.assertRaisesRegex(vm_lab.ProfileError, "refusing to overwrite"):
                    vm_lab.create_macos(profile)
            run_text.assert_not_called()

    def test_inventory_rejects_ambiguous_vm_names(self):
        inventory = json.dumps([
            {"name": "test-linux", "status": "stopped"},
            {"name": "test-linux", "status": "stopped"},
        ])
        with patch.object(vm_lab, "run_text", return_value=inventory):
            with self.assertRaisesRegex(vm_lab.ProfileError, "duplicate VM name"):
                vm_lab.list_vms()

    def test_macos_creation_uses_pinned_plain_disk_and_resources(self):
        with tempfile.TemporaryDirectory() as temporary:
            profile = profile_fixture(Path(temporary))
            with (
                patch.object(vm_lab, "verify_host"),
                patch.object(vm_lab, "list_vms", return_value={}),
                patch.object(vm_lab, "run_text") as run_text,
            ):
                vm_lab.create_macos(profile)
            commands = [call.args[0] for call in run_text.call_args_list]
            self.assertEqual(commands[0][1:6], [
                "create",
                "test-macos",
                "-o",
                "macos",
                "--no-hdd",
            ])
            self.assertEqual(commands[0][-2:], ["--dst", temporary])
            self.assertEqual(commands[1][-2:], ["--size", "81920"])
            self.assertIn("--cpus", commands[2])
            self.assertIn("--shared-clipboard", commands[2])

    def test_hardening_refuses_running_vm_before_changing_any_vm(self):
        with tempfile.TemporaryDirectory() as temporary:
            profile = profile_fixture(Path(temporary))
            inventory = {
                guest["name"]: {"status": "stopped"}
                for guest in profile["guests"].values()
            }
            inventory["test-linux"]["status"] = "running"
            with (
                patch.object(vm_lab, "verify_host"),
                patch.object(vm_lab, "list_vms", return_value=inventory),
                patch.object(vm_lab, "set_guest_resources") as set_resources,
            ):
                with self.assertRaisesRegex(vm_lab.ProfileError, "must be stopped"):
                    vm_lab.harden(profile)
            set_resources.assert_not_called()

    def test_hardening_pins_all_three_only_after_prechecking_stopped_state(self):
        with tempfile.TemporaryDirectory() as temporary:
            profile = profile_fixture(Path(temporary))
            inventory = {
                guest["name"]: {"status": "stopped"}
                for guest in profile["guests"].values()
            }
            with (
                patch.object(vm_lab, "verify_host"),
                patch.object(vm_lab, "list_vms", return_value=inventory),
                patch.object(vm_lab, "set_guest_resources") as set_resources,
            ):
                vm_lab.harden(profile)
            self.assertEqual(
                [call.args[1] for call in set_resources.call_args_list],
                ["windows", "linux", "macos"],
            )

    def test_profile_example_is_a_template_not_a_host_ready_configuration(self):
        profile = json.loads(
            (ROOT / "provision/profiles/m2-pro.example.json").read_text(
                encoding="utf-8"
            )
        )
        with self.assertRaisesRegex(vm_lab.ProfileError, "must be pinned"):
            vm_lab.validate_profile(profile)


if __name__ == "__main__":
    unittest.main()
