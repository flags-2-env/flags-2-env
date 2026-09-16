#!/usr/bin/env python3
"""Static policy checks for repositories consuming flags-2-env.

The canonical C audit remains the source of truth for contract syntax and parser
semantics. This companion check enforces cross-repository adoption policy:
immutable pins, strict unknown-option handling, secret-bearing environment
variables requiring argv=false, and trusted contract discovery for
long-running Rust processes.
"""

from __future__ import annotations

import argparse
import re
import sys
import tomllib
from dataclasses import dataclass
from datetime import date
from pathlib import Path
from typing import Any, Iterable

PIN_RE = re.compile(r"^[0-9a-f]{40}$")
ENV_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
CURRENT_DIR_RE = re.compile(
    r"(?:std\s*::\s*)?(?:env\s*::\s*)?current_dir\s*\(",
    re.MULTILINE,
)
CONTRACT_LITERAL_RE = re.compile(r"\.cli-flags\.toml")
RAW_STRING_START_RE = re.compile(r'(?:b|c)?r(#+)?"')
LONG_RUNNING_KINDS = {"server", "mcp", "worker"}
IGNORED_RUST_PATH_PARTS = {
    ".git",
    ".nix",
    ".venv",
    "benches",
    "build",
    "dist",
    "examples",
    "fixture",
    "fixtures",
    "generated",
    "node_modules",
    "target",
    "test",
    "tests",
    "third_party",
    "vendor",
    "venv",
}
SECRET_SEGMENTS = {
    "TOKEN",
    "SECRET",
    "PASSWORD",
    "PASSWD",
    "KEY",
    "CREDENTIAL",
    "CREDENTIALS",
    "COOKIE",
    "SESSION",
}
SECRET_COMPOUNDS = {
    ("DATABASE", "URL"),
    ("DATABASE", "DSN"),
    ("DB", "URL"),
    ("DB", "DSN"),
    ("REDIS", "URL"),
    ("AUTH", "HEADER"),
}
NON_SECRET_TOKEN_METADATA = {
    "TTL",
    "LIFETIME",
    "EXPIRY",
    "EXPIRATION",
    "ISSUER",
    "AUDIENCE",
}
NON_SECRET_KEY_METADATA = {
    "GRACE",
}
EXACT_SECRET_ENVS = {
    "OTEL_EXPORTER_OTLP_HEADERS",
    "OTEL_EXPORTER_OTLP_TRACES_HEADERS",
}
CANONICAL_UPSTREAM_GIT = "https://github.com/flags-2-env/flags-2-env.git"
COMPATIBILITY_UPSTREAM_GIT = "https://github.com/" + "ORESoftware" + "/flags-2-env.git"
COMPATIBILITY_SUPPORT_END = date(2026, 8, 19)


@dataclass(frozen=True)
class Flag:
    path: str
    env: str
    default_present: bool
    argv_enabled: bool = True


def fail(message: str) -> None:
    print(f"flags2env compliance: {message}", file=sys.stderr)


def is_secret_bearing_env(env: str) -> bool:
    """Return whether an environment name represents secret material.

    `*_TOKEN_TTL_*` and similar names describe token metadata, not the token
    value itself. Likewise, `*_KEY_GRACE_*` describes lifecycle timing for a
    domain key rather than key material. Keep both exceptions deliberately
    narrow and continue rejecting any additional secret marker in the name.
    """

    if env in EXACT_SECRET_ENVS:
        return True
    segments = env.upper().split("_")
    for left, right in zip(segments, segments[1:]):
        if (left, right) in SECRET_COMPOUNDS:
            return True
    for index, segment in enumerate(segments):
        if segment not in SECRET_SEGMENTS:
            continue
        if (
            segment == "TOKEN"
            and index + 1 < len(segments)
            and segments[index + 1] in NON_SECRET_TOKEN_METADATA
        ):
            continue
        if (
            segment == "KEY"
            and index + 1 < len(segments)
            and segments[index + 1] in NON_SECRET_KEY_METADATA
        ):
            continue
        return True
    return False


def safe_child(root: Path, relative: str, label: str) -> Path:
    candidate = (root / relative).resolve()
    try:
        candidate.relative_to(root)
    except ValueError as exc:
        raise ValueError(f"{label} escapes the repository root") from exc
    if not candidate.is_file():
        raise ValueError(f"{label} does not exist: {relative}")
    return candidate


