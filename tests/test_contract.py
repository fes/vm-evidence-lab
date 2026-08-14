import json
import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCHEMAS = ROOT / "schemas"


class ContractTests(unittest.TestCase):
    def test_all_schemas_are_valid_json(self) -> None:
        for path in sorted(SCHEMAS.glob("*.json")):
            with self.subTest(path=path.name):
                document = json.loads(path.read_text(encoding="utf-8"))
                self.assertEqual(document["$schema"], "https://json-schema.org/draft/2020-12/schema")
                self.assertEqual(document["type"], "object")

    def test_external_contracts_reject_unknown_root_fields(self) -> None:
        for name in ("host-request-v1.json", "job-v1.json", "result-v1.json", "manifest-v1.json"):
            with self.subTest(schema=name):
                document = json.loads((SCHEMAS / name).read_text(encoding="utf-8"))
                self.assertFalse(document["additionalProperties"])

    def test_job_contract_has_no_execution_authority_fields(self) -> None:
        document = json.loads((SCHEMAS / "job-v1.json").read_text(encoding="utf-8"))
        properties = set(document["properties"])
        forbidden = {
            "command",
            "arguments",
            "environment",
            "executable",
            "output",
            "path",
            "working_directory",
        }
        self.assertTrue(properties.isdisjoint(forbidden))

    def test_host_request_cannot_select_local_repository_paths(self) -> None:
        document = json.loads((SCHEMAS / "host-request-v1.json").read_text(encoding="utf-8"))
        source_properties = document["properties"]["sources"]["items"]["properties"]
        self.assertEqual(set(source_properties), {"id", "sha"})

    def test_job_and_result_pin_the_installed_adapter(self) -> None:
        for name in ("job-v1.json", "result-v1.json", "manifest-v1.json"):
            with self.subTest(schema=name):
                document = json.loads((SCHEMAS / name).read_text(encoding="utf-8"))
                self.assertIn("adapter_sha", document["required"])
                self.assertIn("adapter_sha", document["properties"])

    def test_full_sha_pattern_rejects_abbreviations(self) -> None:
        document = json.loads((SCHEMAS / "job-v1.json").read_text(encoding="utf-8"))
        pattern = document["properties"]["sources"]["items"]["properties"]["sha"]["pattern"]
        self.assertIsNone(re.fullmatch(pattern, "abc1234"))
        self.assertIsNotNone(re.fullmatch(pattern, "a" * 40))
        self.assertIsNotNone(re.fullmatch(pattern, "b" * 64))

    def test_manifest_records_infrastructure_and_adapter_versions(self) -> None:
        document = json.loads((SCHEMAS / "manifest-v1.json").read_text(encoding="utf-8"))
        required = set(document["required"])
        self.assertTrue(
            {
                "controller_sha",
                "relay_sha",
                "adapter_id",
                "adapter_sha",
                "adapter_schema_version",
                "requested_sources",
            }.issubset(required)
        )


if __name__ == "__main__":
    unittest.main()
