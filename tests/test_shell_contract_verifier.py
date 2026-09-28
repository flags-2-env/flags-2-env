#!/usr/bin/env python3
"""Unit tests for terminal-wrapped flags2env help verification."""

from __future__ import annotations

import importlib.util
import unittest
from unittest.mock import patch
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts" / "verify-shell-contract.py"
SPEC = importlib.util.spec_from_file_location("verify_shell_contract", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ShellContractVerifierTests(unittest.TestCase):
    def test_wide_unicode_rows_are_read_at_terminal_cell_boundaries(self) -> None:
        output = """
| Option(s)                        | Env                  | Type       | Default        | Description                              |
| --secure                         | APP_SECURE           | bool       | -              | 認証が必要です 🔒 Values: true, false.   |
|                                  |                      |            |                | Negate with --no-secure.                 |
| --tenant                         | APP_TENANT           | string     | -              | 配置 tenant 設定                         |
"""
        descriptions = MODULE.table_column(output, {"Description"})
        self.assertIn("認証が必要です 🔒", descriptions)
        self.assertIn("配置 tenant 設定", descriptions)
        self.assertNotIn("APP_SECURE", descriptions)
        self.assertEqual(MODULE.terminal_cells("|e\u0301東京🔒|"), ["|", "e\u0301", "東", "", "京", "", "🔒", "", "|"])

    def test_missing_unicode_descriptions_do_not_pass_an_empty_token_check(self) -> None:
        for expected in ["認証が必要です", "مرحبا", "🔒", "€", "…"]:
            with self.subTest(expected=expected):
                self.assertFalse(MODULE.description_matches(expected, ""))
                self.assertFalse(MODULE.description_matches(expected, "unrelated"))
                self.assertTrue(MODULE.description_matches(expected, expected))

    def test_mixed_unicode_help_requires_every_word_and_symbol(self) -> None:
        for expected, incomplete in [
            ("配置 tenant 設定", "tenant"),
            ("🔒 restricted", "restricted"),
            ("Cost € 10", "Cost 10"),
        ]:
            with self.subTest(expected=expected):
                self.assertFalse(MODULE.description_matches(expected, incomplete))
                self.assertTrue(MODULE.description_matches(expected, expected))

    def test_unicode_words_preserve_casefold_and_canonical_accents(self) -> None:
        self.assertTrue(MODULE.description_matches("CAFÉ: accès", "cafe\u0301 accès"))
        self.assertTrue(MODULE.description_matches("認証：必要", "認証 必要"))
        self.assertFalse(MODULE.description_matches("認証：必要", "認証 不要"))

    def test_help_admission_rejects_a_missing_non_ascii_description(self) -> None:
        output = (
            "+------------+----------------------+\n"
            "| Option(s)  | Description          |\n"
            "+------------+----------------------+\n"
            "| --secure   | unrelated            |\n"
            "+------------+----------------------+\n"
        )
        root = {"flags": {"secure": {"help": "認証が必要です"}}}
        with patch.object(MODULE, "terminal_help", return_value=(0, output)):
            with self.assertRaisesRegex(RuntimeError, "omitted description"):
                MODULE.check_help(Path("unused-cli"), "fixture", Path(".cli-flags.toml"), root, {})

    def test_selected_columns_are_reconstructed_without_interleaving(self) -> None:
        output = """
+----------------------+------------+----------------+-----------------------+
| Option(s)            | Env        | Default        | Description           |
+----------------------+------------+----------------+-----------------------+
| --open-meteo-base-u  | API_URL    | https://api.op | Open-Meteo forecast   |
| rl                   |            | en-meteo.com/v | endpoint for          |
|                      |            | 1/forecast     | commercial use        |
+----------------------+------------+----------------+-----------------------+
"""
        options = MODULE.table_column(output, {"Option(s)"}).replace(" ", "")
        descriptions = MODULE.table_column(output, {"Description", "Details"})
        self.assertIn("--open-meteo-base-url", options)
        self.assertIn("Open-Meteo forecast endpoint for commercial use", descriptions)
        self.assertNotIn("en-meteo.com", descriptions)

    def test_compact_details_layout_reconstructs_wrapped_long_option(self) -> None:
        output = """
+------------------------+-------------------------------------------+
| Option(s)              | Details                                   |
+------------------------+-------------------------------------------+
| --agent-tasks-rds-data | env=AGENT_TASKS_RDS_DATABASE_URL;         |
| base-url               | type=string                               |
+------------------------+-------------------------------------------+
"""
        options = MODULE.table_column(output, {"Option(s)"}).replace(" ", "")
        details = MODULE.table_column(output, {"Description", "Details"})
        self.assertIn("--agent-tasks-rds-database-url", options)
        self.assertIn("env=AGENT_TASKS_RDS_DATABASE_URL; type=string", details)

    def test_literal_pipe_inside_description_does_not_split_the_column(self) -> None:
        output = """
+------------+----------+---------------------------------------+
| Option(s)  | Default  | Description                           |
+------------+----------+---------------------------------------+
| --format   | sql      | Output format: sql | json for CI      |
+------------+----------+---------------------------------------+
"""
        descriptions = MODULE.table_column(output, {"Description", "Details"})
        self.assertIn("Output format: sql json for CI", descriptions)

    def test_description_matching_tolerates_terminal_punctuation_spacing(self) -> None:
        expected = (
            "Output format for diff: sql | json "
            "(machine-readable change plan for CI/AI review)."
        )
        rendered = (
            "Output format for diff: sql  json machine readable change plan "
            "for CI / AI review"
        )
        self.assertTrue(MODULE.description_matches(expected, rendered))
        self.assertFalse(MODULE.description_matches(expected, "Output format only"))

    def test_command_basename_normalizes_paths_and_rejects_metacharacters(self) -> None:
        self.assertEqual(MODULE.command_basename("../zed"), "zed")
        self.assertEqual(MODULE.command_basename("/usr/bin/zed"), "zed")
        for unsafe in ["zed completion", "zed;rm"]:
            with self.assertRaises(ValueError):
                MODULE.command_basename(unsafe)
        self.assertEqual(MODULE.command_basename("zed-cli"), "zed-cli")


if __name__ == "__main__":
    unittest.main()