def iter_flag_tables(container: Any, prefix: str) -> Iterable[Flag]:
    if not isinstance(container, dict):
        return
    flags = container.get("flags", {})
    if isinstance(flags, dict):
        for name, spec in flags.items():
            if not isinstance(spec, dict):
                continue
            env = spec.get("env")
            if isinstance(env, str):
                yield Flag(
                    f"{prefix}flags.{name}",
                    env,
                    "default" in spec,
                    spec.get("argv", True) is not False,
                )
    commands = container.get("commands", {})
    if isinstance(commands, dict):
        for name, command in commands.items():
            if isinstance(command, dict):
                yield from iter_flag_tables(command, f"{prefix}commands.{name}.")


def find_flags2env_dependency(manifest: dict[str, Any]) -> Any:
    locations = [
        manifest.get("dependencies", {}),
        manifest.get("build-dependencies", {}),
        manifest.get("dev-dependencies", {}),
        manifest.get("workspace", {}).get("dependencies", {})
        if isinstance(manifest.get("workspace"), dict)
        else {},
    ]
    for table in locations:
        if isinstance(table, dict) and "flags2env" in table:
            return table["flags2env"]
    return None


def supported_upstream_git(policy_date: date) -> frozenset[str]:
    sources = {CANONICAL_UPSTREAM_GIT}
    if policy_date <= COMPATIBILITY_SUPPORT_END:
        sources.add(COMPATIBILITY_UPSTREAM_GIT)
    return frozenset(sources)


def check_rust_pin(
    root: Path,
    manifest_path: str,
    lock_path: str,
    parser_ref: str,
    policy_date: date,
) -> list[str]:
    errors: list[str] = []
    try:
        manifest_file = safe_child(root, manifest_path, "Rust manifest")
        lock_file = safe_child(root, lock_path, "Cargo lockfile")
    except ValueError as error:
        return [str(error)]

    with manifest_file.open("rb") as handle:
        manifest = tomllib.load(handle)
    dependency = find_flags2env_dependency(manifest)
    if not isinstance(dependency, dict):
        errors.append(
            "Cargo.toml must declare flags2env as a git table with an immutable rev"
        )
    else:
        upstream_git = dependency.get("git")
        supported_sources = supported_upstream_git(policy_date)
        if upstream_git not in supported_sources:
            errors.append(
                f"flags2env git source must be {CANONICAL_UPSTREAM_GIT}; "
                f"the compatibility source is accepted only through "
                f"{COMPATIBILITY_SUPPORT_END.isoformat()}"
            )
        if dependency.get("rev") != parser_ref:
            errors.append("flags2env Cargo rev must exactly match parser_ref")
        if any(key in dependency for key in ("branch", "tag", "version")):
            errors.append(
                "flags2env dependency must not combine rev with branch, tag, or version"
            )

    lock_text = lock_file.read_text(encoding="utf-8")
    if (
        not isinstance(dependency, dict)
        or dependency.get("git") not in lock_text
        or parser_ref not in lock_text
    ):
        errors.append("Cargo.lock does not contain the exact flags2env git revision")
    return errors


def starts_rust_char_literal(source: str, index: int) -> bool:
    """Distinguish a character literal from a lifetime such as `'static`."""

    if index >= len(source) or source[index] != "'" or index + 2 >= len(source):
        return False
    cursor = index + 1
    if source[cursor] in "\r\n'":
        return False
    if source[cursor] != "\\":
        return cursor + 1 < len(source) and source[cursor + 1] == "'"

    cursor += 1
    if cursor >= len(source):
        return False
    if source[cursor] == "u" and cursor + 1 < len(source) and source[cursor + 1] == "{":
        closing_brace = source.find("}", cursor + 2)
        return (
            closing_brace >= 0
            and closing_brace + 1 < len(source)
            and source[closing_brace + 1] == "'"
        )
    return cursor + 1 < len(source) and source[cursor + 1] == "'"


