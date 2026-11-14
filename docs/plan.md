# flags-2-env client publishing plan

## Objective

Support the core C parser and CLI from language-specific client folders, then
publish each client through the package ecosystem that users expect for that
language. Packages must include only the files needed by that destination and
must not accidentally ship unrelated `clients/*` folders, local smoke tests,
Dockerfiles, generated build output, or publish wrappers.

## Current status

The client publishing surface is implemented and guarded by audits. The active
completion check is not a manual checklist; it is the combination of:

- `npm run release:audit`
- `./scripts/audit-client-packaging.sh`
- `npm run pack:audit`
- `tests/run.sh`
- `./scripts/docker-check-new-clients.sh --dry-run --full`

Actual release publication still requires credentials, registry access, and
release tags. The repository only stores repeatable release commands and
package-surface checks.

## Client coverage

The release matrix in `scripts/audit-release-matrix.mjs` is the authoritative
coverage list. It verifies source files, package controls, tests where
practical, destination repository names, and publish dry-runs for:

- JavaScript, Python, Java, Kotlin, Scala, Groovy, Clojure, Rust, Go, C, C++,
  C#, F#, PHP, Ruby, Swift, Dart, Elixir, Erlang, Gleam, Haskell, OCaml,
  ReasonML, Perl, Lua, Nim, R, MATLAB, Julia, Fortran, Zig, Crystal, Solidity,
  Bash, Zsh, and Oreslang.

`scripts/audit-client-packaging.sh` separately verifies every `clients/*`
publish wrapper, including Node.js, Bun, Deno, Bash, and Zsh wrappers that are
not one-to-one rows in the language repository table.

## Package destinations and controls

- npm uses root `.npmignore`, `package.json` `files`, and
  `scripts/audit-npm-package.mjs` to keep the package focused on the JS clients
  plus parser sources.
- PyPI uses `clients/python/MANIFEST.in` and `pyproject.toml`.
- Maven Central/Sonatype clients use Maven, Gradle, sbt, or tools.build
  publication metadata with source and documentation artifacts.
- crates.io uses Cargo `include` rules.
- Go, Swift, C, C++, Fortran, Zig, Crystal, and Oreslang publish through git
  tags or source package conventions. Oreslang release support is additionally
  gated on compiler-backed backend evidence; scalar-only backend receipts do not
  establish full client support.
- NuGet uses `.nuspec` and project pack item rules for C# and F#.
- Packagist, RubyGems, pub.dev, Hex.pm, Hackage, opam, CPAN, LuaRocks, Nimble,
  CRAN/R-universe, MATLAB source archives, Julia General Registry, npm
  Solidity, and Homebrew each have package-local manifests or archive checks.

## Publishing entrypoints

Every client folder has a `publish.sh`. Most wrappers delegate to
`../../scripts/publish-client.sh`; Bash and Zsh use regular wrappers that call
the same dispatcher. Dry-runs are required to work without credentials. Release
publishes require the registry-specific credentials or tags documented in
`clients/PUBLISHING.md`.

## CI and verification

- `npm run release:audit` verifies matrix completeness, expected repository
  destinations, package controls, forbidden package content, and publish
  dry-runs.
- `./scripts/audit-client-packaging.sh` verifies per-client wrappers, manifests,
  archive controls, CI wiring, and package-specific hardening checks.
- `npm run pack:audit` verifies the root npm package omits non-JS clients.
- `./scripts/docker-check-new-clients.sh --full` defines containerized smoke
  checks for heavyweight language toolchains and package archives.
- `.github/workflows/client-packaging.yml` runs package audits and Docker client
  checks in CI.
- `.github/workflows/cli-flags-audit.yml` runs TOML and `.env` drift audits
  when `.cli-flags.toml` or `.env` files change.

## Recent hardening

- Erlang Hex packaging builds and inspects the package tarball for required
  `src/`, `c_src/`, README/license, and forbidden local files.
- Gleam publishing uses `gleam publish --yes` instead of the rebar Hex task.
- Homebrew installs Bash and Zsh helpers, tests Bash directly, and tests Zsh
  when `/bin/zsh` is available.
- Rendered Node.js, Bun, and Deno client distributions intentionally do not copy
  the root README or license into their generated `dist/*` folders.

## Operational notes

The repository does not publish credentials. Release commands are intentionally
dry-run by default and only publish when invoked with `--release`. Docker can
validate Linux package surfaces, while macOS and Windows native artifacts still
need platform-native CI or release runners.
