#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts" / "verify-consumer-compliance.py"
SPEC = importlib.util.spec_from_file_location("verify_consumer_compliance", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class ConsumerCompliancePolicyTests(unittest.TestCase):
    def test_compatibility_source_expires_after_ten_day_window(self) -> None:
        self.assertIn(
            MODULE.COMPATIBILITY_UPSTREAM_GIT,
            MODULE.supported_upstream_git(date(2026, 8, 19)),
        )
        self.assertNotIn(
            MODULE.COMPATIBILITY_UPSTREAM_GIT,
            MODULE.supported_upstream_git(date(2026, 8, 20)),
        )
        self.assertIn(
            MODULE.CANONICAL_UPSTREAM_GIT,
            MODULE.supported_upstream_git(date(2030, 1, 1)),
        )

    def test_token_metadata_is_not_secret_material(self) -> None:
        for env in [
            "AUTH_TOKEN_TTL_SECS",
            "API_TOKEN_EXPIRY_SECONDS",
            "ACCESS_TOKEN_LIFETIME_MINUTES",
            "JWT_TOKEN_ISSUER",
            "JWT_TOKEN_AUDIENCE",
        ]:
            with self.subTest(env=env):
                self.assertFalse(MODULE.is_secret_bearing_env(env))

    def test_domain_key_grace_metadata_is_not_key_material(self) -> None:
        for env in [
            "LMX_IDLE_KEY_GRACE_MS",
            "LOCK_KEY_GRACE_SECONDS",
        ]:
            with self.subTest(env=env):
                self.assertFalse(MODULE.is_secret_bearing_env(env))

    def test_secret_values_and_compound_connection_strings_remain_blocked(self) -> None:
        for env in [
            "API_TOKEN",
            "ACCESS_TOKEN_VALUE",
            "AUTH_SIGNING_KEY_PEM",
            "CLIENT_SECRET",
            "AUTH_DATABASE_URL",
            "REDIS_URL",
            "OTEL_EXPORTER_OTLP_HEADERS",
            "SESSION_COOKIE",
        ]:
            with self.subTest(env=env):
                self.assertTrue(MODULE.is_secret_bearing_env(env))

    def test_metadata_exception_does_not_hide_a_second_secret_marker(self) -> None:
        for env in [
            "AUTH_TOKEN_TTL_SECRET",
            "API_TOKEN_EXPIRY_PASSWORD",
            "ACCESS_TOKEN_LIFETIME_KEY",
            "LOCK_KEY_GRACE_SECRET",
            "LOCK_KEY_GRACE_PASSWORD",
        ]:
            with self.subTest(env=env):
                self.assertTrue(MODULE.is_secret_bearing_env(env))

    def test_env_only_secret_flag_metadata_is_preserved(self) -> None:
        [flag] = list(
            MODULE.iter_flag_tables(
                {
                    "flags": {
                        "database": {
                            "env": "DATABASE_URL",
                            "type": "string",
                            "argv": False,
                        }
                    }
                },
                "",
            )
        )
        self.assertFalse(flag.argv_enabled)
        self.assertTrue(MODULE.is_secret_bearing_env(flag.env))

    def test_long_running_rust_consumer_cannot_load_contract_from_cwd(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "src" / "flags.rs"
            source.parent.mkdir(parents=True)
            source.write_text(
                '''
use std::path::PathBuf;

fn resolve() -> PathBuf {
    std::env::current_dir()
        .expect("cwd")
        .join(".cli-flags.toml")
}
''',
                encoding="utf-8",
            )
            errors = MODULE.check_trusted_contract_resolution(root, "server")
            self.assertEqual(len(errors), 1)
            self.assertIn("src/flags.rs", errors[0])
            self.assertIn("current working directory", errors[0])

    def test_cli_project_local_contract_remains_an_explicit_kind_policy(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "src" / "main.rs"
            source.parent.mkdir(parents=True)
            source.write_text(
                'let path = std::env::current_dir()?.join(".cli-flags.toml");\n',
                encoding="utf-8",
            )
            self.assertEqual(
                MODULE.check_trusted_contract_resolution(root, "cli"), []
            )

    def test_test_fixture_comments_and_string_only_mentions_are_ignored(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = root / "tests" / "cwd_config.rs"
            fixture.parent.mkdir(parents=True)
            fixture.write_text(
                'let path = std::env::current_dir()?.join(".cli-flags.toml");\n',
                encoding="utf-8",
            )
            source = root / "src" / "flags.rs"
            source.parent.mkdir(parents=True)
            source.write_text(
                '''
// std::env::current_dir()?.join(".cli-flags.toml");
/* A nested example:
   /* current_dir().join(".cli-flags.toml") */
*/
const EXPLANATION: &str = "do not call current_dir when locating policy";
const CONTRACT_NAME: &str = ".cli-flags.toml";
''',
                encoding="utf-8",
            )
            self.assertEqual(
                MODULE.check_trusted_contract_resolution(root, "worker"), []
            )

    def test_executable_relative_contract_is_trusted(self) -> None:
        source = '''
let executable = std::env::current_exe()?;
let path = executable
    .parent()
    .expect("executable parent")
    .join("../share/example/.cli-flags.toml");
'''
        self.assertFalse(MODULE.source_resolves_contract_from_cwd(source))

    def test_nested_block_comments_are_removed_without_losing_real_code(self) -> None:
        source = '''
/* current_dir().join(".cli-flags.toml")
   /* nested current_dir example */
*/
let path = env::current_dir()?.join(".cli-flags.toml");
'''
        self.assertTrue(MODULE.source_resolves_contract_from_cwd(source))


if __name__ == "__main__":
    unittest.main()