def strip_rust_comments(source: str) -> str:
    """Remove Rust comments while preserving code and literal positions.

    Rust block comments may nest. Newlines and total character width are kept
    so later diagnostics and proximity checks remain stable.
    """

    output: list[str] = []
    index = 0
    block_depth = 0
    in_line_comment = False
    in_string = False
    in_char = False
    escape = False
    raw_hashes: int | None = None

    while index < len(source):
        char = source[index]
        nxt = source[index + 1] if index + 1 < len(source) else ""

        if in_line_comment:
            if char == "\n":
                in_line_comment = False
                output.append(char)
            else:
                output.append(" ")
            index += 1
            continue

        if block_depth:
            if char == "/" and nxt == "*":
                block_depth += 1
                output.extend((" ", " "))
                index += 2
                continue
            if char == "*" and nxt == "/":
                block_depth -= 1
                output.extend((" ", " "))
                index += 2
                continue
            output.append("\n" if char == "\n" else " ")
            index += 1
            continue

        if raw_hashes is not None:
            if char == '"' and source.startswith("#" * raw_hashes, index + 1):
                output.append(char)
                output.extend("#" * raw_hashes)
                index += 1 + raw_hashes
                raw_hashes = None
                continue
            output.append(char)
            index += 1
            continue

        if in_string:
            output.append(char)
            if escape:
                escape = False
            elif char == "\\":
                escape = True
            elif char == '"':
                in_string = False
            index += 1
            continue

        if in_char:
            output.append(char)
            if escape:
                escape = False
            elif char == "\\":
                escape = True
            elif char == "'":
                in_char = False
            index += 1
            continue

        if char == "/" and nxt == "/":
            in_line_comment = True
            output.extend((" ", " "))
            index += 2
            continue
        if char == "/" and nxt == "*":
            block_depth = 1
            output.extend((" ", " "))
            index += 2
            continue

        raw_match = RAW_STRING_START_RE.match(source, index)
        if raw_match:
            token = raw_match.group(0)
            raw_hashes = len(raw_match.group(1) or "")
            output.extend(token)
            index += len(token)
            continue

        if char == '"':
            in_string = True
            output.append(char)
            index += 1
            continue
        if char == "'" and starts_rust_char_literal(source, index):
            in_char = True
            output.append(char)
            index += 1
            continue

        output.append(char)
        index += 1

    return "".join(output)


def mask_rust_literals(source: str) -> str:
    """Mask string/character contents while preserving source positions."""

    output: list[str] = []
    index = 0
    in_string = False
    in_char = False
    escape = False
    raw_hashes: int | None = None

    while index < len(source):
        char = source[index]

        if raw_hashes is not None:
            if char == '"' and source.startswith("#" * raw_hashes, index + 1):
                width = 1 + raw_hashes
                output.extend(" " * width)
                index += width
                raw_hashes = None
                continue
            output.append("\n" if char == "\n" else " ")
            index += 1
            continue

        if in_string:
            output.append("\n" if char == "\n" else " ")
            if escape:
                escape = False
            elif char == "\\":
                escape = True
            elif char == '"':
                in_string = False
            index += 1
            continue

        if in_char:
            output.append("\n" if char == "\n" else " ")
            if escape:
                escape = False
            elif char == "\\":
                escape = True
            elif char == "'":
                in_char = False
            index += 1
            continue

        raw_match = RAW_STRING_START_RE.match(source, index)
        if raw_match:
            token = raw_match.group(0)
            raw_hashes = len(raw_match.group(1) or "")
            output.extend(" " * len(token))
            index += len(token)
            continue
        if char == '"':
            in_string = True
            output.append(" ")
            index += 1
            continue
        if char == "'" and starts_rust_char_literal(source, index):
            in_char = True
            output.append(" ")
            index += 1
            continue

        output.append(char)
        index += 1

    return "".join(output)


def iter_production_rust_sources(root: Path) -> Iterable[Path]:
    for path in sorted(root.rglob("*.rs")):
        relative = path.relative_to(root)
        folded_parts = {part.casefold() for part in relative.parts}
        if folded_parts & IGNORED_RUST_PATH_PARTS:
            continue
        if path.name.endswith(("_test.rs", "_tests.rs")):
            continue
        yield path


