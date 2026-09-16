# Reusable consumer compliance

Repositories that ship a CLI, server, worker, gateway, proxy, or MCP server can call the reusable workflow at an immutable tooling commit while independently naming the exact parser revision the executable ships:

```yaml
permissions:
  contents: read

jobs:
  flags2env:
    uses: flags-2-env/flags-2-env/.github/workflows/reusable-consumer-compliance.yml@<tooling-full-commit-sha>
    with:
      tooling_ref: <same-tooling-full-commit-sha>
      parser_ref: <consumer-parser-full-commit-sha>
      kind: server
      command_name: example-server
      contract_path: .cli-flags.toml
      rust_manifest_path: Cargo.toml
      cargo_lock_path: Cargo.lock
      runtime_smoke_script: scripts/smoke-flags.sh
      artifact_smoke_script: scripts/smoke-runtime-image.sh
```

Pin `uses:` and `tooling_ref` to the same reviewed full commit SHA. `parser_ref` is separate on purpose: it must match the immutable parser revision in the consumer's manifest and lockfile. This lets a repository adopt newer read-only compliance tooling without silently changing the parser embedded in its production artifact.

The canonical Git source is
`https://github.com/flags-2-env/flags-2-env.git`. The original
`https://github.com/flags-2-env/flags-2-env.git` source remains accepted through
2026-08-19 so consumers can migrate without losing immutable pins. The policy
checker rejects that compatibility URL after the cutoff; the canonical URL has
no transition expiry.

Ordinary pull-request checks need only `contents: read`.

## What the reusable workflow proves

1. Both tooling and parser inputs are full immutable commit SHAs.
2. The exact shipped parser revision builds and audits the consumer's contract.
3. `parse.allow_unknown` is false or omitted.
4. The contract owns at least one real process-level flag.
5. Secret-bearing environment variables are not declared as flags or given defaults.
6. Rust consumers use the exact upstream Git source and full immutable `rev`, with a matching committed `Cargo.lock`.
7. Long-running Rust consumers (`server`, `mcp`, and `worker`) do not discover `.cli-flags.toml` from the ambient process current working directory.
8. The generated help menu renders successfully through wide and narrow pseudo-terminals, contains each visible option and description, and does not fall back to JSON.
9. Bash completion parses, registers for `command_name`, executes in a real Bash process, and returns a declared option or command.
10. Zsh completion parses, registers through `compinit`, autoloads in a real Zsh process, and contains declared candidates.
11. Optional runtime and artifact checks are repository-controlled script files, not arbitrary workflow input commands.
12. MCP consumers must provide a runtime/stdio smoke script so stdout protocol cleanliness is tested by the repository that owns the binary.
13. CLI consumers must provide a runtime smoke script that checks the actual executable's help surface rather than only the canonical generator's table.

The canonical C audit remains the source of truth for syntax, aliases, subcommand scoping, type validation, duplicate destinations, and generated help/completion behavior. The Python policy checker adds cross-repository security and pinning rules. The shell-contract verifier exercises the canonical output in real terminal and shell runtimes.

## Trusted contract discovery

A flag contract is executable policy: it decides which process arguments are accepted, which environment destinations they may write, which defaults are applied, and what operators see in help and completion. Long-running or privileged processes must not silently select that policy from `current_dir()/.cli-flags.toml`. Service launchers, container `WORKDIR`, test harnesses, process supervisors, and operators can all change the working directory independently of the packaged binary.

For `server`, `mcp`, and `worker` consumers, use this precedence instead:

1. an explicit, documented environment override whose path must exist;
2. a package-owned path relative to the executable, such as `../share/<package>/.cli-flags.toml`;
3. an explicitly supported colocated artifact path beside the executable.

Repository-local CLIs may intentionally use the current project directory as their policy boundary. That exception is represented by `kind: cli`; it must not be copied into daemons or protocol servers. Tests should prove that an attacker-controlled CWD contract is ignored, that the explicit override still works, and that the final release image contains the trusted package-relative contract.

