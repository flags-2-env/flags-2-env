# Historical-owner reference audit

The canonical source is `flags-2-env/flags-2-env`. The historical `ORESoftware/flags-2-env` owner must not be used by new mutable dependencies after the migration cutoff.

Run the audit against any checked-out repository or fleet workspace:

```sh
python3 scripts/audit-legacy-owner-references.py /path/to/repo --json
```

The report schema is `flags-2-env.legacy-owner-audit/v1` and is deterministic for a fixed checkout.

## Classification

- Canonical `flags-2-env/flags-2-env` references produce no finding.
- A historical-owner reference pinned to an exact 40-hex commit is reported as `immutable_historical`; it is allowed for reproducibility but should still be migrated deliberately.
- Historical-owner references that are unpinned or point to a branch, moving tag, `latest`, or other non-commit ref are `forbidden_mutable_or_unpinned` and make the command exit non-zero.
- The scanner implementation, its test cases, and this document are narrowly allowlisted because they necessarily contain example historical references. Runtime/manifests/workflows are never blanket-allowlisted.

Git URL fragments (`#<ref>`), GitHub-style `@<ref>`, and `?ref=<ref>` forms are recognized. New clone URLs, submodules, workflow references, package sources, and automation documentation should all use the canonical owner.

## CI / fleet integration

Consumers may vendor or invoke this script from CI, but `ores-cli` and shared GitHub Actions should ultimately consume the same finding schema so the fleet has one rule: canonical mutable source, with historical-owner use limited to immutable evidence/reproducibility pins.

Run the checked-in classifier fixtures with:

```sh
python3 scripts/audit-legacy-owner-references.py --self-test
```
