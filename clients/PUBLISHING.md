# Publishing Clients

`docs/plan.md` tracks the overall client coverage plan and verification gates.

Each client folder has a local `publish.sh` entrypoint. It delegates to
`../../scripts/publish-client.sh`, which defaults to dry-run output:

```sh
clients/nodejs/publish.sh
clients/rust/publish.sh --dry-run
clients/python/publish.sh --release
```

Release mode intentionally expects the native package credentials and ecosystem
tools to already be configured by CI.

| Client | Registry or release channel | Package filtering |
| --- | --- | --- |
| Node/Bun/Deno/Solidity | npm-compatible package registries | root `files`, `.npmignore`, package-local `files` |
| Python | PyPI | `MANIFEST.in` and `pyproject.toml` |
| Java/Kotlin/Scala/Groovy/Clojure | Maven Central/Sonatype-compatible repositories | Maven Central plugin, Gradle/sbt/tools.build publication metadata |
| Rust | crates.io | `include` in `Cargo.toml` |
| Go/Swift/C++/Fortran/Zig/Crystal/MATLAB | git tags or source archives | language package manifests where available |
| Oreslang | git tags/source archive until an Oreslang package registry is designated | `.ores.pkg.toml`, `src/`, native bridge, README/license allowlist |
| C/Bash/Zsh | Homebrew formula or git tags | native CLI, C library, and shell helpers installed from the formula |
| C#/F# | NuGet Gallery | `.nuspec` files plus project item rules |
| PHP | Packagist | Composer `archive.exclude` |
| Ruby | RubyGems.org | `spec.files` in the `.gemspec` |
| Dart | pub.dev | `.pubignore` |
| Elixir/Erlang/Gleam | Hex.pm | package file lists in Mix/rebar/Gleam manifests |
| Haskell | Hackage | Cabal manifest controls |
| OCaml/ReasonML | opam Repository | opam metadata and Dune package files |
| Perl | CPAN | `MANIFEST.SKIP` |
| Lua | LuaRocks | rockspec |
| Nim | Nimble Package Index | `.nimble` install file list |
| R | CRAN or R-universe | `.Rbuildignore` and staged native source |
| Julia | Julia General Registry | `Project.toml` and Registrator |

The goal is that a package for one runtime never bundles every other
`clients/*` directory. The registry/package-control audit checks both the
manifest files and the publish dispatcher commands.

The root npm package and Python PyPI package both ship package-local MIT license
files. The npm audit checks `LICENSE` appears in the packed tarball, and the
Python build uses `license-files = ["LICENSE"]` so wheels place it under
`dist-info/licenses`.

RubyGems and Packagist packages carry package-local README and MIT license
files as well. The Ruby gemspec includes `README.md`, `LICENSE`, and `lib.rb`,
while Composer archives keep README/license metadata and exclude only local
test/build/publish files.

Rust crates, Go modules, C/C++ source helpers, Bash/Zsh helpers, LuaRocks,
Nimble, Crystal Shards, Zig packages, and fpm package folders also include
package-local README and MIT license files so source-index pages have the same
basic metadata as the binary registry packages. Solidity's npm package
allowlist includes its contract sources plus package-local README and license
files, and the Docker Solidity check inspects the `npm pack` file list for
required and forbidden paths.
OCaml and ReasonML opam package folders follow the same pattern.
Erlang and Gleam Hex packages include package-local README and MIT license files
alongside their native parser sources.

The Go client is a module rooted at `clients/golang`, so its release tags use
the Go module subdirectory prefix, for example `clients/golang/v0.1.0`, so
`pkg.go.dev` and the Go command resolve the module version correctly. The Go
module carries package-local copies of `src/parser.c` and `src/parser.h` so
consumers can build it from a module cache without a prebuilt native library;
the packaging audit verifies those copies match the root C parser sources.

The Java Maven package carries package-local copies of the native parser under
`clients/java/native`, and the JNI source includes the local `parser.h` instead
of reaching back to the repository root. The default Docker check builds the
main jar, sources jar, and javadoc jar, then verifies the main jar includes the
runtime class plus package-local native parser sources while rejecting local
Docker, publish, and test files.

The Erlang Hex package carries `c_src/parser.c` and `c_src/parser.h` beside the
NIF source, and the Gleam Docker smoke uses the same package-local Erlang native sources.
The Elixir facade publishes as `flags2env_elixir`, includes its own package-local
README, MIT license file, copy of the Erlang NIF source and parser sources, and
avoids reaching into the Erlang client tree during package smoke checks. Erlang
declares `rebar3_hex` for `rebar3 hex build/publish` and carries
`src/flags2env.app.src` so rebar can discover a Hex-packaged OTP application.
The Docker Erlang Hex check builds the package tarball and inspects it for
`src/`, `c_src/`, README/license, and forbidden local files. Gleam uses
`gleam publish --yes` rather than the rebar Hex task.

