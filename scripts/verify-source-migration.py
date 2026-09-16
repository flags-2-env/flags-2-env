#!/usr/bin/env python3
"""Validate the dual-GitHub source contract without changing either remote.

The compatibility window is a *dated* promise, and a dated promise that
nothing evaluates against the calendar is the same silent pass this
repository refuses everywhere else: before this check learned today's
date, `supportEndsOn` could pass and every run still printed a tick, so
the mirror kept advertising support it no longer owed. After the window
closes the manifest must therefore record the cutoff as complete, and
each obligation that is still outstanding is reported as an error naming
the action that clears it.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tomllib
from datetime import date
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = ROOT / "docs" / "source-migration.json"
SCHEMA_PATH = ROOT / "docs" / "source-migration.schema.json"

CANONICAL_GIT = "https://github.com/flags-2-env/flags-2-env.git"
CANONICAL_WEB = "https://github.com/flags-2-env/flags-2-env"
COMPATIBILITY_GIT = "https://github.com/ORESoftware/flags-2-env.git"
COMPATIBILITY_WEB = "https://github.com/ORESoftware/flags-2-env"

EXPECTED_TOP_LEVEL_KEYS = {
    "$schema",
    "schemaVersion",
    "canonical",
    "compatibility",
    "cutoff",
    "zedPackage",
    "publicationOrder",
}

# Every obligation the cutoff procedure in docs/source-migration.md leaves to a
# human, mapped to the action that clears it. Listing them here is what makes
# an expired window actionable rather than merely late.
CUTOFF_OBLIGATIONS = {
    "mirror-notice-updated": (
        "replace the present-tense compatibility notice in the mirror's README "
        "with the post-cutoff redirect notice"
    ),
    "mirror-archived": (
        "archive https://github.com/ORESoftware/flags-2-env so it is a "
        "read-only historical source"
    ),
}

# The dated promise that must not outlive the window: "remains a supported ...
# through <end date>". Matching the whole shape rather than the bare fragment is
# deliberate -- documentation that *quotes* the phrase while explaining this very
# rule is not itself a claim, and a substring scan cannot tell the two apart.
SUPPORT_CLAIM_DOCS = ("README.md", "docs/source-migration.md")


def stale_support_claim(support_ends_on: date) -> re.Pattern[str]:
    return re.compile(
        r"remains\s+a\s+supported[^.]{0,160}?through\s+" + re.escape(support_ends_on.isoformat()),
        re.IGNORECASE | re.DOTALL,
    )


def today() -> date:
    """Resolve the evaluation date, overridable so the tests are deterministic."""
    override = os.environ.get("F2E_MIGRATION_TODAY")
    if override:
        return date.fromisoformat(override)
    return date.today()
LEGACY_REFERENCE_ALLOWLIST = {
    "README.md",
    "docs/legacy-owner-reference-audit.md",
    "docs/source-migration.json",
    "docs/source-migration.md",
    "docs/source-migration.schema.json",
    "scripts/audit-legacy-owner-references.py",
    "scripts/verify-source-migration.py",
    "tests/legacy-owner-reference-cases.json",
}


def load_json(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"{path.relative_to(ROOT)} must contain a JSON object")
    return value


def expect_object(
    value: Any, name: str, expected_keys: set[str], errors: list[str]
) -> dict[str, Any]:
    if not isinstance(value, dict):
        errors.append(f"{name} must be an object")
        return {}
    actual_keys = set(value)
    if actual_keys != expected_keys:
        missing = sorted(expected_keys - actual_keys)
        extra = sorted(actual_keys - expected_keys)
        errors.append(f"{name} keys differ: missing={missing} extra={extra}")
    return value


def tracked_files() -> list[Path]:
    completed = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=ROOT,
        check=True,
        capture_output=True,
    )
    return [ROOT / item.decode() for item in completed.stdout.split(b"\0") if item]


def validate_cutoff(cutoff: Any, support_ends_on: date) -> list[str]:
    """Check the cutoff record against the calendar, not just against itself."""
    errors: list[str] = []
    cutoff = expect_object(
        cutoff,
        "cutoff",
        {"state", "completedOn", "mirrorDisposition", "pendingObligations"},
        errors,
    )
    if errors:
        return errors

    state = cutoff.get("state")
    if state not in {"pending", "complete"}:
        errors.append('cutoff.state must be "pending" or "complete"')
        return errors
    if cutoff.get("mirrorDisposition") != "read-only-historical-source":
        errors.append(
            "cutoff.mirrorDisposition must keep the mirror as a "
            "read-only historical source"
        )

    pending = cutoff.get("pendingObligations")
    if not isinstance(pending, list) or any(not isinstance(item, str) for item in pending):
        errors.append("cutoff.pendingObligations must be a list of obligation names")
        return errors
    unknown = sorted(set(pending) - set(CUTOFF_OBLIGATIONS))
    if unknown:
        errors.append(f"cutoff.pendingObligations contains unknown entries: {unknown}")
    if len(set(pending)) != len(pending):
        errors.append("cutoff.pendingObligations must not repeat an obligation")

    completed_on = cutoff.get("completedOn")
    completed: date | None = None
    if completed_on is not None:
        try:
            completed = date.fromisoformat(str(completed_on))
        except ValueError:
            errors.append("cutoff.completedOn must be null or YYYY-MM-DD")

    now = today()
    if state == "complete":
        if completed is None:
            errors.append("cutoff.state is complete but cutoff.completedOn is not a date")
        else:
            if completed <= support_ends_on:
                errors.append(
                    "cutoff.completedOn must fall after the compatibility window closes"
                )
            if completed > now:
                errors.append("cutoff.completedOn must not be in the future")
        if pending:
            errors.append(
                "cutoff.state is complete but obligations are still listed: "
                f"{sorted(pending)}"
            )
        return errors

    # state == "pending"
    if completed is not None:
        errors.append("cutoff.completedOn must be null while the cutoff is pending")
    if now > support_ends_on:
        # The window has closed. Saying nothing here is what let the mirror keep
        # advertising expired support, so each outstanding step is an error that
        # names the action clearing it.
        errors.append(
            f"compatibility support ended on {support_ends_on.isoformat()} "
            f"({(now - support_ends_on).days} day(s) ago) and the cutoff is still pending"
        )
        for obligation in sorted(pending):
            errors.append(f"cutoff obligation {obligation!r}: {CUTOFF_OBLIGATIONS[obligation]}")
        if not pending:
            errors.append(
                'cutoff.state must be set to "complete" once every obligation is cleared'
            )
        errors.extend(validate_support_claims(now, support_ends_on))
    return errors


def validate_support_claims(now: date, support_ends_on: date) -> list[str]:
    """After the window closes, no document may still promise support."""
    errors: list[str] = []
    if now <= support_ends_on:
        return errors
    for relative in SUPPORT_CLAIM_DOCS:
        path = ROOT / relative
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8")
        if stale_support_claim(support_ends_on).search(text):
            errors.append(
                f"{relative} still promises the mirror is supported through "
                f"{support_ends_on.isoformat()}, a date that has passed"
            )
    return errors


def validate_metadata() -> list[str]:
    errors: list[str] = []
    manifest = load_json(MANIFEST_PATH)
    schema = load_json(SCHEMA_PATH)

    if set(manifest) != EXPECTED_TOP_LEVEL_KEYS:
        errors.append("source-migration.json has missing or unsupported top-level keys")
    if manifest.get("$schema") != SCHEMA_PATH.name:
        errors.append("source-migration.json must reference its repository-local schema")
    if manifest.get("schemaVersion") != "flags-2-env.source-migration.v1":
        errors.append("unsupported source migration schema version")
    if schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
        errors.append("source-migration.schema.json must use JSON Schema 2020-12")
    if schema.get("$id") != f"{CANONICAL_WEB}/blob/main/docs/{SCHEMA_PATH.name}":
        errors.append("source migration schema $id must use the canonical repository")

    canonical = expect_object(
        manifest.get("canonical"), "canonical", {"repository", "web"}, errors
    )
    if canonical.get("repository") != CANONICAL_GIT:
        errors.append("canonical.repository is not the canonical Git URL")
    if canonical.get("web") != CANONICAL_WEB:
        errors.append("canonical.web is not the canonical web URL")

    compatibility = expect_object(
        manifest.get("compatibility"),
        "compatibility",
        {
            "repository",
            "web",
            "supportStartsOn",
            "supportEndsOn",
            "mode",
            "mirroredRefs",
        },
        errors,
    )
    if compatibility.get("repository") != COMPATIBILITY_GIT:
        errors.append("compatibility.repository is not the original Git URL")
    if compatibility.get("web") != COMPATIBILITY_WEB:
        errors.append("compatibility.web is not the original web URL")
    if compatibility.get("mode") != "commit-identical-mirror":
        errors.append("compatibility.mode must require a commit-identical mirror")
    if compatibility.get("mirroredRefs") != ["refs/heads/main", "refs/tags/*"]:
        errors.append("compatibility.mirroredRefs must cover main and every tag")
    try:
        start = date.fromisoformat(str(compatibility.get("supportStartsOn")))
        end = date.fromisoformat(str(compatibility.get("supportEndsOn")))
    except ValueError:
        errors.append("compatibility support dates must use YYYY-MM-DD")
    else:
        if start.isoformat() != "2026-08-09" or end.isoformat() != "2026-08-19":
            errors.append("compatibility support window must be 2026-08-09 through 2026-08-19")
        if (end - start).days != 10:
            errors.append("compatibility support boundary must be exactly ten days")
        else:
            errors.extend(validate_cutoff(manifest.get("cutoff"), end))

    zed_package = expect_object(
        manifest.get("zedPackage"),
        "zedPackage",
        {
            "version",
            "canonicalIdentity",
            "compatibilityIdentity",
            "aliasSupport",
            "compatibilityPublishMode",
            "repositoryAuthority",
        },
        errors,
    )
    if zed_package != {
        "version": "0.3.0",
        "canonicalIdentity": "flags-2-env/flags-2-env",
        "compatibilityIdentity": "oresoftware/flags-2-env",
        "aliasSupport": "unavailable",
        "compatibilityPublishMode": "single-field-manifest-overlay",
        "repositoryAuthority": "canonical",
    }:
        errors.append("Zed dual-publication policy differs from the reviewed contract")
    if manifest.get("publicationOrder") != ["canonical", "compatibility"]:
        errors.append("publication order must be canonical then compatibility")

    with (ROOT / ".zpkg.toml").open("rb") as handle:
        zpkg = tomllib.load(handle)
    package = zpkg.get("package", {})
    repository = package.get("repository", {}) if isinstance(package, dict) else {}
    if package.get("org") != "flags-2-env" or package.get("name") != "flags-2-env":
        errors.append(".zpkg.toml must declare canonical flags-2-env/flags-2-env")
    if package.get("version") != "0.3.0":
        errors.append(".zpkg.toml must release the hardened tip as 0.3.0")
    if repository.get("url") != CANONICAL_WEB:
        errors.append(".zpkg.toml repository URL must use the canonical source")

    with (ROOT / ".cli-flags.toml").open("rb") as handle:
        cli_flags = tomllib.load(handle)
    if cli_flags.get("help", {}).get("url") != CANONICAL_WEB:
        errors.append(".cli-flags.toml help URL must use the canonical source")
    formal = load_json(ROOT / "formal" / "fmctl.json")
    if formal.get("repoUrl") != CANONICAL_GIT:
        errors.append("formal/fmctl.json must use the canonical source")

    for path in tracked_files():
        relative = path.relative_to(ROOT).as_posix()
        try:
            contents = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        if COMPATIBILITY_WEB in contents and relative not in LEGACY_REFERENCE_ALLOWLIST:
            errors.append(
                f"{relative} retains the compatibility URL outside the explicit allowlist"
            )

    return errors


def remote_refs(url: str) -> dict[str, str]:
    completed = subprocess.run(
        ["git", "ls-remote", "--refs", url, "refs/heads/main", "refs/tags/*"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    if completed.returncode:
        detail = completed.stderr.strip() or f"git ls-remote exited {completed.returncode}"
        raise RuntimeError(f"cannot inspect {url}: {detail}")
    refs: dict[str, str] = {}
    for line in completed.stdout.splitlines():
        object_id, ref = line.split("\t", 1)
        refs[ref] = object_id
    return refs


def validate_remote_parity() -> list[str]:
    errors: list[str] = []
    try:
        canonical = remote_refs(CANONICAL_GIT)
        compatibility = remote_refs(COMPATIBILITY_GIT)
    except RuntimeError as error:
        return [str(error)]
    if "refs/heads/main" not in canonical:
        errors.append("canonical repository has no main branch")
    if "refs/heads/main" not in compatibility:
        errors.append("compatibility repository has no main branch")
    if canonical != compatibility:
        missing_compatibility = sorted(set(canonical) - set(compatibility))
        extra_compatibility = sorted(set(compatibility) - set(canonical))
        mismatched = sorted(
            ref
            for ref in set(canonical) & set(compatibility)
            if canonical[ref] != compatibility[ref]
        )
        errors.append(
            "remote ref parity failed: "
            f"missing_compatibility={missing_compatibility} "
            f"extra_compatibility={extra_compatibility} mismatched={mismatched}"
        )
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check-remotes",
        action="store_true",
        help="compare canonical and compatibility main/tag object IDs",
    )
    args = parser.parse_args()

    try:
        errors = validate_metadata()
    except (OSError, ValueError, json.JSONDecodeError, tomllib.TOMLDecodeError) as error:
        errors = [str(error)]
    if args.check_remotes:
        errors.extend(validate_remote_parity())
    if errors:
        for error in errors:
            print(f"source migration: {error}", file=sys.stderr)
        return 1
    suffix = " + remote parity" if args.check_remotes else ""
    print(f"source migration: metadata valid{suffix}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
