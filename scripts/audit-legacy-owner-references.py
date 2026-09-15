#!/usr/bin/env python3
"""Fail-closed audit for references to the historical ORESoftware/flags-2-env remote."""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

LEGACY = "ORESoftware/flags-2-env"
CANONICAL = "flags-2-env/flags-2-env"
SHA40 = re.compile(r"^[0-9a-fA-F]{40}$")
SKIP_DIRS = {".git", "node_modules", "target", "dist", "build", ".dart_tool", ".venv", "vendor"}
TEXT_EXTENSIONS = {
    "", ".md", ".txt", ".json", ".jsonl", ".toml", ".yaml", ".yml", ".sh", ".bash",
    ".py", ".js", ".mjs", ".cjs", ".ts", ".tsx", ".rs", ".go", ".dart", ".gleam",
    ".ex", ".exs", ".erl", ".hrl", ".java", ".kt", ".swift", ".nix", ".lock",
}
REF_PATTERN = re.compile(
    r"(?:https?://github\.com/|git\+https://github\.com/|git@github\.com:)?"
    r"ORESoftware/flags-2-env(?:\.git)?"
    r"(?:(?:@|#|\?ref=)(?P<ref>[A-Za-z0-9._/-]+))?",
    re.I,
)


def iter_files(root: Path):
    for base, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for name in files:
            path = Path(base) / name
            if path.suffix.lower() not in TEXT_EXTENSIONS and not name.startswith('.'):
                continue
            yield path


def classify_ref(ref: str | None) -> str:
    if ref and SHA40.fullmatch(ref):
        return "immutable_historical"
    return "forbidden_mutable_or_unpinned"


def scan_text(text: str) -> list[tuple[str | None, str, str]]:
    results = []
    for match in REF_PATTERN.finditer(text):
        ref = match.groupdict().get("ref")
        results.append((ref, classify_ref(ref), match.group(0)))
    return results


def scan(root: Path, allow_paths: set[str]) -> list[dict]:
    findings: list[dict] = []
    for path in iter_files(root):
        rel = path.relative_to(root).as_posix()
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        for line_no, line in enumerate(text.splitlines(), 1):
            for ref, classification, reference in scan_text(line):
                if rel in allow_paths:
                    classification = "allowlisted_documentation"
                findings.append({
                    "path": rel,
                    "line": line_no,
                    "legacy_repository": LEGACY,
                    "canonical_repository": CANONICAL,
                    "reference": reference,
                    "ref": ref,
                    "classification": classification,
                    "remediation": "Use flags-2-env/flags-2-env for new references; retain the historical owner only at an immutable 40-hex commit when reproducibility requires it.",
                })
    return findings


def load_allowlist(root: Path) -> set[str]:
    path = root / ".legacy-owner-reference-allowlist.json"
    if not path.exists():
        return set()
    data = json.loads(path.read_text(encoding="utf-8"))
    return set(data.get("paths", []))


def run_self_test() -> int:
    fixture = Path(__file__).resolve().parents[1] / "tests" / "legacy-owner-reference-cases.json"
    data = json.loads(fixture.read_text(encoding="utf-8"))
    failures = []
    for case in data["cases"]:
        matches = scan_text(case["text"])
        actual = "no_finding" if not matches else matches[0][1]
        if actual != case["expected"]:
            failures.append({"name": case["name"], "expected": case["expected"], "actual": actual})
    if failures:
        print(json.dumps({"failures": failures}, indent=2), file=sys.stderr)
        return 1
    print(f"legacy-owner reference self-test: ok ({len(data['cases'])} cases)")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", nargs="?", default=".")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return run_self_test()
    root = Path(args.root).resolve()
    findings = scan(root, load_allowlist(root))
    forbidden = [f for f in findings if f["classification"] == "forbidden_mutable_or_unpinned"]
    report = {
        "schema": "flags-2-env.legacy-owner-audit/v1",
        "root": str(root),
        "legacy_repository": LEGACY,
        "canonical_repository": CANONICAL,
        "findings": findings,
        "forbidden_count": len(forbidden),
    }
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        for item in findings:
            print(f"{item['classification']}: {item['path']}:{item['line']} {item['reference']}")
        print(f"forbidden_count={len(forbidden)}")
    return 1 if forbidden else 0

if __name__ == "__main__":
    raise SystemExit(main())