The C# and F# NuGet packages carry package-local `native/parser.c` and
`native/parser.h` copies, so the native source files in each `.nupkg` do not
depend on repository-relative `../../src` paths.
Their SDK project files and `.nuspec` manifests also include package README
metadata so NuGet packages render useful package documentation.

The C++ package is rooted at `clients/cpp` and carries package-local parser
sources under `clients/cpp/native`, so its CMake target can be consumed without
repository-relative `../../src` paths. The C and C++ helper folders also carry
package-local README and MIT license files for source archive consumers. The
Docker C++ check configures the package with CMake, builds it, and runs the
registered CTest smoke test.

The C, Bash, and Zsh publish wrappers surface the Homebrew formula path. The C
wrapper creates and pushes the `v${PACKAGE_VERSION}` tag before running
`scripts/publish-homebrew.sh --release`; the Bash and Zsh wrappers run the same
Homebrew release checks against that tagged formula, since the formula installs
both shell helper files alongside the native CLI.

SwiftPM expects a `Package.swift` manifest in the repository root and a full
semantic-version tag such as `0.1.0`, so the root manifest points at
`clients/swift` while the Swift publish command uses an unprefixed SemVer tag.
The full Docker Swift check runs `swift package describe`, `swift build`, and
the native-library smoke binary so both the SwiftPM manifest and FFI path are
covered.

The Julia package is rooted at `clients/julia`, not the repository root. Its
publish preflight runs `Pkg.test()` in that project and then prints the
Registrator trigger comment:

```text
@JuliaRegistrator register subdir=clients/julia
```

The Zig package is rooted at `clients/zig` and carries package-local copies of
`src/parser.c` and `src/parser.h` under `clients/zig/native`. The packaging
audit verifies those copies match the root parser sources so consumers can build
the Zig package without relying on repository-relative `../../src` paths. Its
`build.zig.zon` path list includes only the build files, sources, native parser,
README, and license.

Docker-backed verification for the newer client scaffolds lives in
`scripts/docker-check-new-clients.sh`. Run the default set for practical local
coverage, including Perl FFI, .NET NuGet artifacts, Java Maven artifacts,
Python PyPI artifacts, Rust, Go, C++, Fortran, Zig, Lua, PHP FFI, Nim, Crystal,
R, Clojure Maven artifacts, Dart, Solidity, and package-control audits. Pass
`--full` in CI to
include heavier Haskell, OCaml/ReasonML, Julia, Swift, Scala, Kotlin, Groovy,
and JVM facade checks. The full JVM checks build Kotlin/Groovy Gradle jars and
Scala sbt jars, including main, sources, and javadoc artifacts, then inspect the
main and sources jars for required classes, source files, and forbidden local
files. The default Clojure check builds and inspects its main, sources, and
javadoc jars for required namespace/POM contents and forbidden local files. The
Python check builds the
sdist and wheel, runs `twine check`, and inspects the archives for required
metadata and forbidden local files. The .NET check builds, runs, packs, and
inspects both C# and F# `.nupkg` files for README/native source contents and
forbidden local files. The R check builds and checks the CRAN source tarball,
then inspects it for package metadata, R/native sources, tests, README/license,
and forbidden local files. The PHP check validates `composer.json`, builds a
Composer archive, and inspects it for README/license/runtime contents while
rejecting local Docker, publish, and test files. The Haskell full check runs the
Cabal smoke test suite against the freshly built native library, builds the
Hackage `cabal sdist` archive, and inspects that tarball for required and
forbidden files. The OCaml/ReasonML full check runs Dune tests after installing
the OCaml package into the opam switch. The Lua check runs the LuaJIT FFI smoke
test and `luarocks lint` for both the stable and development rockspecs. The Nim
check runs `nimble check` before compiling the smoke test. The Crystal check
runs `shards install --production` before its smoke test to validate `shard.yml`.
The script also accepts `--dry-run` to
print the default or full container plan without requiring a Docker daemon. The
GitHub Actions client packaging workflow runs the default Docker set
automatically and exposes a manual `full_docker_checks` input for the
heavyweight set.

The registry/package-control audit is available without language toolchains:

```sh
scripts/audit-client-packaging.sh
npm run pack:audit
npm run release:audit
```

The release matrix audit verifies that every required language row has the
expected registry destination, client folder, publish wrapper, package-control
metadata, source files, tests where practical, and the expected dry-run publish
command. It also checks ecosystem-specific manifest controls such as npm
allowlists, `MANIFEST.in`, Cargo `include`, `.gemspec` file lists, Composer
archive excludes, Maven/Gradle resource excludes, NuGet file excludes,
`.pubignore`, SwiftPM excludes, Hex file lists, Cabal/opam metadata, CPAN skip
rules, LuaRocks modules, Nimble install files, R build ignores, Julia subdir
registration metadata, and Homebrew shell helper installation. The
package-control, release matrix, and npm
package-content audits run in `.github/workflows/client-packaging.yml`
alongside the core shell integration tests whenever client, packaging, script,
source, or test files change.

