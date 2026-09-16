"""Unit tests for scripts/verify-client-parser-sync.py.

The failure mode this checker has to be protected against is not a false alarm,
it is a silent pass: a discovery glob that stops matching anything still prints
a tick. Every test below therefore asserts on the exit status, and one of them
asserts that finding nothing is itself a failure.
"""

from __future__ import annotations

import importlib.util
import subprocess
import sys
import textwrap
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT = REPO_ROOT / "scripts" / "verify-client-parser-sync.py"

CANONICAL_C = "/* canonical parser */\nint f2e_parse(void) { return 0; }\n"
CANONICAL_H = "/* canonical header */\nint f2e_parse(void);\n"


def load_module():
    spec = importlib.util.spec_from_file_location("verify_client_parser_sync", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ClientParserSyncTest(unittest.TestCase):
    def setUp(self) -> None:
        self.module = load_module()

    def build_tree(self, root: Path, copies: dict[str, str]) -> None:
        (root / "src").mkdir(parents=True, exist_ok=True)
        (root / "src/parser.c").write_text(CANONICAL_C)
        (root / "src/parser.h").write_text(CANONICAL_H)
        for relative, content in copies.items():
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)

    def run_script(self, root: Path, min_copies: int = 1) -> subprocess.CompletedProcess:
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--root",
                str(root),
                "--min-copies",
                str(min_copies),
            ],
            capture_output=True,
            text=True,
        )

    def test_identical_copies_pass(self) -> None:
        with TemporaryTree() as root:
            self.build_tree(
                root,
                {
                    "clients/cpp/native/parser.c": CANONICAL_C,
                    "clients/cpp/native/parser.h": CANONICAL_H,
                    "clients/golang/parser.c": CANONICAL_C,
                    "clients/golang/parser.h": CANONICAL_H,
                },
            )
            result = self.run_script(root, min_copies=4)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_one_drifted_copy_fails(self) -> None:
        with TemporaryTree() as root:
            self.build_tree(
                root,
                {
                    "clients/cpp/native/parser.c": CANONICAL_C,
                    "clients/cpp/native/parser.h": CANONICAL_H,
                    "clients/golang/parser.c": CANONICAL_C + "/* drift */\n",
                    "clients/golang/parser.h": CANONICAL_H,
                },
            )
            result = self.run_script(root, min_copies=4)
            self.assertEqual(result.returncode, 1)
            self.assertIn("clients/golang/parser.c", result.stderr)

    def test_stale_canonical_with_fresh_copies_fails(self) -> None:
        """The direction that merging a parser change without refreshing copies takes."""
        with TemporaryTree() as root:
            self.build_tree(
                root,
                {
                    "clients/cpp/native/parser.c": CANONICAL_C,
                    "clients/cpp/native/parser.h": CANONICAL_H,
                },
            )
            (root / "src/parser.c").write_text(CANONICAL_C + "/* new behaviour */\n")
            result = self.run_script(root, min_copies=2)
            self.assertEqual(result.returncode, 1)

    def test_finding_nothing_is_a_failure(self) -> None:
        """A check that inspected an empty set must not report success."""
        with TemporaryTree() as root:
            self.build_tree(root, {})
            result = self.run_script(root, min_copies=1)
            self.assertEqual(result.returncode, 1)
            self.assertIn("stale", result.stderr)

    def test_fuzz_harness_is_excluded(self) -> None:
        """tests/fuzz_parser.c wraps the parser; it is not a vendored copy."""
        with TemporaryTree() as root:
            self.build_tree(
                root,
                {
                    "clients/cpp/native/parser.c": CANONICAL_C,
                    "clients/cpp/native/parser.h": CANONICAL_H,
                    "tests/fuzz_parser.c": "/* totally different harness */\n",
                },
            )
            result = self.run_script(root, min_copies=2)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_build_and_vendor_trees_are_ignored(self) -> None:
        """Copies inside build output or a zed install dir are not ours to police."""
        with TemporaryTree() as root:
            self.build_tree(
                root,
                {
                    "clients/cpp/native/parser.c": CANONICAL_C,
                    "clients/cpp/native/parser.h": CANONICAL_H,
                    "build/parser.c": "/* stale build artifact */\n",
                    ".vendor/.zed/flags-2-env/flags-2-env/src/parser.c": "/* a dependency */\n",
                },
            )
            result = self.run_script(root, min_copies=2)
            self.assertEqual(result.returncode, 0, result.stderr)


class TemporaryTree:
    """tempfile.TemporaryDirectory, but yielding a Path."""

    def __enter__(self) -> Path:
        import tempfile

        self._tmp = tempfile.TemporaryDirectory()
        return Path(self._tmp.name)

    def __exit__(self, *exc_info) -> None:
        self._tmp.cleanup()


if __name__ == "__main__":
    unittest.main()