The same boundary covers `./.env`. Parsing reads it from the ambient working directory, so it is a second way a changed CWD can supply values for declared flags. `server`, `mcp`, and `worker` consumers should declare `[env] load = false` in their trusted contract and take deployment values from the real process environment instead. That declaration is authoritative: `FLAGS2ENV_DOTENV` can only switch loading off, never back on, so an ambient variable cannot undo it. Tests for these consumers should prove that an attacker-controlled `./.env` changes nothing.

## Central consumer-fleet verification

`consumer-fleet.json` is the committed inventory of active contracts whose canonical help and completion surfaces must remain usable. Each entry names the repository, relative `.cli-flags.toml` path, command basename, and executable kind. Multiple contracts in one monorepo are separate entries, so adding one passing root contract cannot hide a broken nested server or worker.

`.github/workflows/consumer-fleet.yml` validates that inventory before any dynamic checkout, then checks out every consumer and the canonical tooling without persisted credentials. For each contract it:

1. runs the canonical audit;
2. renders root and subcommand help in wide and narrow pseudo-terminals;
3. checks every visible option and description;
4. parses, registers, and executes generated Bash completion;
5. parses, registers through `compinit`, and autoloads generated Zsh completion;
6. installs both completion variants twice and verifies idempotency;
7. records the consumer and tooling commit SHAs in the Actions summary.

The fleet workflow runs when its data or tooling changes, on a daily schedule, and on manual dispatch. It is a cross-repository compatibility signal, not a replacement for the reusable workflow above: consumers still need repository-owned runtime and final-artifact smokes to prove their actual executable, container, protocol, parser pin, secret boundary, and trusted contract path.

### Dependency-free mirrored consumers

A consumer may intentionally avoid loading the native flags-2-env parser at runtime. `ORESoftware/next-loggers.ts` is the reference TypeScript case: its executable uses a dependency-free compiled specification while `.cli-flags.toml` remains the portable contract for canonical audit, generated help/completion, environment-variable documentation, and cross-language tooling.

That design is compliant only when all of these boundaries are enforced:

1. the runtime specification and `.cli-flags.toml` are compared bidirectionally, so both missing declarations and stale declarations fail CI;
2. command names, command descriptions, flag descriptions, aliases, types, short options, defaults, and environment destinations are included in the comparison;
3. repository-owned tests exercise the actual executable and its installed package, not only canonical generated output;
4. the central fleet independently audits the portable contract and exercises Bash/Zsh help and completion against current canonical tooling;
5. release-planning flags may document public package names, registries, and immutable tags, but credentials and secret-bearing environment variables remain outside the flag contract.

This pattern is useful for zero-runtime-dependency JavaScript packages and other applications with a native-tooling build boundary. It must not be used to justify an untested hand-maintained copy of the contract.

To add a consumer, append one sorted entry to `consumer-fleet.json` and run:

```sh
python3 -m unittest tests/test_consumer_fleet.py
python3 scripts/render-consumer-fleet.py --print
```

Private or otherwise centrally unreachable consumers use
`verification: in-repo` and must record both the canonical workflow/PR and the
full immutable commit that contains the reviewed integration. The commit anchor
prevents a later branch movement or unrelated PR URL from silently changing
the claimed evidence.

The renderer rejects mutable tooling refs and evidence commits, unsafe
repositories or paths, duplicate contracts, unsupported kinds, unsafe command
basenames, and unsorted entries before GitHub Actions evaluates the matrix.

## Consumer smoke scripts

Smoke scripts should be deterministic and credential-free. They should:

- exercise one declared non-secret operational flag;
- prove an undeclared secret-bearing flag fails closed;
- avoid printing environment values or credentials;
- for long-running consumers, launch from an attacker-controlled temporary CWD and prove the packaged contract remains authoritative;
- prove a documented explicit contract-path override still works;
- for CLIs, invoke the real binary's root and representative subcommand `--help` paths and assert the expected options/descriptions;
- for containers, inspect the final runtime image and verify `.cli-flags.toml` is packaged at the trusted path;
- for MCP servers, verify normal startup writes no application diagnostics to stdout;
- use test-only ports, temporary paths, and bounded timeouts.

## Scope exclusions

Do not add this workflow to browser-only, Flutter/mobile, desktop GUI, static-site, SDK-only, interface/schema, documentation, or infrastructure-only repositories unless they also ship a real process-level CLI or service. Record exclusions in the repository-classification work rather than omitting them silently.