The Rust crate includes `clients/rust/native/parser.c` and
`clients/rust/native/parser.h`, plus package-local README and license files, in
its Cargo allowlist. Its packaged smoke test compiles those local sources into a
temporary shared library, so `cargo test` does not depend on the monorepo
`build/` directory or shared test fixtures.

The C# and F# smoke programs use the package-local `native/parser.c` fallback
when `FLAGS2ENV_NATIVE_LIB` is not set and write their own temporary TOML
fixture when `FLAGS2ENV_FIXTURE` is absent. The F# smoke program registers a
`DllImportResolver` before the first native call so `DllImport("flags2env")`
loads that temporary library.

The OCaml opam package is `flags2env`. The ReasonML facade publishes as
`flags2env-reason` via `clients/reasonml/flags2env-reason.opam`, and depends on
the OCaml package instead of reusing the same opam package name.

The Clojure Maven/Sonatype path builds main, sources, and javadoc jars. The
javadoc jar contains a small documentation README because the facade is Clojure
source over the Java native bridge rather than a Java API surface.

The Kotlin and Groovy Gradle release wrappers pass `-Prelease`, which makes
their `signing` blocks require and attach signatures before publishing through
the Central Portal OSSRH compatibility endpoint.

The Haskell Hackage package declares `license-file: LICENSE` and includes that
file in `extra-source-files`, so `cabal sdist` carries package-local license
metadata alongside `README.md`. The full Docker check builds that sdist and
rejects local Docker, publish, and Cabal build-output files.

The Fortran fpm package carries package-local copies of `parser.c` and
`parser.h` under `clients/fortran/src`, so the smoke build and package sources
do not depend on the repository-root C source directory. The release audits also
enforce its fpm name, version, license, library source directory, and smoke test
entrypoint metadata.

The R package also carries package-local `src/parser.c` and `src/parser.h`.
`src/Makevars` builds those local files, which keeps `R CMD INSTALL clients/r`
and the staged CRAN archive independent of the monorepo root. The Docker R check
also builds, checks, and inspects the CRAN source tarball.

The Perl CPAN package includes package-local `README.md` and `LICENSE` files,
and the manifest audit checks that generated CPAN manifests and `make dist`
tarballs include both while still excluding generated build metadata,
`publish.sh`, and the repo-local `test.pl` smoke script.

The MATLAB source archive includes `+flags2env`, `native/parser.h`,
`native/parser.c`, `README.md`, and `LICENSE`. The loader defaults to that
package-local header for `loadlibrary`, while callers can still pass an
explicit shared library or header path when embedding flags2env elsewhere. The
client packaging audit builds that zip and rejects local-only files such as the
smoke test and publish wrapper.

The native C CLI has a Homebrew formula at
`packaging/homebrew/Formula/flags2env.rb`. It builds the CLI and C library,
installs bash/zsh helper files under `pkgshare`, runs the Bash helper in the
formula test, and also runs the Zsh helper when `/bin/zsh` is available.
`scripts/publish-homebrew.sh`
prints or runs the local `brew install --build-from-source`,
`brew audit --strict --new --online`, and `brew test` checks.

JVM clients share the Java JNI bridge. Kotlin, Scala, Groovy, and Clojure expose
idiomatic wrappers over `com.oresoftware.flags2env.Flags2Env` and are packaged
for Maven-compatible registries. Java uses Sonatype's Central Publishing Maven
plugin. Gradle and Clojure facades default to Sonatype's Central Portal OSSRH
Staging API compatibility endpoint and then call
`scripts/publish-central-ossrh-compat.sh` to hand the deployment to Central
Portal. Set `CENTRAL_NAMESPACE` plus `CENTRAL_BEARER_TOKEN`, or
`CENTRAL_TOKEN_USERNAME` and `CENTRAL_TOKEN_PASSWORD`, for those release paths.
The default Docker check also builds and inspects Clojure main, sources, and
javadoc jars. The full Docker JVM checks build and inspect Kotlin/Groovy Gradle
jars plus Scala sbt main, sources, and javadoc jars before the rest of the
heavier full-JVM checks finish.
Scala uses `sbt-sonatype` with `sonatypeCentralHost` and `sbt-pgp`; its build
explicitly publishes source and doc artifacts before `publishSigned
sonatypeBundleRelease`. The setup follows Sonatype's Central Portal Maven plugin
docs and OSSRH Staging API compatibility docs; Sonatype's Gradle docs currently
note that there is no official Gradle plugin for the Central Publishing Portal.