def source_resolves_contract_from_cwd(source: str) -> bool:
    without_comments = strip_rust_comments(source)
    code_only = mask_rust_literals(without_comments)
    contract_positions = [
        match.start() for match in CONTRACT_LITERAL_RE.finditer(without_comments)
    ]
    if not contract_positions:
        return False
    for current_dir in CURRENT_DIR_RE.finditer(code_only):
        start = max(0, current_dir.start() - 256)
        end = min(len(without_comments), current_dir.end() + 2048)
        if any(start <= position <= end for position in contract_positions):
            return True
    return False


def check_trusted_contract_resolution(root: Path, kind: str) -> list[str]:
    if kind not in LONG_RUNNING_KINDS:
        return []

    errors: list[str] = []
    for path in iter_production_rust_sources(root):
        try:
            source = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            errors.append(f"{path.relative_to(root)} is not valid UTF-8 Rust source")
            continue
        if source_resolves_contract_from_cwd(source):
            errors.append(
                f"{path.relative_to(root)} resolves .cli-flags.toml from the process "
                "current working directory; long-running consumers must use an "
                "explicit reviewed override and executable/package-relative trusted paths"
            )
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=".")
    parser.add_argument("--contract", default=".cli-flags.toml")
    parser.add_argument("--parser-ref", required=True)
    parser.add_argument(
        "--kind", choices=("server", "mcp", "cli", "worker"), required=True
    )
    parser.add_argument("--rust-manifest")
    parser.add_argument("--cargo-lock", default="Cargo.lock")
    parser.add_argument(
        "--policy-date",
        default=date.today().isoformat(),
        help="UTC policy date in YYYY-MM-DD form; defaults to today",
    )
    args = parser.parse_args()

    root = Path(args.root).resolve()
    errors: list[str] = []
    try:
        policy_date = date.fromisoformat(args.policy_date)
    except ValueError:
        fail("policy-date must use YYYY-MM-DD")
        return 1
    if not PIN_RE.fullmatch(args.parser_ref):
        errors.append("parser_ref must be a full 40-character lowercase commit SHA")

    try:
        contract_path = safe_child(root, args.contract, "contract")
    except ValueError as error:
        fail(str(error))
        return 1

    try:
        with contract_path.open("rb") as handle:
            contract = tomllib.load(handle)
    except (OSError, tomllib.TOMLDecodeError) as error:
        fail(f"cannot parse contract with Python tomllib: {error}")
        return 1

    parse = contract.get("parse", {})
    if isinstance(parse, dict) and parse.get("allow_unknown") is True:
        errors.append(
            "parse.allow_unknown must be false or omitted for compliant executables"
        )

    flags = list(iter_flag_tables(contract, ""))
    if not flags:
        errors.append("contract declares no process-level flags")

    seen_envs: dict[str, str] = {}
    for flag in flags:
        if not ENV_RE.fullmatch(flag.env):
            errors.append(f"{flag.path} uses invalid env name {flag.env!r}")
            continue
        previous = seen_envs.setdefault(flag.env, flag.path)
        if previous != flag.path:
            errors.append(f"{flag.path} and {previous} both map to {flag.env}")
        secret_bearing = is_secret_bearing_env(flag.env)
        if secret_bearing and flag.argv_enabled:
            errors.append(
                f"{flag.path} exposes secret-bearing env {flag.env} to argv; declare argv = false"
            )
        if flag.default_present and secret_bearing:
            errors.append(
                f"{flag.path} gives secret-bearing env {flag.env} a default"
            )

    env_policy = contract.get("env", {})
    ignored = env_policy.get("ignore", []) if isinstance(env_policy, dict) else []
    if ignored and not isinstance(ignored, list):
        errors.append("env.ignore must be a TOML array")
    elif isinstance(ignored, list):
        invalid_ignored = [
            value
            for value in ignored
            if not isinstance(value, str) or not ENV_RE.fullmatch(value)
        ]
        if invalid_ignored:
            errors.append(
                "env.ignore contains non-string or invalid environment names"
            )

    if args.rust_manifest:
        errors.extend(
            check_rust_pin(
                root,
                args.rust_manifest,
                args.cargo_lock,
                args.parser_ref,
                policy_date,
            )
        )
        errors.extend(check_trusted_contract_resolution(root, args.kind))

    if errors:
        for error in errors:
            fail(error)
        return 1

    print(
        "flags2env compliance: ok "
        f"kind={args.kind} flags={len(flags)} parser_ref={args.parser_ref}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
