#!/usr/bin/env python3
"""Regression tests for the read-only consumer fleet matrix renderer."""

from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
import unittest
from copy import deepcopy
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "render-consumer-fleet.py"
FLEET = ROOT / "consumer-fleet.json"


class ConsumerFleetTests(unittest.TestCase):
    def load(self) -> dict[str, object]:
        return json.loads(FLEET.read_text(encoding="utf-8"))

    def run_document(self, document: dict[str, object]) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fleet.json"
            path.write_text(json.dumps(document), encoding="utf-8")
            return subprocess.run(
                [sys.executable, str(SCRIPT), "--fleet", str(path), "--print"],
                cwd=ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

    def run_document_with_outputs(
        self, document: dict[str, object]
    ) -> tuple[subprocess.CompletedProcess[str], dict[str, str]]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "fleet.json"
            output = root / "github-output"
            path.write_text(json.dumps(document), encoding="utf-8")
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--fleet",
                    str(path),
                    "--github-output",
                    str(output),
                    "--print",
                ],
                cwd=ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            values: dict[str, str] = {}
            if output.exists():
                for line in output.read_text(encoding="utf-8").splitlines():
                    name, value = line.split("=", 1)
                    values[name] = value
            return result, values

    def in_repo_entry(self, document: dict[str, object]) -> dict[str, object]:
        consumers = document["consumers"]
        assert isinstance(consumers, list)
        for entry in consumers:
            if isinstance(entry, dict) and entry.get("verification") == "in-repo":
                return entry
        self.fail("fixture has no in-repo consumer")

    def test_repository_matrix_is_valid_and_has_unique_labels(self) -> None:
        result, outputs = self.run_document_with_outputs(self.load())
        self.assertEqual(result.returncode, 0, result.stderr)
        matrix = json.loads(result.stdout)
        entries = matrix["include"]
        self.assertGreaterEqual(len(entries), 21)
        self.assertEqual(len(entries), len({entry["label"] for entry in entries}))
        self.assertIn(
            "ORESoftware/k8s-cluster:remote/deployments/browser-mcp-rs/.cli-flags.toml",
            {entry["label"] for entry in entries},
        )
        self.assertIn(
            "ORESoftware/next-loggers.ts:.cli-flags.toml",
            {entry["label"] for entry in entries},
        )
        next_loggers = next(
            entry
            for entry in entries
            if entry["repository"] == "ORESoftware/next-loggers.ts"
        )
        self.assertEqual("next-loggers", next_loggers["command"])
        self.assertEqual("cli", next_loggers["kind"])
        self.assertEqual(len(entries), int(outputs["central_count"]))
        self.assertEqual(24, int(outputs["consumer_count"]))
        self.assertEqual(3, int(outputs["in_repo_count"]))

        central_repositories = {entry["repository"] for entry in entries}
        evidence = json.loads(outputs["in_repo_evidence"])
        self.assertEqual(
            {
                "ORESoftware/shared-auth-server.rs",
                "ORESoftware/sonusauris-app-proxy",
                "sagitta-stack/sagitta-mcp-server.rs",
            },
            {entry["repository"] for entry in evidence},
        )
        self.assertTrue(
            central_repositories.isdisjoint(
                {entry["repository"] for entry in evidence}
            )
        )
        for entry in evidence:
            self.assertEqual("in-repo", entry["verification"])
            self.assertTrue(entry["workflow"].startswith(".github/workflows/"))
            self.assertIn(f"/{entry['repository']}/pull/".casefold(), entry["evidence_pr"].casefold())
            self.assertRegex(entry["evidence_commit"], re.compile(r"^[0-9a-f]{40}$"))
        self.assertEqual(
            {
                "ORESoftware/shared-auth-server.rs": (
                    "https://github.com/ORESoftware/shared-auth-server.rs/pull/2",
                    "dd595eae1dcd089a01f6487444d9403dcaee608c",
                ),
                "ORESoftware/sonusauris-app-proxy": (
                    "https://github.com/ORESoftware/sonusauris-app-proxy/pull/1",
                    "6e5b1ffadfe77433e079a945fc3916a0b8631394",
                ),
                "sagitta-stack/sagitta-mcp-server.rs": (
                    "https://github.com/sagitta-stack/sagitta-mcp-server.rs/pull/11",
                    "1246562bafe47625c04b18c2e9ccdb14c6fb37bf",
                ),
            },
            {
                entry["repository"]: (
                    entry["evidence_pr"],
                    entry["evidence_commit"],
                )
                for entry in evidence
            },
        )

    def test_mutable_tooling_reference_is_rejected(self) -> None:
        document = self.load()
        document["tooling_ref"] = "main"
        result = self.run_document(document)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("full lowercase commit SHA", result.stderr)

    def test_duplicate_contract_is_rejected_case_insensitively(self) -> None:
        document = self.load()
        consumers = document["consumers"]
        assert isinstance(consumers, list)
        duplicate = deepcopy(consumers[0])
        assert isinstance(duplicate, dict)
        duplicate["repository"] = str(duplicate["repository"]).swapcase()
        consumers.insert(1, duplicate)
        result = self.run_document(document)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("duplicate consumer", result.stderr)

    def test_contract_path_cannot_escape_checkout(self) -> None:
        document = self.load()
        consumers = document["consumers"]
        assert isinstance(consumers, list)
        entry = consumers[0]
        assert isinstance(entry, dict)
        entry["contract"] = "../.cli-flags.toml"
        result = self.run_document(document)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsafe contract path", result.stderr)

    def test_unsorted_entries_are_rejected(self) -> None:
        document = self.load()
        consumers = document["consumers"]
        assert isinstance(consumers, list)
        consumers[0], consumers[1] = consumers[1], consumers[0]
        result = self.run_document(document)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must be sorted", result.stderr)

    def test_in_repo_consumer_requires_complete_evidence(self) -> None:
        document = self.load()
        entry = self.in_repo_entry(document)
        entry.pop("evidence_pr")
        result = self.run_document(document)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("evidence_pr", result.stderr)

    def test_in_repo_evidence_must_match_the_consumer_repository(self) -> None:
        document = self.load()
        entry = self.in_repo_entry(document)
        entry["evidence_pr"] = "https://github.com/flags-2-env/flags-2-env/pull/8"
        result = self.run_document(document)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match consumer", result.stderr)

    def test_in_repo_evidence_requires_an_immutable_commit(self) -> None:
        document = self.load()
        entry = self.in_repo_entry(document)
        entry["evidence_commit"] = "main"
        result = self.run_document(document)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("evidence_commit must be one full lowercase commit SHA", result.stderr)

    def test_in_repo_workflow_must_stay_under_github_workflows(self) -> None:
        document = self.load()
        entry = self.in_repo_entry(document)
        entry["workflow"] = "../flags2env.yml"
        result = self.run_document(document)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsafe workflow path", result.stderr)

    def test_unsupported_verification_mode_is_rejected(self) -> None:
        document = self.load()
        consumers = document["consumers"]
        assert isinstance(consumers, list)
        entry = consumers[0]
        assert isinstance(entry, dict)
        entry["verification"] = "external"
        result = self.run_document(document)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsupported verification mode", result.stderr)

    def test_explicit_central_verification_is_allowed_without_evidence(self) -> None:
        document = self.load()
        consumers = document["consumers"]
        assert isinstance(consumers, list)
        entry = consumers[0]
        assert isinstance(entry, dict)
        entry["verification"] = "central"
        result = self.run_document(document)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
