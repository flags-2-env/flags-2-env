# flags-2-env

`flags-2-env` parses CLI flags through a project-local `.cli-flags.toml` file and returns a string-to-string map of environment variable overrides.

The native core is C. Runtime clients bind to the same small ABI and convert the returned JSON object into each language's native map type.

The stateful browser/Web Worker application runtime uses one explicit,
fail-closed lifecycle reducer. Its actual transition code is exhaustively model
checked, its parameterized worker invariants are proved with Z3, and its timer,
promise, and termination effects are exercised in Chromium, Firefox, and
WebKit. See [`formal/README.md`](formal/README.md) for the exact guarantee,
desktop-application inventory gate, commands, and environmental boundaries.

## Source repository transition

The canonical source repository is
[`flags-2-env/flags-2-env`](https://github.com/flags-2-env/flags-2-env). Use it
for every source reference.

The ten-day compatibility window for the original
[`ORESoftware/flags-2-env`](https://github.com/ORESoftware/flags-2-env)
repository ran from 2026-08-09 and **ended on 2026-08-19**. That repository is
no longer a supported source: it is kept as a read-only historical source and
redirect notice, so existing immutable references to already-published commits
and tags stay resolvable, while anything new — clones, submodules, package
manifests, documentation links — must point at the canonical repository.

The canonical Zed package is `flags-2-env/flags-2-env@0.3.0`. Zed treats
`org/name` as immutable package identity and has no package-alias field, so
`oresoftware/flags-2-env@0.3.0` was published separately from the exact same
tagged source commit during the window; it remains installable but receives no
new versions. See [`docs/source-migration.md`](docs/source-migration.md) for the
machine-checked contract, publication order, and the cutoff procedure that
`scripts/verify-source-migration.py` now enforces against the calendar.

## Config

Create `.cli-flags.toml` in the project root:

```toml
[help]
url = "https://example.com/my-cli/help"
columns = ["options", "env", "type", "default", "description"]
exclude = []

[flags.port]
env = "PORT"
aliases = ["port", "listen-port"]
short = "p"
type = "integer"
default = 3000
help = "TCP port for the app listener."

[flags.debug]
env = "DEBUG"
aliases = ["debug"]
short = "d"
type = "bool"
default = "false"
true_aliases = ["t", "1"]
false_aliases = ["f", "0"]
help = "Enable debug logging."

[flags.mode]
env = "NODE_ENV"
aliases = ["mode", "env"]
short = "m"
type = "string"
help = "Runtime environment name."

[flags.payload]
env = "PAYLOAD_JSON"
aliases = ["payload"]
type = "json"
help = "JSON payload string."

[flags.ratio]
env = "SAMPLE_RATIO"
aliases = ["sample-ratio"]
type = "double"
default = 0.5

[flags.tags]
env = "TAGS"
aliases = ["tags"]
type = "array"

[flags.labels]
env = "LABELS"
aliases = ["labels"]
type = "map"

[flags.retries]
env = "RETRIES"
aliases = ["retries"]
type = "integer"
help = "Retry count."
```

## Subcommands

CLIs like `git commit -am ...` or `docker run ...` scope their flags to a command: `-A` can mean one thing for `git add -A` and something else entirely for `git log -A`. Declare commands with `[commands.<name>]` tables, and scope flags to a command with `[commands.<name>.flags.<flag>]`. Nest arbitrarily deep (`gh auth login`-style) by chaining `commands` segments:

```toml
[commands.add]
help = "Add file contents to the index."
env = "GIT_CMD_ADD"            # optional: set to "true" when this command runs

[commands.add.flags.all]
env = "GIT_ADD_ALL"
aliases = ["all"]
short = "A"
type = "bool"
help = "Stage all tracked and untracked files."

[commands.commit]
help = "Record changes to the repository."
aliases = ["ci"]               # optional command aliases

[commands.commit.flags.message]
env = "GIT_COMMIT_MESSAGE"
aliases = ["message"]
short = "m"
type = "string"

# second-level subcommand: `git remote add ...`
[commands.remote.commands.add]
help = "Add a remote."

[commands.remote.commands.add.flags.fetch]
env = "GIT_REMOTE_ADD_FETCH"
aliases = ["fetch"]
short = "f"
type = "bool"
```

`command`, `subcommands`, and `subcommand` are accepted spellings of the `commands` keyword, and `[commands.<name>]` property lines support `help`/`description`, `aliases`, and `env`.

Nesting always spells out the keyword — `[commands.publish.commands.init.flags.access]`, never `[commands.publish.init.flags.access]` — and the shorthand is an audit error rather than a silent no-op. Because keyword and name positions strictly alternate, command names can never clash with the keywords: `[commands.commands]` is a subcommand literally named `commands` (invoked as `mycli commands`), while `[flags.commands]` would be an unrelated `--commands` flag.

Parsing walks argv left to right. Leading positionals that match no top-level command (the program name, a wrapper token) are skipped; the first positional that matches a command selects it, and each following positional may select a nested subcommand. The first positional that matches no subcommand of the current scope ends command matching — so in `docker run ubuntu ls -la`, `run` is the command and `ubuntu`/`ls` stay positionals. Matched command tokens are not recorded as positionals.

Flags resolve against the active command scope first, then its ancestors, then the global `[flags.*]` set — a subcommand may reuse a short flag or alias that means something else elsewhere, and unshadowed global flags keep working after the subcommand. Command-scoped flags are only valid inside their command: `mycli init --pack` reports `--pack` as an unknown option when `pack` is declared under `[commands.run]`. Flag defaults only apply to global flags and flags of the commands actually selected.

`[global.flags.<name>]` is an explicit spelling of the global namespace — identical to `[flags.<name>]` — for configs that want to state loudly that a flag applies inside every subcommand.

`allow_unknown` may also be set per command: `[commands.run] allow_unknown = true` tolerates unrecognized options once `run` (or one of its subcommands, which inherit the setting) is active, while the rest of the CLI stays strict. A runtime `--allow-unknown`/`--no-allow-unknown` token or `FLAGS2ENV_ALLOW_UNKNOWN` env var still overrides every scope.

Some CLIs front the real binary with a wrapper script that consumes the subcommand token before argv reaches flags2env (discouraged, but common). When commands are declared and argv selects none, parsing falls back to lenient global resolution: root flags behave normally, a command-scoped flag whose name is unambiguous across all scopes is applied as if it were global, and a name declared in several scopes is accepted but not applied (never reported unknown). Genuinely undeclared options are still collected. Scoped defaults stay off in this mode because the intended command is unknown.

The resolved command path is returned as a space-joined string under `FLAGS2ENV_COMMAND` (rename it with `[parse] command_env = "MY_CMD"`), which makes dispatch a plain switch:

```sh
eval "$(flags2env export -- "$0" "$@")"
case "$FLAGS2ENV_COMMAND" in
  "add")        do_add ;;
  "remote add") do_remote_add ;;
  "")           usage ;;
esac
```

Commands that declare `env` also get that key set to `"true"` when they are on the selected path (`GIT_CMD_ADD=true` above), which is convenient in languages where string switches are awkward.

`--help` is subcommand-aware: the top-level menu renders a bordered `Commands:` table (nested commands shown as their full path, e.g. `remote add`) beneath the global options, and `mycli remote add --help` renders that command's description, its own flags, and the inherited global flags with shadowed short flags hidden. Generated shell completions offer top-level command names alongside global options, and `flags2env audit` validates command tables: duplicate aliases or shorts are only errors within one scope, sibling commands must not share names or aliases, and command envs must not collide with flag envs.

Native callers can render the scoped help directly with `f2e_help_table_for_argv[_from_file]` / `f2e_print_table_for_argv[_from_file]`, or `f2e_help_table_for_json_argv[_from_file]` from FFI clients. The Node.js client exposes this as `helpTableForArgv(command, argv, opts)`, and its `parse(...).printTable()` automatically renders the help table for the subcommand selected by the parsed argv.

For programmatic callers, the structured parse API returns each channel separately instead of packing everything into env keys (so nothing can be shadowed by real environment variables): `f2e_parse_structured[_from_file]` / `f2e_parse_structured_json_argv[_from_file]` return `{"flags":{...},"providedFlags":{...},"command":"remote add","subcommands":["remote","add"],"extras":["abc"],"unknownOptions":[],"errors":[]}`. `flags` is the same default-bearing env map `f2e_parse` returns. `providedFlags` contains only normalized argv-derived values and command markers, so it can be merged over the real process environment before `coerce()` without a TOML default incorrectly shadowing an environment value. `extras` holds the operand tokens (positionals after the last matched command, including tokens after a bare `--`; with no command matched, everything except argv[0]). `f2e_resolve_commands*` returns just `{"path":[...],"label":"..."}`. The Node.js client exposes these as `parseStructured(argv, opts)` and the strict `parseOverridesFromArgs(argv, opts)` convenience map; the Rust client exposes `parse_structured(...)` returning a `StructuredParse` with `flags` and `provided_flags`.

Generated shell completions are subcommand-aware for configs with `[commands.*]`: the static script resolves the active command scope from the words typed so far, then offers that scope's options (own flags plus unshadowed inherited ones), its child commands, and per-scope bool values — still with zero flags2env or TOML reads at completion time.

Generated types (`flags2env generate <language>`) describe every env key the parser may emit: command-scoped flag envs are included as optional fields (their defaults only apply when their command runs), each command's marker `env` becomes an optional boolean, and `parse.command_env` becomes an optional string. `flags2env coerce`-style APIs (`f2e_coerce_json`) accept the marker envs as booleans and the command path env as a string.

For CLIs with subcommands that you do not want to model as `[commands.*]` tables, add a `[parse]` table to make parsing stricter or to surface ignored tokens:

```toml
[parse]
require_equals = true
stop_at_first_positional = true
positionals_env = "FLAGS2ENV_POSITIONALS"
unknown_options_env = "FLAGS2ENV_UNKNOWN_OPTIONS"
errors_env = "FLAGS2ENV_PARSE_ERRORS"
allow_unknown = false
```

`require_equals = true` means non-boolean values must be inline (`--port=8080`, `-p8080`, or `-p=8080`) instead of separated (`--port 8080`). `stop_at_first_positional = true` stops scanning once a non-flag token such as `exec` or `run` is found. `positionals_env`, `unknown_options_env`, and `errors_env` store JSON-array strings in the returned map; omit them if you want those tokens ignored.

Set `[parse] allow_unknown = true`, pass `--allow-unknown`, or set `FLAGS2ENV_ALLOW_UNKNOWN=1` to suppress unknown-option collection for flags that belong to downstream code. The older `allow_hidden`, `--allow-hidden`, and `FLAGS2ENV_ALLOW_HIDDEN` spellings are accepted as aliases. A bare `--` always stops flags2env parsing; later tokens are treated as positionals when `positionals_env` is configured.

Add `help` or `description` on any flag to populate the generated help table. Add `[help] url = "https://..."` to print a support or docs URL under the `--help` menu. Use `[help] columns = ["options", "env", "description"]` to choose table columns, or `[help] exclude = ["default"]` to remove columns from the default set. `options` is always kept so every row still identifies the flag.

## Which `.env` files are read

By default `./.env` in the working directory is read if it is present, and
nothing else — no upward walk, and no lookup beside an explicitly passed config
path. `[env] files` changes that:

```toml
[env]
files = [".env", ".env.local"]
```

The list **replaces** the default, and the files are read in order, so a later
file's value wins for a key both define — `[".env", ".env.local"]` behaves the
way the names suggest. Paths are relative to the working directory; a
subdirectory such as `config/.env` is fine, but an absolute path or a `..`
segment is an audit error rather than a silent fallback, because only the
working directory is ever read.

Declaring an empty list means read none at all:

```toml
[env]
files = []          # same effect as `load = false`
```

`[env] load = false` and `FLAGS2ENV_DOTENV=0` still switch loading off
entirely; the config declaration wins, because the environment variable can
only turn loading off, never on.

## Terminals

Three behaviours depend on whether a terminal is attached, and all three are
defined rather than incidental.

### `requires_tty` — flags that need someone there

A flag like `--interactive` is meaningless without a terminal, and a CLI that
honours it anyway waits forever on input nobody can give — in CI, in cron, or on
the far side of a pipe. Declare the requirement and flags2env refuses the flag
instead:

```toml
[flags.interactive]
env = "APP_INTERACTIVE"
aliases = ["interactive"]
type = "bool"
requires_tty = true          # stdin and stderr, outside CI, not TERM=dumb

[flags.progress]
env = "APP_PROGRESS"
aliases = ["progress"]
type = "bool"
requires_tty = "stdout"      # only stdout has to be a terminal
```

`requires_tty` accepts `true` (or `prompt`), `false`, `stdin`, `stdout`, and
`stderr`. `true` mirrors `canPrompt` below: **stdin and stderr** must be
terminals, outside CI, with `TERM` not `dumb`. Stdout is deliberately not
required — data is often piped while the prompt stays on stderr.

Refusal is reported through the normal errors channel, so every client already
fails closed on it:

```
$ app --interactive | cat
flags.interactive requires an interactive terminal; stdin and stderr must be a
terminal, outside CI, with TERM set
```

Three deliberate details:

- **Turning it off is always legal.** `--no-interactive` is exactly how a caller
  says "do not prompt", so it never needs a terminal.
- **Short bundles count.** `-qi` checks the `i` just as `--interactive` would.
- **It applies to argv, not to the environment.** A value in the environment or
  a `.env` is ambient configuration, not someone asking for a prompt right now,
  and failing a CI job because `APP_INTERACTIVE` was inherited would be worse
  than the problem. `flags2env doctor` warns when a `.env` sets a
  `requires_tty` flag, so the bypass is visible rather than silent.

A `requires_tty` value that is not one of the six spellings is an **audit
error**, because a terminal check that silently is not one is worse than none.

### `flags2env context` — what this process can see

```sh
$ flags2env context
{ "stdinTty": true, "stdoutTty": false, "canPrompt": true, "outputMode": "plain", ... }
```

Run it where the real command runs to answer "why did my CLI refuse to prompt".
`columns` is `null` when the terminal size is unknown — a pty with no window
size set, for instance — so consumers must handle that.

The `F2E_FORCE_STDIN_TTY`, `F2E_FORCE_STDOUT_TTY`, `F2E_FORCE_STDERR_TTY`, and
`F2E_FORCE_CI` variables override detection, which is how the test suite pins
this behaviour without allocating a pty.

### Help table width

| Situation | Width |
|-----------|-------|
| `COLUMNS` set to a value in 1–1000 | that value |
| otherwise, stdout is a terminal | the terminal's width |
| otherwise (piped, redirected, CI) | **80** |

Clamped to 40–160 in every case. The last row is the one that matters: piped
`--help` is byte-identical regardless of the terminal that launched it, so
golden-file tests and diffs are stable. `COLUMNS` remains the explicit override
for the cases that want something else.

## `flags2env doctor`

`audit` checks `.cli-flags.toml`, and `audit env` compares one `.env` against
it. `doctor` answers the question you actually have when a value does not
arrive — *is my `.env` being read, and does it say what I think it says?* It
reads every file `[env] files` names (or `./.env`) and reports two classes of
problem:

```sh
flags2env doctor                 # the discovered .cli-flags.toml
flags2env doctor path/to/.cli-flags.toml
```

**Malformed** — lines the loader cannot use and silently skips today:

```
.env:4: APP_HOST has an unterminated quote, so the quote becomes part of the value
.env:5: no "=", so this line is not an assignment and is skipped
.env:6: "app-host" is not a valid environment variable name, so it is skipped
.env:8: "export" with nothing after it
```

**Ambiguous** — lines that read as configuration but do something else, or
nothing:

```
.env:3: APP_PORT was already assigned at line 2; the later value wins
.env:7: TYPO_HOST is not declared by any [flags.*] env and is not in env.ignore, so it is read by nothing
.env.local:1: APP_HOST is also set in .env:2; .env.local wins because it is read later
.env is readable by group or other (mode 644); a .env usually holds secrets
```

Malformed lines are errors and exit non-zero, so `doctor` works as a pre-commit
or CI gate. Ambiguity and permissions are warnings: worth seeing, not worth
blocking a commit over. Keys listed in `[env] ignore` are not reported as
undeclared.

**Values are never printed** — only key names and positions. A `.env` holds
secrets, and this report is exactly the kind of output that gets pasted into an
issue.

Ignore project-specific env keys during `.env` audits with an `[env]` table:

```toml
[env]
ignore = ["DATABASE_URL", "CI", "VERCEL_ENV"]
```

Ignored keys are neither required from `.cli-flags.toml` nor rejected from `.env`.

This repository's own root `.cli-flags.toml` is intentionally library-shaped for CLI smoke tests and maps to `FLAGS2ENV_*` variables. App-shaped examples like `PORT` and `NODE_ENV` live under `tests/fixtures/`.

Supported CLI forms:

```sh
--port 8080
--port=8080
--listen-port 8080
-p 8080
-p8080
--debug
--debug=false
--debug=t
--debug 0
--no-debug
-d
-d=1
-d0
-dv
```

Every parsed value is returned as a string. Declared types validate CLI values without changing that env-compatible result: `integer`/`int`, `double`/`float`/`number`, `bool`, `json`, `array`/`list`, and `map`/`object` are supported. `array` and `map` values use JSON syntax and enforce the top-level container. Integers are signed base-10 values that fit in C's `long long`; doubles must be finite. Invalid or out-of-range values are not applied. If a typed value is invalid, declare `errors_env = "FLAGS2ENV_PARSE_ERRORS"` in `[parse]` to receive a JSON-array string of validation errors.

Separated values do not consume the next token when it looks like another option. For example, `--port --unknown` leaves `PORT` unchanged and lets `--unknown` be ignored or reported through `unknown_options_env`. Use equals for string values that begin with `-`, such as `--host=-internal`; typed negative numbers like `--retries -1` are accepted in separated form.

Boolean flags return `"true"` or `"false"`. A bare boolean flag like `--debug` or `-d` means `"true"`. Canonical `true` and `false` are always accepted as boolean values. Shorthand values like `t`, `f`, `1`, and `0` only work when the flag declares them in `true_aliases` or `false_aliases`. Separated boolean values like `--debug false` are accepted only when separated values are enabled, which is the default; inline forms like `--debug=false` work in both modes.

When the exact `--help` token is present, the native CLI prints a generated table instead of JSON. The table is generated by the C core from `.cli-flags.toml`: wide terminals get separate `Option(s)`, `Env`, `Type`, `Default`, and `Description` columns, while narrower terminals collapse flag metadata into fewer columns. Native table printing locks stdio on POSIX before writing and flushing to reduce output interleaving.

## Build

```sh
make all
make borrow-check
make test
```

`make test` runs the C smoke tests plus `make borrow-check`. The borrow check uses Clang's static analyzer with ownership annotations on heap-returning C APIs, so returned strings must be released through `f2e_free`.

Outputs:

```text
build/libflags2env.dylib  # macOS
build/libflags2env.so     # Linux
build/flags2env.dll       # Windows
build/libflags2env.a
build/flags2env
```

## Zed package

The Zed package is a universal executable package, not a replacement for a
project's npm, pnpm, Maven, RubyGems, Python, or Go dependencies. It installs
under the project-local `zed_modules/` tree and exposes `flags2env` through
`zed_modules/.bin` and `zed run`.

In an existing project without a `.zpkg.toml`, install it without changing the
native package manifest:

```sh
zed install flags-2-env/flags-2-env@^0.3 \
  --do-not-write-new-manifest \
  --allow-build \
  --adapter none
zed run flags2env -- audit .cli-flags.toml
```

`--allow-build` explicitly permits the package's small C build. `--adapter
none` keeps this universal CLI out of `node_modules`, Java classpaths, Python
paths, Go workspaces, and other language-specific dependency wiring.

For a manifest-backed Zed project, declare the dependency and universal
adapter once:

```toml
[dependencies]
"flags-2-env/flags-2-env" = "^0.3"

[install]
adapter = "none"
```

Then run `zed install --allow-build`. Both install forms retain the native
project structure, write an integrity-pinned `.zpkg.lock`, and support frozen
reinstallation with `zed install --frozen --do-not-write-new-manifest --allow-build
--adapter none` for manifestless consumers.

Until the end of 2026-08-19, the compatibility coordinate
`oresoftware/flags-2-env@^0.3` resolves a separately published artifact from
the same tagged source commit. New manifests should use the canonical
`flags-2-env/flags-2-env` coordinate.

`tests/flags-2-env-e2e.sh` round-trips the exact publishable artifact through a
temporary file registry and installs it into npm, nested pnpm, Maven, Ruby,
Python virtualenv, Go module, standalone JAR, and plain Bash layouts. It checks
symlink and copy installs, `zed run`, the Bash helper, native-manifest
non-interference, and frozen lockfile restoration.

Export parsed flags directly into a shell function or script:

```bash
source ./clients/bash/flags2env.bash

my_program() {
  FLAGS2ENV_CONFIG=.cli-flags.toml flags2env_apply "$@"
  command my_program_impl "$@"
}
```

```zsh
#!/usr/bin/env zsh
source ./clients/zsh/flags2env.zsh
FLAGS2ENV_CONFIG=.cli-flags.toml flags2env_apply "$@"
```

Both shell clients call the native `flags2env shell-env` command and `eval`
shell-quoted `export KEY='value'` lines in the current shell. Set
`FLAGS2ENV_BIN` when the CLI is not on `PATH`.

The shared library exposes:

```c
char *f2e_parse_process_from_file(const char *config_path);
char *f2e_parse_json_argv_from_file(const char *config_path, const char *argv_json);
int f2e_is_help_requested_json_argv(const char *argv_json);
char *f2e_help_table_from_file(const char *config_path, const char *command_name, int terminal_columns);
int f2e_print_table_from_file(const char *config_path, const char *command_name, int terminal_columns);
char *f2e_audit_config_from_file(const char *config_path);
char *f2e_completion_script_from_file(const char *config_path, const char *shell, const char *command_name);
char *f2e_generate_types_from_file(const char *config_path, const char *language, const char *type_name);
char *f2e_coerce_json_from_file(const char *config_path, const char *values_json);
char *f2e_audit_env_file_from_file(const char *config_path, const char *env_path);
void f2e_free(char *value);
```

`f2e_parse_process_from_file` asks the host OS for the current process command line. This is available on macOS, Linux, and Windows. `argv_json` is a JSON array of strings for callers that want to pass a manually edited argv. Return values are heap-allocated JSON object strings and must be released with `f2e_free`.

Audit a config before parsing or in CI:

```sh
build/flags2env audit .cli-flags.toml
scripts/audit-changed-cli-flags.sh
```

The audit fails on ambiguous long aliases, duplicate short flags, duplicate env targets, `--no-*` namespace clashes, and conflicting boolean value aliases.

Generate shell completions from the same `.cli-flags.toml` file:

```sh
build/flags2env completion bash mycli .cli-flags.toml > mycli.bash
build/flags2env completion zsh mycli .cli-flags.toml > _mycli
```

The generated completion scripts are static. They do not invoke `flags2env`, read TOML, or do filesystem lookup while the shell is completing, so tab completion stays fast.

## Typed Config Generation

Generate an importable env-keyed type from `.cli-flags.toml`:

```sh
mkdir -p generated/typescript generated/python generated/go generated/dart generated/json-schema
f2e generate typescript .cli-flags.toml --name CliStuff --output generated/typescript/cli-interfaces.ts
f2e generate python .cli-flags.toml --name CliStuff --output generated/python/cli_interfaces.py
f2e generate go .cli-flags.toml --name CliStuff --output generated/go/cli_config.go
f2e generate dart .cli-flags.toml --name CliStuff --output generated/dart/env.dart
f2e generate json-schema .cli-flags.toml --name CliStuff --output generated/json-schema/env.schema.json
```

`--output` writes the file and freezes it with `chmod a-w`. Do not hand-edit generated files; change `.cli-flags.toml` and regenerate. Directories and `generated/README.md` stay writable. Git does not persist the write bit, so re-run `python3 scripts/check-generated-contract.py --freeze` after clone, or generate again with `--output`.

JSON Schema is a **runtime cross-check**, not the primary generator input (that remains `.cli-flags.toml`). `scripts/check-generated-contract.py` validates fixtures against the generated schema at runtime (valid instances must pass, invalid must fail) and compares schema property names to flag `env` keys. Compile-time types alone are not the contract.

Shell redirects (`> generated/dart/env.dart`) still work but do not freeze the file; prefer `--output`.

The native generator supports TypeScript (`ts`), Python (`py`), Go (`golang`), Rust (`rs`), Java, C# (`cs`/`dotnet`), Dart, and JSON Schema. Properties use the declared `env` names. A flag with a default is required in the generated type because `coerce()` can always supply it; a flag without a default is optional.

For Node.js/TypeScript, merge the raw env and CLI maps first, then cross the explicit typed boundary:

```ts
import * as f2e from "@oresoftware/f2e";
import type { CliStuff } from "../generated/cli-interfaces.js";

const overrides = f2e.parseOverridesFromArgs(process.argv);
const config = { ...process.env, ...overrides };
const typedConfig: CliStuff = f2e.coerce(config);
```

`parseOverridesFromArgs()` remains string-valued, omits schema defaults, and throws a value-redacted `TypeError` when argv contains unknown options or invalid values. It is argv-only, so the merge above sees no `./.env`; use `parseStructured()` and its `dotenv` / `dotenvOverrides` channels when the project keeps one, as shown in [Env Files](#env-files). Use `parseStructured()` too when the caller needs the detailed diagnostic channels. The older `parseFromArgs()` retains its default-bearing behavior for compatibility and should not be spread over `process.env` when defaults are declared. `coerce()` reads the same `.cli-flags.toml` used by generation, keeps only declared env keys, applies schema defaults, converts integers, doubles, booleans, JSON, arrays, and maps, and throws `CoercionError` with all invalid keys when conversion fails. Each conversion error identifies the env key, its `[flags.*]` table, the declared type, the received JSON kind, and how to repair either the value or declaration.

The generated TypeScript interface is erased at runtime; it does not tell `coerce()` what to do. The TOML `type` field is the runtime source of truth. When `type` is omitted, flags2env deterministically treats the value as a string, even if a default such as `123` looks numeric. It never guesses independently from each process value, because that could make generated types disagree with runtime values. Errors already collected in the configured `[parse] errors_env` are carried into the same exception. Pass `{ configPath: "path/to/.cli-flags.toml" }` as the second argument when config discovery is not appropriate.

The JSON Schema target is a Draft 2020-12 description of the post-`coerce()` object, not the raw `process.env` input. Its `default` keywords document the defaults that `coerce()` applies; JSON Schema validators do not insert those values themselves. The schema rejects undeclared properties, marks default-backed output keys as required, and includes `x-flags2env-*` metadata that maps properties back to their TOML declarations.

The generated-code Docker matrix under `tests/codegen-docker/` compiles and runs these interfaces in Node.js, TypeScript, Bun, Deno, Go, Rust, Dart, Java, Python, and C#. It also checks the generated JSON Schema against the official Draft 2020-12 meta-schema before exercising valid and invalid instances.

Completion command names are reduced to a safe basename such as `mycli`, and command names, aliases, short flags, boolean value aliases, and env keys are audited for shell-safe characters before scripts are emitted.

Install completions into user-level shell locations:

```sh
build/flags2env completion install bash mycli .cli-flags.toml
build/flags2env completion install zsh mycli .cli-flags.toml
```

Bash installs to `${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion/completions`. Zsh installs to `${ZDOTDIR:-$HOME}/.zfunc` and adds an idempotent `fpath`/`compinit` block to `.zshrc`. For tests or custom installs, set `F2E_COMPLETION_DIR`, `F2E_BASH_COMPLETION_DIR`, `F2E_ZSH_COMPLETION_DIR`, `F2E_BASHRC`, or `F2E_ZSHRC`.

Audit a `.env` file against the env keys declared in `.cli-flags.toml`:

```sh
build/flags2env audit env .cli-flags.toml .env
build/flags2env env-audit .cli-flags.toml .env
```

Unknown `.env` keys are errors unless they are listed in `[env] ignore`. Duplicate keys, invalid `.env` lines, and non-ignored TOML env keys missing from `.env` are warnings.

Check a local `.env` file against the env keys declared by `.cli-flags.toml`:

```sh
build/flags2env env-audit .cli-flags.toml .env
```

When the `.env` path is omitted, `flags2env` checks the `.env` file next to the selected `.cli-flags.toml`. Unknown `.env` keys are errors unless they are listed in `[env] ignore`; non-ignored TOML-declared env keys missing from `.env` are warnings because they may be optional, defaulted, or supplied by deployment infrastructure.

## Env Files

Parsing reads `./.env` from the process working directory. A value can come from three sources, ranked highest first by default:

| Source | Where it comes from |
| --- | --- |
| `flags` | argv |
| `env_shell` | the live process environment |
| `env_file` | `./.env` |

Below all three sits the `[flags.*] default` declared in `.cli-flags.toml`. [`[order-of-preference]`](#changing-the-order-per-key) re-ranks the sources per env key.

```sh
$ cat .env
PORT=8080
HOST="db.internal"

$ mycli serve
{"PORT":"8080","HOST":"db.internal","DEBUG":"false"}

$ PORT=7777 mycli serve            # a live variable outranks the file
{"PORT":"7777","HOST":"db.internal","DEBUG":"false"}

$ PORT=7777 mycli serve --port 9999  # argv outranks both
{"PORT":"9999","HOST":"db.internal","DEBUG":"false"}
```

Only `./.env` is read. There is no upward walk the way config discovery has one, and no lookup next to an explicitly passed config path, so a `--config` pointing into another tree never drags that tree's `.env` along. A `./.env` symlink is followed like a regular file, which is how a repo can point at a shared or generated env file.

Only keys declared by a `[flags.*] env` are taken from the file. Undeclared keys stay out of the parsed map and are never copied into a returned JSON document. Parse-derived keys — the command path, per-command markers, positionals, unknown options, and parse errors — are never read from `.env` or the environment either, so neither can forge what argv actually contained.

A `.env` value that does not fit its declared type is reported through `[parse] errors_env` and skipped, leaving the value below it in the order. A live environment value that does not fit is skipped silently: the ambient environment is not the parser's to validate, and a stray `DEBUG=verbose` in someone's shell should not turn into a parse error.

### Changing the order per key

The three sources are named `flags`, `env_shell`, and `env_file`. `[order-of-preference]` re-ranks them for individual env keys, highest first:

```toml
[order-of-preference]
MY_ENV_1 = (env_file, env_shell, flags)
MY_ENV_2 = (env_shell, flags)
MY_ENV_3 = (env_file, flags)
```

Only keys that deviate from the default need an entry; everything else keeps `flags > env_shell > env_file`. Brackets work as well as parentheses (`MY_ENV_1 = [env_file, env_shell, flags]`), and entries may be bare or quoted.

A list does not have to name every source. Whatever it omits is appended in default order, so `MY_ENV_2 = (env_shell, flags)` resolves to `env_shell > flags > env_file`, and `MY_ENV_3 = (env_file, flags)` resolves to `env_file > flags > env_shell`. At least two sources are required, since one says nothing about precedence.

Note that `flags` can be ranked last, as `MY_ENV_1` does. That pins a value against the command line: `--my-env-1` will not override what `.env` supplies.

`[env] order` sets a config-wide default for keys the table omits:

```toml
[env]
order = (env_file, env_shell, flags)
```

Two shorthands remain for the common case of lifting `.env` over the shell while argv still wins — per flag, or for the whole config:

```toml
[flags.token]
env = "API_TOKEN"
type = "string"
dotenv_override = true

[env]
override = true
```

Most specific declaration wins: an `[order-of-preference]` entry, then the flag's `dotenv_override`, then `[env] order`, then `[env] override`, then the default. `flags2env audit` rejects unknown source names, repeated sources, single-entry lists, and entries for env keys no `[flags.*]` table declares.

Turn file loading off entirely with `[env] load = false`, or per process with `FLAGS2ENV_DOTENV=0`.

Because `./.env` comes from the ambient working directory, long-running or privileged consumers should declare `[env] load = false` for the same reason they do not discover `.cli-flags.toml` from the CWD — see [consumer compliance](docs/consumer-compliance.md#trusted-contract-discovery). That declaration is authoritative: `FLAGS2ENV_DOTENV` can only switch loading off, never back on.

Callers that merge channels by hand instead of using the resolved map get the split they need from `parseStructured()`: `dotenv` holds the values that lose to the environment and `dotenvOverrides` the ones that win it, so a re-ranked `.env` survives a flat merge:

```ts
const s = f2e.parseStructured(process.argv);
const config = { ...s.dotenv, ...process.env, ...s.dotenvOverrides, ...s.providedFlags };
```

That reproduces `flags` while `flags` still outranks both env sources. `s.sourceOrder` reports the resolved order for every key that deviates from the default; if any of them ranks `flags` below an env source, the spread above cannot express it and `s.flags` is the value to use.

## Shell Completion

Generate static bash or zsh completions for an end-product CLI:

```sh
build/flags2env completion bash mycli .cli-flags.toml > completions/mycli.bash
build/flags2env completion zsh mycli .cli-flags.toml > completions/_mycli
```

The generated scripts are intentionally static and fast: shell completion does not run `flags2env`, read TOML, or load the native library at tab-completion time.

Install completions locally:

```sh
build/flags2env install-completion bash mycli .cli-flags.toml
build/flags2env install-completion zsh mycli .cli-flags.toml
```

Bash installs to `${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion/completions/<command>` and adds an idempotent source block to `~/.bashrc`. Zsh installs to `${ZDOTDIR:-$HOME}/.zfunc/_<command>` and adds an idempotent `fpath`/`compinit` block to `~/.zshrc`. Tests and package scripts can override these paths with `F2E_COMPLETION_DIR`, `F2E_BASH_COMPLETION_DIR`, `F2E_ZSH_COMPLETION_DIR`, `F2E_BASHRC`, and `F2E_ZSHRC`.

## Runtime Clients

The repository root is a Cargo workspace, so Rust applications can pin the
client directly to an immutable repository revision while releases continue to
publish the package from `clients/rust`:

```toml
[dependencies]
flags2env = { git = "https://github.com/flags-2-env/flags-2-env.git", rev = "<full-commit-sha>" }
```

CI installs that git dependency into an isolated consumer, executes the bundled
parser, and separately runs the package-only checks from `clients/rust`. A
source checkout is therefore not counted as integration until a downstream
binary resolves and executes the actual package.

Client sources live under `clients/<runtime>/`. For package publishing, render or copy only the target runtime client plus the C source or a platform-specific native artifact.

```sh
node scripts/render-client.mjs nodejs dist/nodejs
node scripts/render-client.mjs bun dist/bun
npm pack --dry-run
```

The root npm package is scaffolded as `@oresoftware/f2e`. It exports the Node client at `@oresoftware/f2e`, the Bun client at `@oresoftware/f2e/bun`, the Deno source at `@oresoftware/f2e/deno`, and `f2e` / `flags2env` CLI bins for completion generation, completion install, config audit, and `.env` audit. The package allowlist keeps npm focused on the JS/TS clients plus the C parser source needed for native builds.

In Node, `parse()` still behaves like a string map, but it also exposes non-enumerable help metadata:

```js
import { parse } from "@oresoftware/f2e";

const f2e = parse(process.argv);
if (f2e.isHelpMenu) {
  f2e.printTable();
  process.exit(0);
}

Object.assign(process.env, f2e);
```

`printTable()` generates the table lazily when called. For custom output streams, pass an object with `write()` and optionally `columns`.

Other language clients should be published through their own package ecosystems instead of being bundled into npm:

```text
Java/Kotlin/Scala/Groovy/Clojure: Maven-compatible registries, primarily Maven Central/Sonatype
Ruby: RubyGems, for example flags2env
Rust: crates.io, for example flags2env
Go: Go modules from github.com/oresoftware/flags-2-env/clients/golang
Python: PyPI, for example flags2env
PHP: Packagist, for example oresoftware/flags2env
Dart: pub.dev, for example flags2env
BEAM/Gleam: Hex packages for the Erlang, Elixir, and Gleam clients
Swift: SwiftPM through git tags
Haskell: Hackage
OCaml/ReasonML: opam
Perl: CPAN
Lua: LuaRocks
Nim: Nimble
Julia: Julia General Registry
R: CRAN or R-universe
.NET C#/F#: NuGet Gallery
C/C++/Fortran/Zig/Crystal/MATLAB/Solidity: source packages or git-tagged releases
Bash/Zsh: source packages, Homebrew-installed shell helpers, or git-tagged releases
```

Every client folder has a `publish.sh` wrapper. It defaults to a dry-run command printout and only publishes when passed `--release`. See `docs/plan.md` for the coverage plan and `clients/PUBLISHING.md` for package manifest controls such as `.npmignore`, `MANIFEST.in`, `.gemspec` file lists, Composer archive excludes, NuGet `.nuspec` files, `.pubignore`, `Package.swift` excludes, Mix package files, Cabal manifests, opam metadata, CPAN `MANIFEST.SKIP`, LuaRocks rockspecs, Nimble manifests, Julia `Project.toml`, and the Homebrew formula under `packaging/homebrew/Formula/`.

The native CLI can be distributed through Homebrew with
`packaging/homebrew/Formula/flags2env.rb`. Run
`scripts/publish-homebrew.sh --dry-run` to see the local Homebrew install, test,
and audit commands; use `--release` on a machine with Homebrew configured. The
C, Bash, and Zsh client `publish.sh` wrappers also surface that Homebrew release
path.

BEAM clients share the Erlang NIF in `clients/erlang/c_src/flags2env_nif.c`; compile it with Erlang headers plus `clients/erlang/c_src/parser.c` into `priv/flags2env_nif.so`. On macOS, add `-undefined dynamic_lookup` when linking the NIF. Gleam uses `clients/gleam/flags2env_native.erl` as a native shim so its public module can still be named `flags2env` without colliding with the NIF module. Java uses `clients/java/native/flags2env_jni.c`; Kotlin, Scala, Groovy, and Clojure build facade packages over that Java bridge.

Node, Bun, and Deno use syntax-highlighted source files instead of `.ejs` templates:

```text
clients/nodejs/lib.mjs
clients/nodejs/lib.cjs
clients/nodejs/lib.ts
clients/bun/lib.mjs
clients/bun/lib.cjs
clients/bun/lib.ts
clients/deno/lib.ts
```

Node package exports include both ESM and CommonJS entrypoints. For webpack, Turbopack, and other bundlers, keep the native addon or shared library external to the browser bundle and load it at runtime.

## Client Tests

The original smoke-tested clients have Dockerfiles that run on Linux:

```sh
docker build -f clients/nodejs/Dockerfile -t flags2env-nodejs .
docker run --rm flags2env-nodejs
scripts/test-docker-clients.sh nodejs bun deno
```

Swap `nodejs` for `c`, `bun`, `deno`, `dart`, `golang`, `python`, `ruby`, `php`, `rust`, `swift`, `erlang`, `elixir`, `gleam`, or `java`. Docker can test Linux userland and can vary CPU architecture with `--platform`, but it cannot faithfully emulate macOS or Windows kernels; use native CI runners for those.

Newer scaffolded clients have Docker-backed syntax/package checks in:

```sh
scripts/docker-check-new-clients.sh
scripts/docker-check-new-clients.sh --full
```

The default set checks practical local coverage. `--full` adds heavier Haskell,
OCaml/opam, Julia, and JVM facade checks intended for CI runners.

The repository also includes `.github/workflows/cli-flags-audit.yml`, a GitHub Actions bot that runs when any `.cli-flags.toml` or adjacent `.env` changes and reports audit failures as PR annotations. When a config has an adjacent `.env`, the bot also runs `flags2env audit env` so the same `[env] ignore` list controls CI drift checks.

## Usage

In every language, the merge rule is:

```text
combined = env map + parsed CLI map
```

When the same key exists in both maps, the parsed CLI value wins.

Most clients expose two parse modes:

```text
parseProcess()  # read the current process argv through the C library
parse(argv)     # explicitly pass argv after slicing, popping, or rewriting
```

The examples below keep the raw combined map as strings first, then show a typed end-values module. Boolean flags already return canonical `"true"` or `"false"`, so typed boolean conversion is a direct comparison to `"true"`.

<details>
<summary>Node.js</summary>

```js
import * as f2e from "@oresoftware/f2e";

function getEnvMap(argv = process.argv) {
  const envMap = process.env;
  const cli = f2e.parse(argv);
  return { ...envMap, ...cli };
}

const combined = getEnvMap();
```

```ts
import * as f2e from "@oresoftware/f2e";
import type { CliStuff } from "../generated/cli-interfaces.js";

const overrides = f2e.parseOverridesFromArgs(process.argv);
const combined = { ...process.env, ...overrides };
const appEnv: CliStuff = f2e.coerce(combined);

export default appEnv;
```

</details>

<details>
<summary>Bun</summary>

```js
import * as f2e from "@oresoftware/f2e/bun";

function getEnvMap(argv = Bun.argv) {
  const envMap = process.env;
  const cli = f2e.parse(argv);
  return { ...envMap, ...cli };
}

const combined = getEnvMap();
```

```ts
import * as f2e from "@oresoftware/f2e/bun";

type AppEnv = {
  nodeEnv: string;
  port: number;
  isDebug: boolean;
};

function getEnvMap(argv = Bun.argv): Record<string, string> {
  return { ...process.env, ...f2e.parse(argv) };
}

const combined = getEnvMap();

const appEnv: AppEnv = {
  nodeEnv: combined.NODE_ENV ?? "development",
  port: Number.parseInt(combined.PORT ?? "3000", 10),
  isDebug: combined.DEBUG === "true",
};

export default appEnv;
```

</details>

<details>
<summary>Deno</summary>

```ts
import * as f2e from "./clients/deno/mod.ts";

function getEnvMap(argv: string[] = Deno.args): Record<string, string> {
  const envMap = f2e.envMap();
  const cli = f2e.parse(argv);
  return { ...envMap, ...cli };
}

const combined = getEnvMap();
```

```ts
import * as f2e from "./clients/deno/mod.ts";

export type AppEnv = {
  nodeEnv: string;
  port: number;
  isDebug: boolean;
};

export function getEnvMap(argv: string[] = Deno.args): Record<string, string> {
  return { ...f2e.envMap(), ...f2e.parse(argv) };
}

const combined = getEnvMap();

const appEnv: AppEnv = {
  nodeEnv: combined.NODE_ENV ?? "development",
  port: Number.parseInt(combined.PORT ?? "3000", 10),
  isDebug: combined.DEBUG === "true",
};

export default appEnv;
```

</details>

<details>
<summary>C</summary>

```c
#include "clients/c/lib.h"
#include <stdio.h>
#include <string.h>

F2EMap env_map_from_envp(char *envp[]) {
  F2EMap env_map = {0};

  for (size_t i = 0; envp[i]; i++) {
    char *eq = strchr(envp[i], '=');
    if (eq) {
      char key[512];
      size_t key_len = (size_t)(eq - envp[i]);
      if (key_len < sizeof(key)) {
        memcpy(key, envp[i], key_len);
        key[key_len] = '\0';
        f2e_map_set(&env_map, key, eq + 1);
      }
    }
  }

  return env_map;
}

F2EMap get_env_map(int argc, const char *const argv[], char *envp[]) {
  F2EMap env_map = env_map_from_envp(envp);
  F2EMap cli = {0};

  if (!f2e_client_parse(argc, argv, &cli)) {
    f2e_map_free(&env_map);
    return (F2EMap){0};
  }

  f2e_map_overlay(&env_map, &cli);
  f2e_map_free(&cli);

  F2EMap combined = env_map;
  return combined;
}

int main(int argc, const char *const argv[], char *envp[]) {
  F2EMap combined = get_env_map(argc, argv, envp);
  printf("PORT=%s\n", f2e_map_get(&combined, "PORT"));
  f2e_map_free(&combined);
  return 0;
}
```

```c
#include "clients/c/lib.h"
#include <stdlib.h>
#include <string.h>

typedef struct {
  const char *node_env;
  int port;
  int is_debug;
} AppEnv;

static const char *map_or_default(const F2EMap *map, const char *key, const char *fallback) {
  const char *value = f2e_map_get(map, key);
  return value ? value : fallback;
}

AppEnv app_env_from_map(const F2EMap *combined) {
  const char *debug = map_or_default(combined, "DEBUG", "false");

  return (AppEnv){
    .node_env = map_or_default(combined, "NODE_ENV", "development"),
    .port = atoi(map_or_default(combined, "PORT", "3000")),
    .is_debug = strcmp(debug, "true") == 0,
  };
}
```

</details>

<details>
<summary>Dart</summary>

```dart
import 'dart:io';
import 'package:flags2env/flags2env.dart';

Map<String, String> getEnvMap(List<String> args) {
  final f2e = Flags2Env.load('./build/libflags2env.dylib');
  final cli = f2e.parse(args);
  return <String, String>{...Platform.environment, ...cli};
}

void main(List<String> args) {
  final combined = getEnvMap(args);
}
```

```dart
import 'dart:io';
import 'package:flags2env/flags2env.dart';

class AppEnv {
  const AppEnv({
    required this.nodeEnv,
    required this.port,
    required this.isDebug,
  });

  final String nodeEnv;
  final int port;
  final bool isDebug;

  factory AppEnv.fromMap(Map<String, String> combined) {
    return AppEnv(
      nodeEnv: combined['NODE_ENV'] ?? 'development',
      port: int.tryParse(combined['PORT'] ?? '') ?? 3000,
      isDebug: combined['DEBUG'] == 'true',
    );
  }
}

AppEnv loadAppEnv(List<String> args) {
  final f2e = Flags2Env.load('./build/libflags2env.dylib');
  final combined = <String, String>{
    ...Platform.environment,
    ...f2e.parse(args),
  };

  return AppEnv.fromMap(combined);
}
```

</details>

<details>
<summary>Go</summary>

```go
package main

import (
	"os"
	"strings"

	flags2env "github.com/oresoftware/flags-2-env/clients/golang"
)

func envMap() map[string]string {
	env := map[string]string{}
	for _, entry := range os.Environ() {
		key, value, ok := strings.Cut(entry, "=")
		if ok {
			env[key] = value
		}
	}
	return env
}

func mergeMaps(env map[string]string, cli map[string]string) map[string]string {
	combined := make(map[string]string, len(env)+len(cli))
	for key, value := range env {
		combined[key] = value
	}
	for key, value := range cli {
		combined[key] = value
	}
	return combined
}

func getEnvMap(args []string) (map[string]string, error) {
	cli, err := flags2env.Parse(args)
	if err != nil {
		return nil, err
	}
	return mergeMaps(envMap(), cli), nil
}

func main() {
	combined, err := getEnvMap(os.Args)
	if err != nil {
		panic(err)
	}
	_ = combined
}
```

```go
package config

import (
	"os"
	"strconv"
	"strings"

	flags2env "github.com/oresoftware/flags-2-env/clients/golang"
)

type AppEnv struct {
	NodeEnv string
	Port    int
	Debug   bool
}

func Load(args []string) (AppEnv, error) {
	cli, err := flags2env.Parse(args)
	if err != nil {
		return AppEnv{}, err
	}

	combined := map[string]string{}
	for key, value := range envMap() {
		combined[key] = value
	}
	for key, value := range cli {
		combined[key] = value
	}

	port, err := strconv.Atoi(valueOr(combined, "PORT", "3000"))
	if err != nil {
		return AppEnv{}, err
	}

	return AppEnv{
		NodeEnv: valueOr(combined, "NODE_ENV", "development"),
		Port:    port,
		Debug:   combined["DEBUG"] == "true",
	}, nil
}

func envMap() map[string]string {
	env := map[string]string{}
	for _, entry := range os.Environ() {
		if key, value, ok := strings.Cut(entry, "="); ok {
			env[key] = value
		}
	}
	return env
}

func valueOr(mapValue map[string]string, key string, fallback string) string {
	if value, ok := mapValue[key]; ok {
		return value
	}
	return fallback
}
```

</details>

<details>
<summary>Erlang</summary>

```erlang
-module(my_app).
-export([get_env_map/0, main/1]).

get_env_map() ->
  Env = flags2env:env_map(),
  Cli = flags2env:parse(init:get_plain_arguments()),
  maps:merge(Env, Cli).

main(_Args) ->
  Combined = get_env_map(),
  Combined.
```

```erlang
-module(my_app_config).
-export([load/0]).

-record(app_env, {
  node_env :: binary(),
  port :: integer(),
  is_debug :: boolean()
}).

load() ->
  Combined = maps:merge(flags2env:env_map(), flags2env:parse(init:get_plain_arguments())),
  #app_env{
    node_env = maps:get(<<"NODE_ENV">>, Combined, <<"development">>),
    port = binary_to_integer(maps:get(<<"PORT">>, Combined, <<"3000">>)),
    is_debug = maps:get(<<"DEBUG">>, Combined, <<"false">>) =:= <<"true">>
  }.
```

</details>

<details>
<summary>Gleam</summary>

```gleam
import gleam/dict.{type Dict}
import flags2env

pub fn get_env_map() -> Dict(String, String) {
  let env_map = flags2env.env_map()
  let cli = flags2env.parse([])

  dict.fold(cli, env_map, fn(combined, key, value) {
    dict.insert(combined, key, value)
  })
}

pub fn main() {
  let _combined = get_env_map()
  Nil
}
```

```gleam
import gleam/dict.{type Dict}
import gleam/int
import gleam/result
import flags2env

pub type AppEnv {
  AppEnv(node_env: String, port: Int, is_debug: Bool)
}

pub fn load(argv: List(String)) -> AppEnv {
  let combined =
    dict.fold(flags2env.parse(argv), flags2env.env_map(), fn(map, key, value) {
      dict.insert(map, key, value)
    })

  let node_env = dict.get(combined, "NODE_ENV") |> result.unwrap("development")
  let port =
    dict.get(combined, "PORT")
    |> result.unwrap("3000")
    |> int.parse
    |> result.unwrap(3000)

  AppEnv(
    node_env: node_env,
    port: port,
    is_debug: dict.get(combined, "DEBUG") == Ok("true"),
  )
}
```

</details>

<details>
<summary>Elixir</summary>

```elixir
defmodule MyApp do
  def get_env_map(args) do
    env_map = System.get_env()
    cli = Flags2Env.parse(args)

    Map.merge(env_map, cli)
  end

  def main(args) do
    combined = get_env_map(args)
    combined
  end
end
```

```elixir
defmodule MyApp.Config do
  defstruct node_env: "development", port: 3000, debug?: false

  def load(args) do
    combined = Map.merge(System.get_env(), Flags2Env.parse(args))

    %__MODULE__{
      node_env: Map.get(combined, "NODE_ENV", "development"),
      port: parse_int(Map.get(combined, "PORT"), 3000),
      debug?: Map.get(combined, "DEBUG") == "true"
    }
  end

  defp parse_int(value, fallback) do
    case Integer.parse(to_string(value || "")) do
      {number, ""} -> number
      _ -> fallback
    end
  end
end
```

</details>

<details>
<summary>Java</summary>

```java
import com.oresoftware.flags2env.Flags2Env;
import java.util.Map;
import java.util.stream.Collectors;
import java.util.stream.Stream;

public final class Main {
  private static Map<String, String> getEnvMap(String[] args) {
    Map<String, String> envMap = System.getenv();
    Map<String, String> cli = Flags2Env.parse(args);

    return Stream.concat(envMap.entrySet().stream(), cli.entrySet().stream())
        .collect(Collectors.toMap(
            Map.Entry::getKey,
            Map.Entry::getValue,
            (env, cliValue) -> cliValue
        ));
  }

  public static void main(String[] args) {
    Map<String, String> combined = getEnvMap(args);
  }
}
```

```java
import com.oresoftware.flags2env.Flags2Env;
import java.util.Map;

public record AppEnv(String nodeEnv, int port, boolean debug) {
  public static AppEnv load(String[] args) {
    Map<String, String> combined = new java.util.HashMap<>(System.getenv());
    combined.putAll(Flags2Env.parse(args));

    return new AppEnv(
        combined.getOrDefault("NODE_ENV", "development"),
        Integer.parseInt(combined.getOrDefault("PORT", "3000")),
        "true".equals(combined.get("DEBUG"))
    );
  }
}
```

</details>

<details>
<summary>Python</summary>

```python
import os
import sys
from flags2env import Flags2Env

def get_env_map(argv=None):
    sdk = Flags2Env("./build/libflags2env.dylib")
    env_map = dict(os.environ)
    cli = sdk.parse(sys.argv if argv is None else argv)

    return {**env_map, **cli}

combined = get_env_map()
```

```python
from dataclasses import dataclass
import os
import sys
from flags2env import Flags2Env

@dataclass(frozen=True)
class AppEnv:
    node_env: str
    port: int
    is_debug: bool

def load_app_env(argv=None):
    sdk = Flags2Env("./build/libflags2env.dylib")
    combined = {**os.environ, **sdk.parse(sys.argv if argv is None else argv)}

    return AppEnv(
        node_env=combined.get("NODE_ENV", "development"),
        port=int(combined.get("PORT", "3000")),
        is_debug=combined.get("DEBUG") == "true",
    )

app_env = load_app_env()
```

</details>

<details>
<summary>Ruby</summary>

```ruby
require_relative "clients/ruby/lib"

def get_env_map(argv = ARGV)
  env_map = ENV.to_h
  cli = Flags2Env.parse(argv)

  env_map.merge(cli)
end

combined = get_env_map
```

```ruby
require_relative "clients/ruby/lib"

AppEnv = Struct.new(:node_env, :port, :is_debug, keyword_init: true)

def load_app_env(argv = ARGV)
  combined = ENV.to_h.merge(Flags2Env.parse(argv))

  AppEnv.new(
    node_env: combined.fetch("NODE_ENV", "development"),
    port: Integer(combined.fetch("PORT", "3000")),
    is_debug: combined["DEBUG"] == "true"
  )
end

app_env = load_app_env
```

</details>

<details>
<summary>PHP</summary>

```php
<?php
require __DIR__ . '/clients/php/lib.php';

$nativeLibrary = getenv('FLAGS2ENV_NATIVE_LIB') ?: match (PHP_OS_FAMILY) {
    'Darwin' => __DIR__ . '/build/libflags2env.dylib',
    'Windows' => __DIR__ . '/build/flags2env.dll',
    default => __DIR__ . '/build/libflags2env.so',
};
$f2e = new Flags2Env($nativeLibrary);

function get_env_map(Flags2Env $f2e, array $argv): array {
    $envMap = $_ENV;
    $cli = $f2e->parse($argv);

    return array_replace($envMap, $cli);
}

$combined = get_env_map($f2e, $argv);
```

```php
<?php
require __DIR__ . '/clients/php/lib.php';

final class AppEnv {
    public function __construct(
        public string $nodeEnv,
        public int $port,
        public bool $isDebug,
    ) {}
}

$nativeLibrary = getenv('FLAGS2ENV_NATIVE_LIB') ?: match (PHP_OS_FAMILY) {
    'Darwin' => __DIR__ . '/build/libflags2env.dylib',
    'Windows' => __DIR__ . '/build/flags2env.dll',
    default => __DIR__ . '/build/libflags2env.so',
};
$f2e = new Flags2Env($nativeLibrary);
$combined = array_replace($_ENV, $f2e->parse($argv));

$appEnv = new AppEnv(
    $combined['NODE_ENV'] ?? 'development',
    (int)($combined['PORT'] ?? '3000'),
    ($combined['DEBUG'] ?? 'false') === 'true',
);
```

</details>

<details>
<summary>Rust</summary>

```rust
use flags2env::Flags2Env;
use std::collections::HashMap;
use std::env;

fn get_env_map() -> Result<HashMap<String, String>, Box<dyn std::error::Error>> {
    let sdk = unsafe { Flags2Env::load(Some("./build/libflags2env.dylib"))? };
    let env_map: HashMap<String, String> = env::vars().collect();
    let argv: Vec<String> = env::args().collect();
    let cli = sdk.parse(&argv, None)?;

    let combined = env_map.into_iter().chain(cli).collect();
    Ok(combined)
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let combined = get_env_map()?;
    let _ = combined;
    Ok(())
}
```

Generate the typed shape with
`f2e generate rust .cli-flags.toml --name AppEnv > src/app_env.rs`, then let
the schema perform coercion:

```rust
mod app_env;

use app_env::AppEnv;
use flags2env::BundledFlags2Env;
use std::collections::HashMap;
use std::env;

pub fn load_app_env() -> Result<AppEnv, Box<dyn std::error::Error>> {
    let sdk = BundledFlags2Env::new();
    let mut combined: HashMap<String, String> = env::vars().collect();
    let argv: Vec<String> = env::args().collect();
    let parsed = sdk.parse_structured(&argv, None)?;
    combined.extend(parsed.provided_flags);

    Ok(sdk.coerce(&combined, None)?)
}
```

`coerce<T, V>()` is also available on the dynamically loaded `Flags2Env`
client. It accepts any serializable map, returns the requested deserializable
type, and reports all schema conversion failures through `CoercionError`.

</details>

<details>
<summary>Swift</summary>

```swift
import Foundation

func getEnvMap(args: [String] = CommandLine.arguments) throws -> [String: String] {
    let f2e = try Flags2Env(libraryPath: "./build/libflags2env.dylib")
    let envMap = ProcessInfo.processInfo.environment
    let cli = try f2e.parse(args)

    return envMap.merging(cli) { _, cli in cli }
}

let combined = try getEnvMap()
```

```swift
import Foundation

struct AppEnv {
    let nodeEnv: String
    let port: Int
    let isDebug: Bool

    init(_ combined: [String: String]) {
        nodeEnv = combined["NODE_ENV"] ?? "development"
        port = Int(combined["PORT"] ?? "") ?? 3000
        isDebug = combined["DEBUG"] == "true"
    }
}

func loadAppEnv(args: [String] = CommandLine.arguments) throws -> AppEnv {
    let f2e = try Flags2Env(libraryPath: "./build/libflags2env.dylib")
    let combined = ProcessInfo.processInfo.environment.merging(try f2e.parse(args)) { _, cli in cli }

    return AppEnv(combined)
}

let appEnv = try loadAppEnv()
```

</details>

## Parser Notes

The C parser owns config discovery. By default, it walks upward from the current working directory to find the nearest `.cli-flags.toml`, but refuses to use `$HOME/.cli-flags.toml` because that is likely accidental. Runtime clients should not reimplement this lookup; they should pass an explicit `configPath` only when the user asks for one.

Unknown flags and positional tokens are ignored unless `[parse]` declares `unknown_options_env` or `positionals_env`; `allow_unknown` suppresses unknown-option collection when downstream flags are expected. The parsed map is fully resolved: defaults from `.cli-flags.toml` sit at the bottom of the order described in [Env Files](#env-files), under `./.env`, the live environment, and argv. Merge it as-is rather than spreading it over an environment snapshot, which would re-apply values the parser already ranked.

When `[commands.*]` tables are declared, the parser resolves the subcommand path in a dry-run pass before applying defaults, so defaults are only emitted for global flags and the selected commands, and flag lookups always prefer the innermost command scope. The resolved path is reported under `parse.command_env` (default `FLAGS2ENV_COMMAND`, emitted as an empty string when no command is selected), and matched command tokens are consumed rather than recorded as positionals. While no command has matched yet, leading positionals such as the program name are skipped and do not trigger `stop_at_first_positional`.

### Short flag bundles

Single-dash flags combine the way `getopt` combines them, so the muscle-memory
spellings from everyday tools parse the way their authors meant them:

```console
$ ls -la              # -l -a: two booleans in one token
$ rm -rf tmp/         # -r -f
$ set -eo pipefail    # -e is boolean, then -o consumes "pipefail"
$ node -pe '1 + 1'    # -p is boolean, then -e consumes the script
$ git commit -am wip  # -a is boolean, then -m consumes the message
```

A token of boolean shorts sets each of them to `true`. One value-taking short
may end the bundle; it consumes the rest of the token as its value — with or
without an `=` — or, when the token ends there, the next argument:

```console
$ flags2env app -dv           # DEBUG=true VERBOSE=true
$ flags2env app -dvp 8080     # DEBUG=true VERBOSE=true PORT=8080
$ flags2env app -dvp8080      # same, inline value
$ flags2env app -dvp=8080     # same, inline value with equals
```

The rules, all of them the classic getopt ones plus this parser's existing
guarantees:

- A bundle is exactly its separated spelling: `-dv` means `-d -v`, and the two
  must agree in every case. That includes the trailing short, the only one
  adjacent to the next argument and so the only one that can consume a
  separated boolean value — `-dv false` sets `VERBOSE=false` just as
  `-d -v false` does. Only a value the trailing flag would itself accept is
  consumed, so a word like `archive.tar` stays a positional. `require_equals`
  suppresses this for bundles and lone shorts alike.
- Every character before the value flag must be a declared boolean short with
  an env target, resolvable in the active scope. A token containing a
  character that is not — a typo, a short belonging to a command that is not
  active, a short several commands declare differently — is not a bundle and
  applies nothing at all. Such a token is reported through
  `unknown_options_env` wherever the offending character sits, so a typo like
  `rm -rF` surfaces the same way `rm -Fr` does rather than vanishing. When the
  token has more than one character after the dash, `errors_env` also explains
  which character was at fault, instead of quoting the token's tail back as a
  value for its first flag. `allow_unknown` silences both channels.
- An explicit `=` makes an empty remainder a real value, so every spelling of
  "set this to the empty string" agrees: `--mode=`, `-m=` and `-dvm=` all
  export `NODE_ENV=""`. Without the `=`, a bundle ending at its value flag
  leaves that flag untouched.
- The value flag ends the bundle: characters after it belong to its value,
  never to more flags. Put the value-taking flag last — `node -pe '1 + 1'`
  works, while `-ep '1 + 1'` reads `p` as `-e`'s inline value, exactly as
  getopt would.
- A suffix that reads as a boolean value for the first flag keeps that
  meaning. With `true_aliases = ["t", "1"]`, `-dt` and `-d1` stay
  `DEBUG=true`, and `-dtrue` stays the canonical spelling — mixed bundling
  never reinterprets a previously valid token. (An all-boolean token such as
  `-dt` with `-t` itself a declared boolean short was already a bundle, and
  stays one.)
- `requires_tty` applies to every flag in a bundle: `-qi` checks the `i` just
  as `--interactive` would.
- Bundles resolve in the active command scope first, then its ancestors, so
  `gitish ci -am 'fix stuff'` applies the `commit` scope's `-a` and `-m`, and
  an inherited global `-v` may join the same bundle (`gitish ci -vam wip`).
  When no command is selected, the same globally-unique fallback that resolves
  a lone `-m` resolves it inside a bundle, which means one token may combine
  shorts declared by unrelated commands, and a character two commands declare
  differently resolves to neither. Write the command first if you want the
  scoped reading.
- With `[parse] require_equals = true`, the value must be inline
  (`-dvp8080` or `-dvp=8080`); a separated value stays positional, matching
  how a lone `-p 8080` behaves in that mode.
- A bundle whose *value* is rejected still applies its leading booleans, just
  as the equivalent separate tokens would: `-dvp x` sets `DEBUG` and `VERBOSE`
  and reports `flags.port value "x" is not a valid integer` through
  `errors_env`. Only an unreadable *token* applies nothing.

What `flags2env audit` checks about bundles:

- A single-character boolean value alias that also resolves as a reachable
  short flag, because a token like `-dt` then has two readings. Reachability
  includes the active command's inherited/global flags and the parser's unique
  scoped-flag fallback when no command is selected; the warning names every
  context in which the collision is reachable, not just the first one found.
  The parser resolves each context deterministically — an all-boolean token is
  a bundle, and otherwise the value-alias reading wins. Declare different
  characters if you want both spellings.
- A *multi-character* boolean value alias that spells a bundle. With
  `true_aliases = ["vp"]`, `-dvp` is a value for the boolean while `-dvp8080`
  is `-v` plus `-p 8080` — two spellings that differ only in whether the value
  is inline, resolving to different flags.
- A `short` declared with more than one character. Only the first is ever
  used, so `short = "ab"` quietly ships a CLI whose `-ab` is a bundle rather
  than the two-letter flag that was written. This is an error, not a warning.

Generated shell completion decomposes bundles the same way the parser does, so
a bundled value flag's separated value is offered as a value rather than
matched against subcommand names.

### Command aliases are canonicalized

A command can declare one or more aliases at any nesting depth. The parser
accepts the alias but reports the canonical command path through
`parse.command_env`, structured parsing, and `f2e_resolve_commands`:

```toml
[parse]
command_env = "ZED_COMMAND"

[commands.develop]
aliases = ["dev"]

[commands.develop.commands.shell]
aliases = ["sh"]
```

`zed dev sh` therefore selects the canonical path `develop shell`. Help keeps
the canonical command visible while listing accepted aliases, and generated
Bash/Zsh completion maps every alias to the same canonical option scope.
Separated option values are consumed before command matching, so a value such
as `--profile dev` never activates the `develop` command accidentally.

`flags2env audit` rejects sibling name/alias collisions, unsafe alias tokens,
and aliases that redundantly repeat their own canonical command name.
