# Deterministic environment manifest

`flags-2-env` can build a repository-wide environment inventory from the `[[env]]`
metadata embedded in root TOML configuration files.

This is an **audit/build-time metadata extractor**, not a runtime parser for domain
configuration. Each domain still parses and validates its own TOML through its own
independent TypeSpec and JSON Schema authorities. The shared metadata shape is owned
by `ORESoftware/ores-interfaces` under `contracts/env-manifest/v1/`; TJSV is the
fail-closed peer-authority admission mechanism.

## Canonical `[[env]]` declaration

```toml
[[env]]
name = "database_url"
key = "DATABASE_URL"
kind = "url"
required = true
secret = true
exposure = "env-only"
description = "Database credential URI supplied by the runtime secret boundary."
overrides = ["server.database_url"]
environments = ["dev", "prod"]
```

Non-secret values may include `default`; the scanner normalizes it to textual
`defaultValue` evidence. Secrets must be `env-only` and must not declare a default.

Supported kinds are `string`, `bool`, `integer`, `double`, `json`, `url`,
`duration-ms`, `string-list`, and `integer-list`.

## Discovery and merge

The scanner examines regular repository-root `*.toml` files except
`.cli-flags.toml`. Files are bytewise sorted. TOMLs without `[[env]]` blocks are
ignored.

Environment key is the global identity. Repeated compatible declarations merge
source paths, environment profiles, and override paths. Kind, required/secret
classification, exposure, description, and default must agree exactly; flags-2-env
does not choose a winner when two domain configs disagree.

Root TOML symlinks fail discovery rather than letting repository-local configuration
escape the checkout.

## `.cli-flags.toml` is the argv-capable superset

`f2e env-manifest sync` adds a generated **comment-only** inventory block to
`.cli-flags.toml`. This keeps every discovered environment key visible in the CLI
contract without adding a second runtime table understood differently by the native
parser.

The block is derived evidence. Actual argv exposure still requires a normal
`[flags.*]` declaration:

- `exposure = "argv-and-env"` requires exactly one `[flags.*].env` owner.
- `exposure = "env-only"` forbids a `[flags.*]` owner.

This is particularly important for credentials: they appear in the inventory but
never in process listings or shell history.

## `manifest.env`

`f2e env-manifest sync` writes deterministic `manifest.env`:

- all variables sorted alphabetically;
- empty `KEY=` assignments only;
- comments recording type, required/secret/exposure state, dev/stage/prod profiles,
  override paths, source TOMLs, and the human description;
- a SHA-256 identity over the normalized manifest.

`manifest.env` contains no runtime values and is safe to commit. Editing it by hand
is pointless because `f2e env-manifest check` recomputes the exact bytes.

## SOPS / `env/enc` / `env/dec`

The existing `ores-sops` boundary stays intact:

- tracked ciphertext: `env/enc/dev.env.enc`, optional `stage.env.enc`,
  `prod.env.enc`;
- ignored plaintext: `env/dec/*.env`.

The manifest check reads **keys only**. It never prints or hashes plaintext values.
For any existing profile file it rejects undeclared application keys, duplicate
keys, and non-alphabetical application-key order. By default every declared secret
for that profile must be present. `--sops-all` and `--dec-all` make the corresponding
file require every declared key, not just secrets.

SOPS metadata is lower-case and is not treated as an application environment key.

## Commands

```text
f2e env-manifest generate [root]
f2e env-manifest json [root]
f2e env-manifest sync [root] [--manifest path] [--cli path]
f2e env-manifest check [root] [--manifest path] [--cli path] [--sops-all] [--dec-all]
```

`generate` prints the empty-value dotenv inventory. `json` prints the normalized
machine-readable manifest. `sync` writes `manifest.env` and refreshes the
comment-only `.cli-flags.toml` index. `check` is the CI/pre-commit gate.

The env-manifest commands are dispatched before application argv parsing. They are
repository tooling and do not alter the existing flags-2-env runtime precedence or
create a competing command-line schema.
