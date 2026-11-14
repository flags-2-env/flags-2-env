#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
status=0

require_path() {
  path="$1"
  if [ ! -e "$ROOT_DIR/$path" ]; then
    printf 'missing: %s\n' "$path" >&2
    status=1
  fi
}

require_absent() {
  path="$1"
  if [ -e "$ROOT_DIR/$path" ]; then
    printf 'unexpected file: %s\n' "$path" >&2
    status=1
  fi
}

require_contains() {
  path="$1"
  pattern="$2"
  require_path "$path"
  if [ -e "$ROOT_DIR/$path" ] && ! grep -Eq "$pattern" "$ROOT_DIR/$path"; then
    printf 'missing pattern in %s: %s\n' "$path" "$pattern" >&2
    status=1
  fi
}

forbid_contains() {
  path="$1"
  pattern="$2"
  require_path "$path"
  if [ -e "$ROOT_DIR/$path" ] && grep -Eq "$pattern" "$ROOT_DIR/$path"; then
    printf 'forbidden pattern in %s: %s\n' "$path" "$pattern" >&2
    status=1
  fi
}

require_same_file() {
  left="$1"
  right="$2"
  require_path "$left"
  require_path "$right"
  if [ -e "$ROOT_DIR/$left" ] && [ -e "$ROOT_DIR/$right" ] &&
     ! cmp -s "$ROOT_DIR/$left" "$ROOT_DIR/$right"; then
    printf 'file copies differ: %s %s\n' "$left" "$right" >&2
    status=1
  fi
}

native_library_name() {
  case "$(uname -s)" in
    Darwin)
      printf 'libflags2env.dylib'
      ;;
    MINGW*|MSYS*|CYGWIN*)
      printf 'libflags2env.dll'
      ;;
    *)
      printf 'libflags2env.so'
      ;;
  esac
}

audit_rendered_js_client() {
  runtime="$1"
  tmp_dir="${TMPDIR:-/tmp}/flags2env-render-audit-$runtime-$$"
  tmp_cache="${TMPDIR:-/tmp}/flags2env-render-npm-audit-$runtime-$$"
  rm -rf "$tmp_dir" "$tmp_cache"
  if ! node "$ROOT_DIR/scripts/render-client.mjs" "$runtime" "$tmp_dir" >/dev/null 2>&1; then
    printf 'render failed for JS client: %s\n' "$runtime" >&2
    status=1
    return
  fi

  for path in "$@"; do
    if [ "$path" = "$runtime" ]; then
      continue
    fi
    if [ ! -e "$tmp_dir/$path" ]; then
      printf 'rendered %s package is missing: %s\n' "$runtime" "$path" >&2
      status=1
    fi
  done

  if [ "$runtime" = "nodejs" ] &&
     grep -Eq '\.\./\.\./src' "$tmp_dir/binding.gyp"; then
    printf 'rendered nodejs binding.gyp points outside the package\n' >&2
    status=1
  fi

  if [ -e "$tmp_dir/package.json" ]; then
    output="$(
      cd "$tmp_dir" &&
        npm_config_cache="$tmp_cache" npm pack --dry-run --json 2>/dev/null
    )" || {
      printf 'npm pack dry-run failed for rendered JS client: %s\n' "$runtime" >&2
      status=1
      rm -rf "$tmp_dir" "$tmp_cache"
      return
    }

    for path in "$@"; do
      if [ "$path" = "$runtime" ]; then
        continue
      fi
      if ! printf '%s\n' "$output" | grep -Fq "\"path\": \"$path\""; then
        printf 'rendered npm package for %s is missing: %s\n' "$runtime" "$path" >&2
        status=1
      fi
    done
  fi
  rm -rf "$tmp_dir" "$tmp_cache"
}

audit_npm_pack_client() {
  client="$1"
  required="$2"
  forbidden="$3"
  tmp_cache="${TMPDIR:-/tmp}/flags2env-npm-audit-$client-$$"
  output="$(
    cd "$ROOT_DIR/clients/$client" &&
      npm_config_cache="$tmp_cache" npm pack --dry-run --json 2>/dev/null
  )" || {
    printf 'npm pack dry-run failed for client: %s\n' "$client" >&2
    status=1
    rm -rf "$tmp_cache"
    return
  }

  for path in $required; do
    if ! printf '%s\n' "$output" | grep -Fq "\"path\": \"$path\""; then
      printf 'npm package for %s is missing: %s\n' "$client" "$path" >&2
      status=1
    fi
  done
  for path in $forbidden; do
    if printf '%s\n' "$output" | grep -Fq "\"path\": \"$path\""; then
      printf 'npm package for %s includes forbidden file: %s\n' "$client" "$path" >&2
      status=1
    fi
  done
  rm -rf "$tmp_cache"
}

audit_perl_manifest() {
  tmp_dir="${TMPDIR:-/tmp}/flags2env-perl-manifest-audit-$$"
  rm -rf "$tmp_dir"
  mkdir -p "$tmp_dir"
  cp -R "$ROOT_DIR/clients/perl/." "$tmp_dir/"
  if ! (
    cd "$tmp_dir" &&
      perl Makefile.PL >/dev/null 2>&1 &&
      make manifest >/dev/null 2>&1 &&
      make dist >/dev/null 2>&1
  ); then
    printf 'Perl CPAN manifest/dist generation failed\n' >&2
    status=1
    rm -rf "$tmp_dir"
    return
  fi
  for path in publish.sh test.pl MYMETA.json MYMETA.yml; do
    if grep -Fxq "$path" "$tmp_dir/MANIFEST"; then
      printf 'Perl CPAN manifest includes forbidden file: %s\n' "$path" >&2
      status=1
    fi
  done
  for path in LICENSE README.md Makefile.PL lib/Flags2Env.pm; do
    if ! grep -Fxq "$path" "$tmp_dir/MANIFEST"; then
      printf 'Perl CPAN manifest is missing: %s\n' "$path" >&2
      status=1
    fi
  done
  dist_file=
  for candidate in "$tmp_dir"/Flags2Env-*.tar.gz; do
    if [ -e "$candidate" ]; then
      dist_file="$candidate"
      break
    fi
  done
  if [ -z "$dist_file" ]; then
    printf 'Perl CPAN dist archive was not generated\n' >&2
    status=1
    rm -rf "$tmp_dir"
    return
  fi
  tar -tf "$dist_file" > "$tmp_dir/dist-files.txt"
  for path in LICENSE README.md Makefile.PL lib/Flags2Env.pm; do
    if ! grep -Eq "/$path$" "$tmp_dir/dist-files.txt"; then
      printf 'Perl CPAN dist is missing: %s\n' "$path" >&2
      status=1
    fi
  done
  for path in publish.sh test.pl MYMETA.json MYMETA.yml; do
    if grep -Eq "/$path$" "$tmp_dir/dist-files.txt"; then
      printf 'Perl CPAN dist includes forbidden file: %s\n' "$path" >&2
      status=1
    fi
  done
  rm -rf "$tmp_dir"
}

audit_ruby_gem() {
  tmp_dir="${TMPDIR:-/tmp}/flags2env-ruby-gem-audit-$$"
  rm -rf "$tmp_dir"
  mkdir -p "$tmp_dir"
  cp "$ROOT_DIR/clients/ruby/flags2env.gemspec" \
     "$ROOT_DIR/clients/ruby/lib.rb" \
     "$ROOT_DIR/clients/ruby/README.md" \
     "$ROOT_DIR/clients/ruby/LICENSE" \
     "$tmp_dir/"
  if ! (cd "$tmp_dir" && gem build flags2env.gemspec >/dev/null 2>&1); then
    printf 'RubyGems package build failed\n' >&2
    status=1
    rm -rf "$tmp_dir"
    return
  fi
  gem_file=
  for candidate in "$tmp_dir"/flags2env-*.gem; do
    if [ -e "$candidate" ]; then
      gem_file="$candidate"
      break
    fi
  done
  if [ -z "$gem_file" ] ||
     ! (cd "$tmp_dir" && gem unpack "$(basename "$gem_file")" >/dev/null 2>&1); then
    printf 'RubyGems package unpack failed\n' >&2
    status=1
    rm -rf "$tmp_dir"
    return
  fi
  unpacked_dir="${gem_file%.gem}"
  for path in LICENSE README.md lib.rb; do
    if [ ! -e "$unpacked_dir/$path" ]; then
      printf 'RubyGems package is missing: %s\n' "$path" >&2
      status=1
    fi
  done
  for path in Dockerfile publish.sh test.rb flags2env.gemspec; do
    if [ -e "$unpacked_dir/$path" ]; then
      printf 'RubyGems package includes forbidden file: %s\n' "$path" >&2
      status=1
    fi
  done
  rm -rf "$tmp_dir"
}

audit_r_staging() {
  tmp_dir="${TMPDIR:-/tmp}/flags2env-r-staging-audit-$$"
  rm -rf "$tmp_dir"
  mkdir -p "$tmp_dir/r"
  cp -R "$ROOT_DIR/clients/r/." "$tmp_dir/r/"
  for path in src/flags2env_r.c src/parser.c src/parser.h src/Makevars DESCRIPTION NAMESPACE tests/smoke.R; do
    if [ ! -e "$tmp_dir/r/$path" ]; then
      printf 'staged R package is missing: %s\n' "$path" >&2
      status=1
    fi
  done
  if grep -Eq '\.\./\.\./\.\./src/parser\.h' "$tmp_dir/r/src/flags2env_r.c"; then
    printf 'staged R package still points to repository parser header\n' >&2
    status=1
  fi
  if grep -Eq '\.\./\.\./\.\./src' "$tmp_dir/r/src/Makevars"; then
    printf 'staged R package Makevars reaches into repository source directory\n' >&2
    status=1
  fi
  rm -rf "$tmp_dir"
}

audit_matlab_archive() {
  tmp_dir="${TMPDIR:-/tmp}/flags2env-matlab-archive-audit-$$"
  zip_file="$tmp_dir/flags2env-matlab.zip"
  files_list="$tmp_dir/files.txt"
  rm -rf "$tmp_dir"
  mkdir -p "$tmp_dir"
  if ! (
    cd "$ROOT_DIR/clients/matlab" &&
      zip -qr "$zip_file" +flags2env native README.md LICENSE
  ); then
    printf 'MATLAB source archive generation failed\n' >&2
    status=1
    rm -rf "$tmp_dir"
    return
  fi
  zipinfo -1 "$zip_file" > "$files_list"
  for path in \
    +flags2env/apply.m \
    +flags2env/defaultHeaderPath.m \
    +flags2env/defaultLibraryName.m \
    +flags2env/ensureLoaded.m \
    +flags2env/ownedString.m \
    +flags2env/parse.m \
    +flags2env/parseProcess.m \
    native/parser.c \
    native/parser.h \
    README.md \
    LICENSE
  do
    if ! grep -Fxq "$path" "$files_list"; then
      printf 'MATLAB source archive missing: %s\n' "$path" >&2
      status=1
    fi
  done
  for path in Dockerfile publish.sh test.m; do
    if grep -Fxq "$path" "$files_list"; then
      printf 'MATLAB source archive includes forbidden file: %s\n' "$path" >&2
      status=1
    fi
  done
  rm -rf "$tmp_dir"
}

audit_docker_check_plan() {
  output="$("$ROOT_DIR/scripts/docker-check-new-clients.sh" --dry-run --full 2>/dev/null)" || {
    printf 'Docker client check dry-run failed\n' >&2
    status=1
    return
  }

  for label in \
    perl dotnet java python rust golang cpp fortran zig lua php dart nim crystal r clojure erlang-hex solidity packaging \
    jvm scala haskell swift ocaml julia
  do
    if ! printf '%s\n' "$output" | grep -Fq "[dry-run] docker check $label:"; then
      printf 'Docker client check dry-run is missing label: %s\n' "$label" >&2
      status=1
    fi
  done
}

require_client() {
  client="$1"
  require_path "clients/$client"
  require_path "clients/$client/publish.sh"
  if [ -L "$ROOT_DIR/clients/$client/publish.sh" ]; then
    target="$(readlink "$ROOT_DIR/clients/$client/publish.sh" || true)"
    if [ "$target" != "../../scripts/publish-client.sh" ]; then
      printf 'unexpected publish wrapper target for clients/%s/publish.sh: %s\n' "$client" "$target" >&2
      status=1
    fi
  elif [ -e "$ROOT_DIR/clients/$client/publish.sh" ] &&
       ! grep -Eq 'publish-client\.sh' "$ROOT_DIR/clients/$client/publish.sh"; then
    printf 'publish wrapper does not delegate for client: %s\n' "$client" >&2
    status=1
  fi
  if ! grep -Eq "^  $client\\)|\\|$client\\)|$client\\|" "$ROOT_DIR/scripts/publish-client.sh"; then
    printf 'missing publish dispatcher case for client: %s\n' "$client" >&2
    status=1
  fi
  if [ -e "$ROOT_DIR/clients/$client/publish.sh" ] &&
     ! "$ROOT_DIR/clients/$client/publish.sh" --dry-run >/dev/null 2>&1; then
    printf 'publish dry-run failed for client: %s\n' "$client" >&2
    status=1
  fi
}

for client in \
  nodejs bun deno python java kotlin scala groovy clojure rust golang c cpp \
  bash zsh \
  csharp fsharp php ruby dart swift elixir erlang gleam haskell ocaml \
  reasonml perl lua nim r matlab julia fortran zig crystal solidity oreslang
do
  require_client "$client"
done

for path in \
  .npmignore \
  LICENSE \
  Package.swift \
  docs/plan.md \
  package.json \
  packaging/homebrew/README.md \
  packaging/homebrew/Formula/flags2env.rb \
  scripts/audit-npm-package.mjs \
  scripts/audit-release-matrix.mjs \
  scripts/docker-check-new-clients.sh \
  tests/codegen-docker/Dockerfile \
  tests/codegen-docker/README.md \
  tests/codegen-docker/run.sh \
  scripts/publish-central-ossrh-compat.sh \
  scripts/publish-homebrew.sh \
  clients/bash/LICENSE \
  clients/bash/README.md \
  clients/bash/flags2env.bash \
  clients/bash/test.bash \
  clients/zsh/LICENSE \
  clients/zsh/README.md \
  clients/zsh/flags2env.zsh \
  clients/zsh/test.zsh \
  clients/c/LICENSE \
  clients/c/README.md \
  clients/c/lib.c \
  clients/c/lib.h \
  clients/cpp/LICENSE \
  clients/cpp/README.md \
  clients/cpp/native/parser.c \
  clients/cpp/native/parser.h \
  clients/python/LICENSE \
  clients/python/MANIFEST.in \
  clients/python/pyproject.toml \
  clients/golang/LICENSE \
  clients/golang/README.md \
  clients/golang/parser.c \
  clients/golang/parser.h \
  clients/rust/Cargo.toml \
  clients/rust/Dockerfile \
  clients/rust/LICENSE \
  clients/rust/README.md \
  clients/rust/native/parser.c \
  clients/rust/native/parser.h \
  clients/ruby/flags2env.gemspec \
  clients/ruby/LICENSE \
  clients/ruby/README.md \
  clients/php/composer.json \
  clients/php/LICENSE \
  clients/php/README.md \
  clients/java/pom.xml \
  clients/java/native/parser.c \
  clients/java/native/parser.h \
  clients/kotlin/build.gradle.kts \
  clients/groovy/build.gradle \
  clients/scala/build.sbt \
  clients/scala/project/plugins.sbt \
  clients/csharp/Flags2Env.nuspec \
  clients/csharp/Flags2Env.csproj \
  clients/csharp/README.md \
  clients/csharp/native/parser.c \
  clients/csharp/native/parser.h \
  clients/fsharp/Flags2Env.FSharp.nuspec \
  clients/fsharp/Flags2Env.FSharp.fsproj \
  clients/fsharp/README.md \
  clients/fsharp/native/parser.c \
  clients/fsharp/native/parser.h \
  clients/dart/CHANGELOG.md \
  clients/dart/LICENSE \
  clients/dart/README.md \
  clients/dart/pubspec.yaml \
  clients/dart/.pubignore \
  clients/swift/Package.swift \
  clients/elixir/LICENSE \
  clients/elixir/README.md \
  clients/elixir/mix.exs \
  clients/elixir/native/flags2env.erl \
  clients/elixir/native/flags2env_nif.c \
  clients/elixir/native/parser.c \
  clients/elixir/native/parser.h \
  clients/erlang/rebar.config \
  clients/erlang/src/flags2env.app.src \
  clients/erlang/LICENSE \
  clients/erlang/README.md \
  clients/erlang/src/flags2env.erl \
  clients/erlang/c_src/flags2env_nif.c \
  clients/erlang/c_src/parser.c \
  clients/erlang/c_src/parser.h \
  clients/gleam/LICENSE \
  clients/gleam/README.md \
  clients/gleam/gleam.toml \
  clients/gleam/src/flags2env.gleam \
  clients/gleam/src/flags2env_native.erl \
  clients/haskell/LICENSE \
  clients/haskell/flags2env.cabal \
  clients/ocaml/dune \
  clients/ocaml/LICENSE \
  clients/ocaml/README.md \
  clients/ocaml/flags2env.opam \
  clients/reasonml/LICENSE \
  clients/reasonml/README.md \
  clients/reasonml/flags2env-reason.opam \
  clients/reasonml/src/dune \
  clients/perl/LICENSE \
  clients/perl/README.md \
  clients/lua/flags2env-0.1.0-1.rockspec \
  clients/lua/LICENSE \
  clients/lua/README.md \
  clients/perl/MANIFEST.SKIP \
  clients/lua/flags2env-dev-1.rockspec \
  clients/nim/LICENSE \
  clients/nim/README.md \
  clients/nim/flags2env.nimble \
  clients/r/.Rbuildignore \
  clients/r/DESCRIPTION \
  clients/r/LICENSE \
  clients/r/README.md \
  clients/r/src/parser.c \
  clients/r/src/parser.h \
  clients/r/tests/smoke.R \
  clients/matlab/LICENSE \
  clients/matlab/README.md \
  clients/matlab/+flags2env/defaultHeaderPath.m \
  clients/matlab/native/parser.c \
  clients/matlab/native/parser.h \
  clients/julia/LICENSE \
  clients/julia/Project.toml \
  clients/julia/README.md \
  clients/julia/REGISTRATION.md \
  clients/solidity/package.json \
  clients/solidity/LICENSE \
  clients/solidity/README.md \
  clients/fortran/LICENSE \
  clients/fortran/README.md \
  clients/fortran/src/parser.c \
  clients/fortran/src/parser.h \
  clients/crystal/LICENSE \
  clients/crystal/README.md \
  clients/zig/LICENSE \
  clients/zig/README.md \
  clients/zig/build.zig.zon \
  clients/zig/native/parser.c \
  clients/zig/native/parser.h \
  .github/workflows/client-packaging.yml \
  .github/workflows/cli-flags-audit.yml
do
  require_path "$path"
done

require_contains .npmignore '^!clients/nodejs/'
require_contains .npmignore '^!LICENSE$'
require_contains Package.swift 'path: "clients/swift"'
require_contains Package.swift 'exclude: \["Dockerfile", "Package\.swift", "test\.swift", "publish\.sh"\]'
require_contains Makefile '@rpath/lib\$\(LIB_NAME\)\.dylib'
require_contains package.json '"files"'
require_contains package.json '"license": "MIT"'
require_contains package.json '"LICENSE"'
require_contains package.json '"pack:audit"'
require_contains package.json '"release:audit"'
require_contains scripts/audit-npm-package.mjs '"README.md"'
require_contains scripts/audit-npm-package.mjs '"src/parser.h"'
require_contains scripts/audit-npm-package.mjs 'non-JS clients'
require_contains scripts/audit-npm-package.mjs 'forbidden build/test/package-template files'
require_contains scripts/audit-npm-package.mjs 'nodejs.*build'
require_contains scripts/audit-client-packaging.sh 'make dist'
require_contains scripts/audit-client-packaging.sh 'Perl CPAN dist includes forbidden file'
require_contains scripts/audit-client-packaging.sh 'Flags2Env-\*\.tar\.gz'
require_contains scripts/audit-client-packaging.sh 'audit_ruby_gem'
require_contains scripts/audit-client-packaging.sh 'gem build flags2env\.gemspec'
require_contains scripts/audit-release-matrix.mjs 'release matrix audit passed'
require_contains scripts/audit-release-matrix.mjs 'requiredClients'
require_contains scripts/audit-release-matrix.mjs 'expectedRepositories'
require_contains scripts/audit-release-matrix.mjs 'packageControls'
require_contains scripts/audit-release-matrix.mjs 'missing package-control assertions'
require_contains docs/plan.md 'scripts/audit-release-matrix\.mjs'
require_contains docs/plan.md 'scripts/audit-client-packaging\.sh'
require_contains docs/plan.md 'npm run pack:audit'
require_contains docs/plan.md 'scripts/docker-check-new-clients\.sh --full'
require_contains docs/plan.md '\.github/workflows/client-packaging\.yml'
require_contains README.md 'docs/plan\.md'
require_contains clients/PUBLISHING.md 'docs/plan\.md'
require_contains scripts/publish-central-ossrh-compat.sh 'manual/upload/defaultRepository'
require_contains scripts/publish-central-ossrh-compat.sh 'CENTRAL_NAMESPACE'
require_contains scripts/publish-central-ossrh-compat.sh 'ossrh-staging-api\.central\.sonatype\.com'
require_contains scripts/docker-check-new-clients.sh 'clojure:temurin-21-tools-deps'
require_contains scripts/docker-check-new-clients.sh 'sbtscala/scala-sbt'
require_contains scripts/docker-check-new-clients.sh 'run java maven:3\.9-eclipse-temurin-21'
require_contains scripts/docker-check-new-clients.sh 'mvn -q -f clients/java/pom\.xml -DskipTests package'
forbid_contains scripts/docker-check-new-clients.sh 'package source:jar-no-fork javadoc:jar'
require_contains scripts/docker-check-new-clients.sh 'flags2env-0\.1\.0-sources\.jar'
require_contains scripts/docker-check-new-clients.sh 'flags2env-0\.1\.0-javadoc\.jar'
require_contains scripts/docker-check-new-clients.sh 'Maven artifact includes forbidden local file'
require_contains scripts/docker-check-new-clients.sh 'run python python:3\.12-bookworm'
require_contains scripts/docker-check-new-clients.sh 'python -m build && python -m twine check dist/\*'
require_contains scripts/docker-check-new-clients.sh 'sdist includes'
require_contains scripts/docker-check-new-clients.sh 'wheel missing dist-info license'
require_contains scripts/docker-check-new-clients.sh 'run rust rust:1-bookworm'
require_contains scripts/docker-check-new-clients.sh 'cargo test && cargo package --allow-dirty'
require_contains scripts/docker-check-new-clients.sh 'run golang golang:1\.23-bookworm'
require_contains scripts/docker-check-new-clients.sh 'cd clients/golang && go test \./\.\.\.'
require_contains scripts/docker-check-new-clients.sh 'zig build test'
require_contains scripts/docker-check-new-clients.sh 'dry-run'
require_contains scripts/docker-check-new-clients.sh 'cabal test --extra-lib-dirs=/work/build'
require_contains scripts/docker-check-new-clients.sh 'cabal sdist'
require_contains scripts/docker-check-new-clients.sh 'dist-newstyle/sdist/flags2env-0\.1\.0\.tar\.gz'
require_contains scripts/docker-check-new-clients.sh 'Hackage sdist missing'
require_contains scripts/docker-check-new-clients.sh 'Hackage sdist includes forbidden local file'
require_contains scripts/docker-check-new-clients.sh 'clients/reasonml/flags2env-reason\.opam'
require_contains scripts/docker-check-new-clients.sh 'php -d ffi\.enable=true clients/php/test\.php'
require_contains scripts/docker-check-new-clients.sh 'docker-php-ext-install ffi'
require_contains scripts/docker-check-new-clients.sh 'run dart dart:stable'
require_contains scripts/docker-check-new-clients.sh 'dart pub publish --dry-run'
require_contains scripts/docker-check-new-clients.sh 'run swift swift:6\.0'
require_contains scripts/docker-check-new-clients.sh 'swift package --disable-sandbox --scratch-path /tmp/flags2env-swift-build describe --type json'
require_contains scripts/docker-check-new-clients.sh 'swift build --disable-sandbox --scratch-path /tmp/flags2env-swift-build -c release'
require_contains scripts/docker-check-new-clients.sh 'swiftc clients/swift/lib\.swift clients/swift/test\.swift'
require_contains scripts/docker-check-new-clients.sh 'clients/ocaml && FLAGS2ENV_NATIVE_LIB=/work/build/libflags2env\.so dune runtest'
require_contains scripts/docker-check-new-clients.sh 'dune install --prefix="\$\(opam var prefix\)" flags2env'
require_contains scripts/docker-check-new-clients.sh 'cd \.\./reasonml && FLAGS2ENV_NATIVE_LIB=/work/build/libflags2env\.so dune runtest'
require_contains scripts/docker-check-new-clients.sh 'npm test && npm pack'
require_contains packaging/homebrew/Formula/flags2env.rb 'class Flags2env < Formula'
forbid_contains packaging/homebrew/Formula/flags2env.rb 'depends_on "gcc" => :build'
require_contains packaging/homebrew/Formula/flags2env.rb '\(include/"flags2env"\)\.install "src/parser\.h"'
require_contains packaging/homebrew/Formula/flags2env.rb 'shell-env'
require_contains packaging/homebrew/Formula/flags2env.rb 'shell-env --config'
require_contains packaging/homebrew/Formula/flags2env.rb 'assert_path_exists pkgshare/"shell/flags2env\.bash"'
require_contains packaging/homebrew/Formula/flags2env.rb 'assert_path_exists pkgshare/"shell/flags2env\.zsh"'
require_contains packaging/homebrew/Formula/flags2env.rb 'refute_path_exists prefix/"tests"'
require_contains packaging/homebrew/Formula/flags2env.rb 'refute_path_exists pkgshare/"tests"'
require_contains packaging/homebrew/Formula/flags2env.rb 'generate typescript \.cli-flags\.toml --name CliStuff'
require_contains packaging/homebrew/Formula/flags2env.rb 'bash-helper-test'
require_contains packaging/homebrew/Formula/flags2env.rb 'zsh-helper-test'
require_contains packaging/homebrew/Formula/flags2env.rb '/bin/zsh'
require_contains packaging/homebrew/Formula/flags2env.rb 'flags2env_apply --debug'
require_contains packaging/homebrew/README.md 'scripts/publish-homebrew\.sh --release'
require_contains packaging/homebrew/README.md "Docker generated-code matrix"
require_contains packaging/homebrew/README.md "is not installed"
require_contains clients/PUBLISHING.md '@JuliaRegistrator register subdir=clients/julia'
require_contains clients/PUBLISHING.md 'clients/zig/native'
require_contains scripts/publish-homebrew.sh 'brew audit --strict --new --online'
require_contains scripts/publish-homebrew.sh 'FLAGS2ENV_HOMEBREW_AUDIT_TARGET'
require_contains scripts/publish-homebrew.sh 'rev-parse "v\$VERSION'
require_contains src/main.c 'shell-env'
require_contains src/terminal_context.c 'f2e_terminal_context_json'
require_contains .github/workflows/e2e.yml 'src\\terminal_context\.c src\\main\.c'
require_contains clients/bash/LICENSE 'MIT License'
require_contains clients/bash/README.md 'flags2env Bash'
require_contains clients/bash/flags2env.bash 'flags2env_apply'
require_contains clients/zsh/LICENSE 'MIT License'
require_contains clients/zsh/README.md 'flags2env Zsh'
require_contains clients/zsh/flags2env.zsh 'flags2env_apply'
require_contains clients/python/MANIFEST.in '^include lib\.py$'
require_contains clients/python/MANIFEST.in '^include flags2env\.py$'
require_contains clients/python/MANIFEST.in '^include README\.md$'
require_contains clients/python/MANIFEST.in '^include LICENSE$'
require_contains clients/python/MANIFEST.in '^exclude publish\.sh$'
require_contains clients/python/pyproject.toml 'setuptools>=77'
require_contains clients/python/pyproject.toml '^license = "MIT"$'
require_contains clients/python/pyproject.toml '^license-files = \["LICENSE"\]$'
forbid_contains clients/python/pyproject.toml 'license = \{ text = "MIT" \}'
require_contains clients/rust/Cargo.toml '^include = \['
require_contains clients/rust/Cargo.toml '^readme = "README\.md"$'
require_contains clients/rust/Cargo.toml '"LICENSE"'
require_contains clients/rust/Cargo.toml '"README\.md"'
require_contains clients/rust/Cargo.toml '"native/\*\*"'
require_contains clients/rust/Cargo.toml '"tests/\*\*"'
require_contains clients/rust/LICENSE 'MIT License'
require_contains clients/rust/README.md 'Rust bindings'
require_contains clients/rust/Dockerfile 'COPY clients/rust ./clients/rust'
forbid_contains clients/rust/Dockerfile 'COPY src|COPY tests|src/parser\.c|tests/fixtures|make all|LD_LIBRARY_PATH'
forbid_contains clients/rust/tests/smoke.rs '\.\./\.\./build|tests/fixtures|\.\./\.\./tests'
require_contains clients/rust/tests/smoke.rs 'native/parser\.c'
require_same_file src/parser.c clients/rust/native/parser.c
require_same_file src/parser.h clients/rust/native/parser.h
require_contains clients/c/LICENSE 'MIT License'
require_contains clients/c/README.md 'flags2env C'
require_contains clients/c/lib.h 'f2e_client_parse'
require_contains clients/cpp/CMakeLists.txt 'native/parser\.c'
require_contains clients/cpp/CMakeLists.txt 'target_include_directories\(flags2env_native PUBLIC native\)'
require_contains clients/cpp/CMakeLists.txt 'target_include_directories\(flags2env_cpp INTERFACE include native\)'
require_contains clients/cpp/CMakeLists.txt 'add_test\(NAME flags2env_cpp_smoke'
require_contains clients/cpp/LICENSE 'MIT License'
require_contains clients/cpp/README.md 'flags2env C\+\+'
forbid_contains clients/cpp/CMakeLists.txt '\.\./\.\./src'
require_same_file src/parser.c clients/cpp/native/parser.c
require_same_file src/parser.h clients/cpp/native/parser.h
require_contains scripts/docker-check-new-clients.sh 'cmake -S clients/cpp -B /tmp/flags2env-cpp-build'
require_contains scripts/docker-check-new-clients.sh 'ctest --test-dir /tmp/flags2env-cpp-build --output-on-failure'
require_contains clients/golang/lib.go '#cgo CFLAGS: -I\.'
require_contains clients/golang/lib.go '#include "parser\.h"'
require_contains clients/golang/LICENSE 'MIT License'
require_contains clients/golang/README.md 'Go bindings'
require_contains clients/golang/README.md 'pkg\.go\.dev'
forbid_contains clients/golang/lib.go '\.\./\.\./src|\.\./\.\./build|LDFLAGS'
require_same_file src/parser.c clients/golang/parser.c
require_same_file src/parser.h clients/golang/parser.h
require_contains clients/ruby/flags2env.gemspec 'spec\.files'
require_contains clients/ruby/flags2env.gemspec '"LICENSE"'
require_contains clients/ruby/flags2env.gemspec '"README\.md"'
forbid_contains clients/ruby/flags2env.gemspec '"test\.rb"'
require_contains clients/php/composer.json '"archive"'
require_contains clients/php/composer.json '"license": "MIT"'
require_contains clients/php/composer.json '"\/publish\.sh"'
require_contains scripts/docker-check-new-clients.sh 'run php php:8\.3-cli'
require_contains scripts/docker-check-new-clients.sh 'composer validate --strict'
require_contains scripts/docker-check-new-clients.sh 'composer archive --format=zip'
require_contains scripts/docker-check-new-clients.sh 'unzip -Z1 /tmp/flags2env-php-archive\.zip'
require_contains scripts/docker-check-new-clients.sh 'Composer archive missing'
require_contains scripts/docker-check-new-clients.sh 'Composer archive includes forbidden local file'
require_contains clients/java/pom.xml 'central-publishing-maven-plugin'
require_contains clients/java/pom.xml '<publishingServerId>'
require_contains clients/java/pom.xml '<excludes>'
require_contains clients/java/pom.xml '<directory>native</directory>'
require_contains clients/java/pom.xml '<include>\*\*/\*\.c</include>'
require_contains clients/java/pom.xml '<include>\*\*/\*\.h</include>'
forbid_contains clients/java/pom.xml '\.\./\.\./src'
forbid_contains clients/java/pom.xml 'nexus-staging-maven-plugin'
require_contains clients/java/native/flags2env_jni.c '#include "parser\.h"'
forbid_contains clients/java/native/flags2env_jni.c '\.\./\.\./\.\./src/parser\.h'
require_contains clients/java/Dockerfile 'clients/java/native/parser\.c'
forbid_contains clients/java/Dockerfile 'COPY src|COPY tests|src/parser\.c'
require_same_file src/parser.c clients/java/native/parser.c
require_same_file src/parser.h clients/java/native/parser.h
require_contains clients/kotlin/build.gradle.kts 'maven-publish'
require_contains clients/kotlin/build.gradle.kts 'java-library'
require_contains clients/kotlin/build.gradle.kts 'artifactId = "flags2env-kotlin"'
require_contains clients/kotlin/build.gradle.kts 'exclude\("publish\.sh"\)'
require_contains clients/kotlin/build.gradle.kts 'setRequired \{ project\.hasProperty\("release"\) \}'
require_contains clients/kotlin/build.gradle.kts 'ossrh-staging-api\.central\.sonatype\.com'
require_contains scripts/docker-check-new-clients.sh 'gradle -p clients/kotlin jar sourcesJar javadocJar'
require_contains scripts/docker-check-new-clients.sh 'flags2env-kotlin-0\.1\.0-sources\.jar'
require_contains scripts/docker-check-new-clients.sh 'com/oresoftware/flags2env/kotlin/Flags2Env\.class'
require_contains clients/groovy/build.gradle "maven-publish"
require_contains clients/groovy/build.gradle "java-library"
require_contains clients/groovy/build.gradle "artifactId = 'flags2env-groovy'"
require_contains clients/groovy/build.gradle "exclude 'publish\\.sh'"
require_contains clients/groovy/build.gradle "required \\{ project\\.hasProperty\\('release'\\) \\}"
require_contains clients/groovy/build.gradle 'ossrh-staging-api\.central\.sonatype\.com'
require_contains scripts/docker-check-new-clients.sh 'gradle -p clients/groovy jar sourcesJar javadocJar'
require_contains scripts/docker-check-new-clients.sh 'flags2env-groovy-0\.1\.0-sources\.jar'
require_contains scripts/docker-check-new-clients.sh 'com/oresoftware/flags2env/groovy/Flags2Env\.class'
require_contains scripts/docker-check-new-clients.sh 'Gradle artifact includes forbidden local file'
require_contains clients/scala/build.sbt 'sonatype'
require_contains clients/scala/build.sbt 'sonatypeCentralHost'
require_contains clients/scala/build.sbt 'flags2env-scala'
require_contains clients/scala/build.sbt 'Compile / packageSrc / publishArtifact := true'
require_contains clients/scala/build.sbt 'Compile / packageDoc / publishArtifact := true'
require_contains clients/scala/project/plugins.sbt 'sbt-pgp'
require_contains scripts/docker-check-new-clients.sh 'sbt -batch -Dsbt\.supershell=false package "Compile / packageSrc" "Compile / packageDoc"'
require_contains scripts/docker-check-new-clients.sh 'flags2env-scala_2\.13-0\.1\.0-sources\.jar'
require_contains scripts/docker-check-new-clients.sh 'com/oresoftware/flags2env/scala/Flags2Env\$\.class'
require_contains scripts/docker-check-new-clients.sh 'Scala artifact includes forbidden local file'
require_contains clients/clojure/build.clj 'sign-and-deploy-file'
require_contains clients/clojure/build.clj 'CENTRAL_OSSRH_DEPLOY_URL'
require_contains clients/clojure/build.clj 'javadoc-jar-file'
require_contains clients/clojure/build.clj '\(defn javadoc-jar'
require_contains clients/clojure/build.clj '"-Djavadoc="'
require_contains clients/clojure/build.clj 'flags2env-clojure'
require_contains scripts/docker-check-new-clients.sh 'clojure -T:build javadoc-jar'
require_contains scripts/docker-check-new-clients.sh 'flags2env-clojure-0\.1\.0-sources\.jar'
require_contains scripts/docker-check-new-clients.sh 'META-INF/maven/com\.oresoftware/flags2env-clojure/pom\.xml'
require_contains scripts/docker-check-new-clients.sh 'Clojure artifact includes forbidden local file'
require_contains clients/csharp/Flags2Env.nuspec '<files>'
require_contains clients/csharp/Flags2Env.nuspec '<readme>README\.md</readme>'
require_contains clients/csharp/Flags2Env.nuspec 'src="README\.md"'
require_contains clients/csharp/Flags2Env.nuspec 'exclude='
require_contains clients/csharp/Flags2Env.nuspec 'native/parser\.c'
require_contains clients/csharp/Flags2Env.nuspec 'native/parser\.h'
forbid_contains clients/csharp/Flags2Env.nuspec '\.\./\.\./src|\.\./\.\./clients'
require_contains clients/csharp/Flags2Env.csproj 'Pack="true"'
require_contains clients/csharp/Flags2Env.csproj '<PackageReadmeFile>README\.md</PackageReadmeFile>'
require_contains clients/csharp/Flags2Env.csproj 'Include="README\.md"'
require_contains clients/csharp/Flags2Env.csproj 'Include="native/parser\.c"'
require_contains clients/csharp/Flags2Env.csproj 'Include="native/parser\.h"'
require_contains clients/csharp/Flags2Env.csproj 'PackagePath="native/"'
forbid_contains clients/csharp/Flags2Env.csproj '\.\./\.\./src'
require_contains clients/csharp/Flags2EnvTest.cs 'clients/csharp/native/parser\.c'
forbid_contains clients/csharp/Flags2EnvTest.cs 'build/libflags2env|tests/fixtures|\.\./\.\./tests'
require_same_file src/parser.c clients/csharp/native/parser.c
require_same_file src/parser.h clients/csharp/native/parser.h
require_contains clients/fsharp/Flags2Env.FSharp.nuspec '<files>'
require_contains clients/fsharp/Flags2Env.FSharp.nuspec '<readme>README\.md</readme>'
require_contains clients/fsharp/Flags2Env.FSharp.nuspec 'src="README\.md"'
require_contains clients/fsharp/Flags2Env.FSharp.nuspec 'exclude='
require_contains clients/fsharp/Flags2Env.FSharp.nuspec 'native/parser\.c'
require_contains clients/fsharp/Flags2Env.FSharp.nuspec 'native/parser\.h'
forbid_contains clients/fsharp/Flags2Env.FSharp.nuspec '\.\./\.\./src|\.\./\.\./clients'
require_contains clients/fsharp/Flags2Env.FSharp.fsproj 'Pack="true"'
require_contains clients/fsharp/Flags2Env.FSharp.fsproj '<PackageReadmeFile>README\.md</PackageReadmeFile>'
require_contains clients/fsharp/Flags2Env.FSharp.fsproj 'Include="README\.md"'
require_contains clients/fsharp/Flags2Env.FSharp.fsproj 'Include="native/parser\.c"'
require_contains clients/fsharp/Flags2Env.FSharp.fsproj 'Include="native/parser\.h"'
require_contains clients/fsharp/Flags2Env.FSharp.fsproj 'PackagePath="native/"'
forbid_contains clients/fsharp/Flags2Env.FSharp.fsproj '\.\./\.\./src'
require_contains clients/fsharp/Flags2EnvTest.fs 'clients/fsharp/native/parser\.c'
require_contains clients/fsharp/Flags2EnvTest.fs 'SetDllImportResolver'
forbid_contains clients/fsharp/Flags2EnvTest.fs 'build/libflags2env|tests/fixtures|\.\./\.\./tests'
require_same_file src/parser.c clients/fsharp/native/parser.c
require_same_file src/parser.h clients/fsharp/native/parser.h
require_contains clients/dart/pubspec.yaml '^description:'
require_contains clients/dart/pubspec.yaml '^repository:'
require_contains clients/dart/.pubignore '^Dockerfile$'
require_contains clients/dart/.pubignore '^\.dart_tool/$'
require_contains clients/dart/.pubignore '^pubspec\.lock$'
require_contains clients/dart/.pubignore '^test\.dart$'
require_contains clients/dart/.pubignore '^publish\.sh$'
require_contains clients/swift/Package.swift 'exclude:'
require_contains clients/nodejs/package.json.ejs '"license": "MIT"'
require_contains clients/bun/package.json.ejs '"license": "MIT"'
require_contains clients/deno/deno.json '"license": "MIT"'
require_contains clients/elixir/mix.exs 'files:'
require_contains clients/elixir/mix.exs 'name: "flags2env_elixir"'
require_contains clients/elixir/mix.exs 'erlc_paths: \["native"\]'
require_contains clients/elixir/mix.exs '"native/flags2env\.erl"'
require_contains clients/elixir/mix.exs '"native/flags2env_nif\.c"'
require_contains clients/elixir/mix.exs '"native/parser\.c"'
require_contains clients/elixir/mix.exs '"native/parser\.h"'
require_contains clients/elixir/mix.exs '"LICENSE"'
require_contains clients/elixir/LICENSE 'MIT License'
require_contains clients/elixir/README.md 'flags2env_elixir'
require_contains clients/elixir/Dockerfile 'clients/elixir/native/parser\.c'
forbid_contains clients/elixir/Dockerfile 'COPY src|COPY tests|src/parser\.c|tests/fixtures|clients/erlang'
forbid_contains clients/elixir/test.exs 'tests/fixtures|\.\./\.\./tests|\.\./\.cli-flags\.toml'
require_contains clients/elixir/test.exs 'System\.at_exit'
require_same_file clients/erlang/src/flags2env.erl clients/elixir/native/flags2env.erl
require_same_file clients/erlang/c_src/flags2env_nif.c clients/elixir/native/flags2env_nif.c
require_same_file src/parser.c clients/elixir/native/parser.c
require_same_file src/parser.h clients/elixir/native/parser.h
require_contains clients/erlang/rebar.config '\{files,'
require_contains clients/erlang/rebar.config '\{plugins, \[rebar3_hex\]\}'
require_contains clients/erlang/rebar.config '\{src_dirs, \["src"\]\}'
require_contains clients/erlang/rebar.config '"src/flags2env\.erl"'
require_contains clients/erlang/rebar.config '"src/flags2env\.app\.src"'
require_contains clients/erlang/rebar.config '"c_src/flags2env_nif\.c"'
require_contains clients/erlang/rebar.config '"c_src/parser\.c"'
require_contains clients/erlang/rebar.config '"c_src/parser\.h"'
require_contains clients/erlang/src/flags2env.app.src '\{application, flags2env,'
require_contains clients/erlang/src/flags2env.app.src '\{vsn, "0\.1\.0"\}'
require_contains clients/erlang/rebar.config '"README\.md"'
require_contains clients/erlang/rebar.config '"LICENSE"'
require_contains clients/erlang/LICENSE 'MIT License'
require_contains clients/erlang/README.md 'Erlang bindings'
require_contains clients/erlang/flags2env_test.erl 'file:delete\(Config\)'
require_contains clients/erlang/c_src/flags2env_nif.c '#include "parser\.h"'
forbid_contains clients/erlang/c_src/flags2env_nif.c '\.\./\.\./src/parser\.h'
require_contains clients/erlang/Dockerfile 'clients/erlang/c_src/parser\.c'
forbid_contains clients/erlang/Dockerfile 'COPY src|COPY tests|tests/fixtures'
require_same_file src/parser.c clients/erlang/c_src/parser.c
require_same_file src/parser.h clients/erlang/c_src/parser.h
require_contains scripts/docker-check-new-clients.sh 'run erlang-hex erlang:27'
require_contains scripts/docker-check-new-clients.sh 'rebar3 hex build package'
require_contains scripts/docker-check-new-clients.sh 'Erlang Hex package missing'
require_contains scripts/docker-check-new-clients.sh 'Erlang Hex package includes forbidden local file'
require_contains clients/gleam/Dockerfile 'clients/erlang/c_src/parser\.c'
require_contains clients/gleam/LICENSE 'MIT License'
require_contains clients/gleam/README.md 'Gleam bindings'
require_contains scripts/publish-client.sh 'gleam publish --yes'
forbid_contains clients/gleam/Dockerfile 'COPY src|COPY tests|tests/fixtures'
forbid_contains clients/gleam/test.gleam '/repo/tests|tests/fixtures'
require_contains clients/haskell/flags2env.cabal '^extra-source-files:'
require_contains clients/haskell/flags2env.cabal '^license-file: LICENSE$'
require_contains clients/haskell/flags2env.cabal '^  LICENSE$'
require_contains clients/haskell/flags2env.cabal '^  README\.md$'
require_contains clients/haskell/flags2env.cabal '^test-suite flags2env-smoke$'
require_contains clients/haskell/flags2env.cabal '^  main-is: test\.hs$'
require_contains clients/ocaml/dune '^\(test'
require_contains clients/ocaml/LICENSE 'MIT License'
require_contains clients/ocaml/README.md 'OCaml bindings'
require_contains clients/ocaml/flags2env.opam '^build:'
require_contains clients/ocaml/flags2env.opam '\{with-test\}'
require_contains clients/ocaml/test.ml 'Sys\.remove config_path'
require_contains clients/reasonml/dune-project '\(name flags2env_reason\)'
require_contains clients/reasonml/dune-project '\(name flags2env-reason\)'
require_contains clients/reasonml/LICENSE 'MIT License'
require_contains clients/reasonml/README.md 'ReasonML facade'
require_contains clients/reasonml/flags2env-reason.opam '^build:'
require_contains clients/reasonml/flags2env-reason.opam '"reason"'
require_contains clients/reasonml/flags2env-reason.opam '"flags2env"'
require_contains clients/reasonml/flags2env-reason.opam '\{with-test\}'
require_absent clients/reasonml/flags2env.opam
require_contains clients/reasonml/src/dune '^\(test'
require_contains clients/reasonml/src/Test.re 'Sys\.remove\(configPath\)'
require_contains clients/perl/MANIFEST.SKIP '^\^blib/'
require_contains clients/perl/MANIFEST.SKIP '^\^publish\\\.sh\$'
require_contains clients/perl/MANIFEST.SKIP '^\^test\\\.pl\$'
require_contains clients/perl/MANIFEST.SKIP '^\^MYMETA\\\.'
require_contains clients/lua/flags2env-dev-1.rockspec '^build ='
require_contains clients/lua/LICENSE 'MIT License'
require_contains clients/lua/README.md 'LuaJIT FFI bindings'
require_contains clients/lua/flags2env-dev-1.rockspec 'clients/lua/flags2env\.lua'
require_contains clients/lua/flags2env-0.1.0-1.rockspec '^version = "0\.1\.0-1"'
require_contains clients/lua/flags2env-0.1.0-1.rockspec 'tag = "v0\.1\.0"'
require_contains clients/lua/flags2env-0.1.0-1.rockspec 'clients/lua/flags2env\.lua'
require_contains clients/lua/test.lua 'os\.remove\(config\)'
require_contains scripts/docker-check-new-clients.sh 'luarocks lint clients/lua/flags2env-0\.1\.0-1\.rockspec'
require_contains scripts/docker-check-new-clients.sh 'luarocks lint clients/lua/flags2env-dev-1\.rockspec'
require_contains clients/nim/flags2env.nimble '^installFiles'
require_contains clients/nim/LICENSE 'MIT License'
require_contains clients/nim/README.md 'Nim bindings'
require_contains clients/nim/test.nim 'import std/os'
require_contains clients/nim/test.nim 'removeFile\(config\)'
require_contains scripts/docker-check-new-clients.sh 'cd clients/nim && nimble check'
require_contains clients/r/.Rbuildignore '\^Dockerfile\$'
require_contains clients/r/DESCRIPTION 'License: MIT \+ file LICENSE'
require_contains clients/r/LICENSE 'COPYRIGHT HOLDER: ORESoftware'
require_contains clients/r/README.md 'R bindings'
require_contains clients/r/src/Makevars '^OBJECTS = flags2env_r\.o parser\.o$'
require_contains clients/r/src/Makevars '^PKG_CPPFLAGS = -I\.$'
forbid_contains clients/r/src/Makevars '^parser\.o:'
require_contains clients/r/man/flags2env.Rd '\\alias\{parse_flags\}'
require_contains clients/r/man/flags2env.Rd '\\alias\{parse_process\}'
require_contains clients/r/man/flags2env.Rd '\\alias\{apply_flags\}'
forbid_contains clients/r/src/Makevars '\.\./\.\./\.\./src'
require_contains clients/r/src/flags2env_r.c '#include "parser\.h"'
forbid_contains clients/r/src/flags2env_r.c '\.\./\.\./\.\./src/parser\.h'
require_same_file src/parser.c clients/r/src/parser.c
require_same_file src/parser.h clients/r/src/parser.h
require_contains clients/r/tests/smoke.R 'parse_flags'
require_contains clients/r/tests/smoke.R 'on\.exit\(unlink\(config\), add = TRUE\)'
require_contains scripts/docker-check-new-clients.sh 'R CMD build clients/r'
require_contains scripts/docker-check-new-clients.sh 'R CMD check --no-manual flags2env_0\.1\.0\.tar\.gz'
require_contains scripts/docker-check-new-clients.sh 'R source package missing'
require_contains scripts/docker-check-new-clients.sh 'R source package includes forbidden local file'
require_contains clients/matlab/test.m 'flags2env\.parse'
require_contains clients/matlab/LICENSE 'MIT License'
require_contains clients/matlab/README.md 'MATLAB bindings'
require_contains clients/matlab/+flags2env/defaultHeaderPath.m 'native'
require_contains clients/matlab/+flags2env/ensureLoaded.m 'flags2env\.defaultHeaderPath\(\)'
forbid_contains clients/matlab/+flags2env/apply.m 'fullfile\(pwd, "src", "parser\.h"\)'
forbid_contains clients/matlab/+flags2env/ensureLoaded.m 'fullfile\(pwd, "src", "parser\.h"\)'
forbid_contains clients/matlab/+flags2env/parse.m 'fullfile\(pwd, "src", "parser\.h"\)'
forbid_contains clients/matlab/+flags2env/parseProcess.m 'fullfile\(pwd, "src", "parser\.h"\)'
require_same_file src/parser.c clients/matlab/native/parser.c
require_same_file src/parser.h clients/matlab/native/parser.h
require_contains scripts/audit-client-packaging.sh 'audit_matlab_archive'
require_contains scripts/audit-client-packaging.sh 'MATLAB source archive missing'
require_contains scripts/audit-client-packaging.sh 'MATLAB source archive includes forbidden file'
require_contains clients/julia/Project.toml '^name = "Flags2Env"'
require_contains clients/julia/Project.toml '^uuid = "[0-9a-f-]{36}"'
require_contains clients/julia/Project.toml '^version = "0\.1\.0"'
require_contains clients/julia/REGISTRATION.md '@JuliaRegistrator register subdir=clients/julia'
require_contains clients/julia/test/runtests.jl 'atexit'
require_contains clients/solidity/package.json '"files"'
require_contains clients/solidity/package.json '"README\.md"'
require_contains clients/solidity/package.json '"LICENSE"'
require_contains clients/solidity/package.json '"test"'
require_contains clients/solidity/package.json '"solc"'
require_contains clients/solidity/package.json '"overrides"'
require_contains clients/solidity/package.json '"tmp": "\^0\.2\.6"'
require_path clients/solidity/package-lock.json
require_contains clients/solidity/LICENSE 'MIT License'
require_contains clients/solidity/README.md 'Solidity'
require_contains scripts/docker-check-new-clients.sh 'Solidity npm package missing'
require_contains scripts/docker-check-new-clients.sh 'Solidity npm package includes forbidden local file'
require_contains scripts/docker-check-new-clients.sh 'cd clients/solidity && npm ci --ignore-scripts && npm audit'
require_contains scripts/docker-check-new-clients.sh 'run packaging node:24-bookworm'
require_contains scripts/docker-check-new-clients.sh 'build-essential perl ruby zip unzip && make clean && make all && sh scripts/audit-client-packaging\.sh'
require_contains clients/fortran/LICENSE 'MIT License'
require_contains clients/fortran/README.md 'Fortran bindings'
require_contains clients/fortran/fpm.toml '^name = "flags2env"$'
require_contains clients/fortran/fpm.toml '^version = "0\.1\.0"$'
require_contains clients/fortran/fpm.toml '^license = "MIT"$'
require_contains clients/fortran/fpm.toml '^\[library\]'
require_contains clients/fortran/fpm.toml '^source-dir = "src"$'
require_contains clients/fortran/fpm.toml '^\[\[test\]\]'
require_contains clients/fortran/fpm.toml '^main = "test\.f90"$'
require_contains scripts/docker-check-new-clients.sh 'apt-get install -y --no-install-recommends gfortran-12'
require_contains scripts/docker-check-new-clients.sh 'gfortran-12 -c clients/fortran/src/flags2env\.f90'
require_contains scripts/docker-check-new-clients.sh '\[--only LABEL\]'
require_contains scripts/docker-check-new-clients.sh 'unknown or disabled client label'
require_contains scripts/docker-check-new-clients.sh 'run php php:8\.3-cli-bookworm'
require_contains scripts/docker-check-new-clients.sh 'getcomposer\.org/download/2\.10\.2/composer\.phar'
require_contains scripts/docker-check-new-clients.sh '5ee7125f8a30a34d246cefdc0bc85b8a783b28f2aec968994118512350d28027'
require_contains scripts/docker-check-new-clients.sh 'composer archive --format=zip --dir=/tmp --file=flags2env-php-archive'
forbid_contains scripts/docker-check-new-clients.sh 'apt-get install[^&]* composer'
require_contains scripts/docker-check-new-clients.sh 'clients/fortran/src/parser\.c'
forbid_contains scripts/docker-check-new-clients.sh ' -c src/parser\.c -o /tmp/flags2env-parser\.o'
require_same_file src/parser.c clients/fortran/src/parser.c
require_same_file src/parser.h clients/fortran/src/parser.h
require_contains clients/zig/build.zig 'native/parser\.c'
require_contains clients/zig/build.zig 'b\.path\("native"\)'
require_contains clients/zig/build.zig.zon '\.minimum_zig_version = "0\.14\.0"'
require_contains clients/zig/build.zig.zon '\.paths'
require_contains clients/zig/build.zig.zon '"test\.zig"'
require_contains clients/zig/build.zig.zon '"README\.md"'
require_contains clients/zig/build.zig.zon '"LICENSE"'
require_contains scripts/docker-check-new-clients.sh 'run zig kassany/bookworm-ziglang:0\.14\.0'
require_contains clients/zig/LICENSE 'MIT License'
require_contains clients/zig/README.md 'Zig bindings'
forbid_contains clients/zig/build.zig '\.\./\.\./src'
require_same_file src/parser.c clients/zig/native/parser.c
require_same_file src/parser.h clients/zig/native/parser.h
require_contains clients/crystal/LICENSE 'MIT License'
require_contains clients/crystal/README.md 'Crystal bindings'
require_contains clients/crystal/shard.yml '^version: 0\.1\.0$'
require_contains clients/crystal/shard.yml '^license: MIT$'
require_contains clients/crystal/shard.yml '^repository: https://github\.com/flags-2-env/flags-2-env$'
require_contains scripts/docker-check-new-clients.sh 'cd clients/crystal && shards install &&'
require_contains scripts/docker-check-new-clients.sh 'crystal run --link-flags "-L/work/build" clients/crystal/test\.cr'
forbid_contains scripts/docker-check-new-clients.sh 'shards install --production'
require_path clients/oreslang/.ores.pkg.toml
require_path clients/oreslang/LICENSE
require_path clients/oreslang/README.md
require_path clients/oreslang/src/flags2env.ores
require_path clients/oreslang/native/flags2env_ores_bridge.c
require_path clients/oreslang/native/flags2env_ores_bridge.h
require_path clients/oreslang/native/bridge_test.c
require_path clients/oreslang/native/bridge_fault_test.c
require_path clients/oreslang/native/parser.c
require_path clients/oreslang/native/parser.h
require_path clients/oreslang/tests/client_contract.ores
require_path clients/oreslang/tests/abi-status-scalar.ores
require_path clients/oreslang/tests/source_contract.mjs
require_same_file src/parser.c clients/oreslang/native/parser.c
require_same_file src/parser.h clients/oreslang/native/parser.h
require_contains clients/oreslang/native/flags2env_ores_bridge.c '#include "parser\.h"'
forbid_contains clients/oreslang/native/flags2env_ores_bridge.c '\.\./\.\./\.\./src/parser\.h'
require_contains clients/oreslang/.ores.pkg.toml '^name = "flags2env"require_contains scripts/render-client.mjs 'src/parser\.c'
require_contains scripts/render-client.mjs 'native'
forbid_contains scripts/publish-client.sh 'cp src/parser\.c src/parser\.h dist/r/src/'
require_contains scripts/publish-client.sh 'npm publish --access public'
require_contains scripts/publish-client.sh 'node scripts/render-client\.mjs deno dist/deno'
require_contains scripts/publish-client.sh '\$\{PYTHON:-python3\} -m build'
require_contains scripts/publish-client.sh 'twine upload'
require_contains scripts/publish-client.sh 'clients/golang/v\$'
require_contains scripts/publish-client.sh 'git tag "\$\{PACKAGE_VERSION:\?set PACKAGE_VERSION\}"'
require_contains scripts/publish-client.sh 'git push origin "v\$\{PACKAGE_VERSION\}"'
require_contains scripts/publish-client.sh 'scripts/publish-homebrew\.sh --release'
require_contains scripts/publish-client.sh 'mvn -P release deploy'
require_contains scripts/publish-client.sh 'gradle -Prelease publish'
require_contains scripts/publish-client.sh 'sbt publishSigned sonatypeBundleRelease'
require_contains scripts/publish-client.sh 'publish-central-ossrh-compat\.sh'
require_contains scripts/publish-client.sh 'dotnet nuget push'
require_contains scripts/publish-client.sh 'gem push'
require_contains scripts/publish-client.sh 'dart pub publish'
require_contains scripts/publish-client.sh 'mix hex.publish'
require_contains scripts/publish-client.sh 'rebar3 hex publish'
require_contains scripts/publish-client.sh 'gleam publish --yes'
require_contains scripts/publish-client.sh 'cabal upload'
require_contains scripts/publish-client.sh 'opam publish submit'
require_contains scripts/publish-client.sh 'opam lint flags2env-reason\.opam'
require_contains scripts/publish-client.sh 'cpan-upload'
require_contains scripts/publish-client.sh 'luarocks upload flags2env-0\.1\.0-1\.rockspec'
require_contains scripts/publish-client.sh 'nimble publish'
require_contains scripts/publish-client.sh 'submit_cran'
require_contains scripts/publish-client.sh 'zip -r flags2env-matlab\.zip \+flags2env native README\.md LICENSE'
require_contains scripts/publish-client.sh '@JuliaRegistrator register subdir=clients/julia'
require_contains scripts/docker-check-new-clients.sh 'dotnet run'
require_contains scripts/docker-check-new-clients.sh 'dotnet run --project /tmp/f2e-csharp-test/f2e-csharp-test\.csproj'
require_contains scripts/docker-check-new-clients.sh 'dotnet run --project /tmp/f2e-fsharp-test/f2e-fsharp-test\.fsproj'
require_contains scripts/docker-check-new-clients.sh 'dotnet pack clients/csharp/Flags2Env\.csproj -c Release'
require_contains scripts/docker-check-new-clients.sh 'dotnet pack clients/fsharp/Flags2Env\.FSharp\.fsproj -c Release'
require_contains scripts/docker-check-new-clients.sh 'OreSoftware\.Flags2Env\.\*\.nupkg'
require_contains scripts/docker-check-new-clients.sh 'OreSoftware\.Flags2Env\.FSharp\.\*\.nupkg'
require_contains scripts/docker-check-new-clients.sh 'missing net6\.0 library'
forbid_contains scripts/docker-check-new-clients.sh 'FLAGS2ENV_FIXTURE=tests/fixtures|FLAGS2ENV_NATIVE_LIB=build/libflags2env\.so.*dotnet|LD_LIBRARY_PATH=build.*dotnet'
require_contains scripts/docker-check-new-clients.sh 'cmake --build /tmp/flags2env-cpp-build --verbose'
require_contains README.md 'undefined dynamic_lookup'
require_contains .github/workflows/client-packaging.yml 'scripts/audit-client-packaging\.sh'
require_contains .github/workflows/client-packaging.yml 'npm run release:audit'
require_contains .github/workflows/client-packaging.yml 'scripts/docker-check-new-clients\.sh'
require_contains .github/workflows/client-packaging.yml 'full_docker_checks'
require_contains .github/workflows/client-packaging.yml 'tests/run\.sh'
require_contains .github/workflows/client-packaging.yml 'tests/codegen-docker/run\.sh'
require_contains tests/codegen-docker/Dockerfile 'FROM dart:stable AS test-dart'
require_contains tests/codegen-docker/Dockerfile 'FROM node:22-bookworm AS test-nodejs'
require_contains tests/codegen-docker/nodejs/main.ts 'f2e\.coerce'
require_contains tests/codegen-docker/run.sh 'json-schema'
require_contains .github/workflows/cli-flags-audit.yml 'scripts/audit-changed-cli-flags\.sh'
require_contains .github/workflows/cli-flags-audit.yml '\*\*/\.cli-flags\.toml'
require_contains .github/workflows/cli-flags-audit.yml '\*\*/\.env'
require_contains scripts/audit-changed-cli-flags.sh 'audit env'

for path in \
  clients/cpp/test.cpp \
  clients/scala/src/main/scala/com/oresoftware/flags2env/Flags2Env.scala \
  clients/groovy/src/main/groovy/com/oresoftware/flags2env/Flags2Env.groovy \
  clients/kotlin/src/main/kotlin/com/oresoftware/flags2env/Flags2Env.kt \
  clients/clojure/src/com/oresoftware/flags2env.clj \
  clients/csharp/Flags2EnvTest.cs \
  clients/fsharp/Flags2EnvTest.fs \
  clients/rust/tests/smoke.rs \
  clients/elixir/test.exs \
  clients/erlang/flags2env_test.erl \
  clients/gleam/test.gleam \
  clients/r/R/flags2env.R \
  clients/r/tests/smoke.R \
  clients/matlab/+flags2env/defaultHeaderPath.m \
  clients/matlab/test.m \
  clients/fortran/src/flags2env.f90 \
  clients/fortran/test.f90 \
  clients/zig/src/flags2env.zig \
  clients/zig/test.zig \
  clients/crystal/src/flags2env.cr \
  clients/solidity/contracts/Flags2Env.sol \
  clients/perl/test.pl \
  clients/lua/test.lua \
  clients/nim/test.nim \
  clients/crystal/test.cr \
  clients/julia/test/runtests.jl \
  clients/haskell/test.hs \
  clients/ocaml/test.ml \
  clients/reasonml/src/Test.re
do
  require_path "$path"
done

for path in \
  clients/cpp/test.cpp \
  clients/crystal/test.cr \
  clients/fortran/test.f90 \
  clients/haskell/test.hs \
  clients/julia/test/runtests.jl \
  clients/lua/test.lua \
  clients/nim/test.nim \
  clients/ocaml/test.ml \
  clients/reasonml/src/Test.re \
  clients/rust/tests/smoke.rs \
  clients/zig/test.zig
do
  forbid_contains "$path" 'tests/fixtures|\.\./\.\./tests'
done

native_lib="$(native_library_name)"
require_contains src/parser.h 'f2e_generate_types_from_file'
require_contains src/parser.h 'f2e_coerce_json_from_file'
require_contains clients/nodejs/addon.c 'coerceJson'
require_contains clients/nodejs/addon.c 'generateTypes'
require_contains clients/nodejs/lib.mjs 'export function coerce'
require_contains clients/nodejs/lib.mjs 'export function parseFromArgs'
require_contains clients/nodejs/lib.mjs 'export function generateTypes'
require_contains clients/nodejs/lib.cjs 'CoercionError'
require_contains clients/nodejs/lib.ts 'export function coerce'
require_contains clients/nodejs/cli.mjs '"generate"'
audit_rendered_js_client nodejs package.json binding.gyp addon.c src/parser.c src/parser.h lib.mjs lib.cjs lib.ts cli.mjs
audit_rendered_js_client bun package.json "native/$native_lib" lib.mjs lib.cjs lib.ts
audit_rendered_js_client deno deno.json "native/$native_lib" mod.ts lib.ts
audit_npm_pack_client solidity "contracts/Flags2Env.sol package.json README.md LICENSE" "test.js test.ts Dockerfile"
audit_perl_manifest
audit_ruby_gem
audit_r_staging
audit_matlab_archive
audit_docker_check_plan

if [ "$status" -eq 0 ]; then
  printf 'client packaging audit passed\n'
fi
exit "$status"

require_contains clients/oreslang/.ores.pkg.toml '^roots = \["src"\]require_contains scripts/render-client.mjs 'src/parser\.c'
require_contains scripts/render-client.mjs 'native'
forbid_contains scripts/publish-client.sh 'cp src/parser\.c src/parser\.h dist/r/src/'
require_contains scripts/publish-client.sh 'npm publish --access public'
require_contains scripts/publish-client.sh 'node scripts/render-client\.mjs deno dist/deno'
require_contains scripts/publish-client.sh '\$\{PYTHON:-python3\} -m build'
require_contains scripts/publish-client.sh 'twine upload'
require_contains scripts/publish-client.sh 'clients/golang/v\$'
require_contains scripts/publish-client.sh 'git tag "\$\{PACKAGE_VERSION:\?set PACKAGE_VERSION\}"'
require_contains scripts/publish-client.sh 'git push origin "v\$\{PACKAGE_VERSION\}"'
require_contains scripts/publish-client.sh 'scripts/publish-homebrew\.sh --release'
require_contains scripts/publish-client.sh 'mvn -P release deploy'
require_contains scripts/publish-client.sh 'gradle -Prelease publish'
require_contains scripts/publish-client.sh 'sbt publishSigned sonatypeBundleRelease'
require_contains scripts/publish-client.sh 'publish-central-ossrh-compat\.sh'
require_contains scripts/publish-client.sh 'dotnet nuget push'
require_contains scripts/publish-client.sh 'gem push'
require_contains scripts/publish-client.sh 'dart pub publish'
require_contains scripts/publish-client.sh 'mix hex.publish'
require_contains scripts/publish-client.sh 'rebar3 hex publish'
require_contains scripts/publish-client.sh 'gleam publish --yes'
require_contains scripts/publish-client.sh 'cabal upload'
require_contains scripts/publish-client.sh 'opam publish submit'
require_contains scripts/publish-client.sh 'opam lint flags2env-reason\.opam'
require_contains scripts/publish-client.sh 'cpan-upload'
require_contains scripts/publish-client.sh 'luarocks upload flags2env-0\.1\.0-1\.rockspec'
require_contains scripts/publish-client.sh 'nimble publish'
require_contains scripts/publish-client.sh 'submit_cran'
require_contains scripts/publish-client.sh 'zip -r flags2env-matlab\.zip \+flags2env native README\.md LICENSE'
require_contains scripts/publish-client.sh '@JuliaRegistrator register subdir=clients/julia'
require_contains scripts/docker-check-new-clients.sh 'dotnet run'
require_contains scripts/docker-check-new-clients.sh 'dotnet run --project /tmp/f2e-csharp-test/f2e-csharp-test\.csproj'
require_contains scripts/docker-check-new-clients.sh 'dotnet run --project /tmp/f2e-fsharp-test/f2e-fsharp-test\.fsproj'
require_contains scripts/docker-check-new-clients.sh 'dotnet pack clients/csharp/Flags2Env\.csproj -c Release'
require_contains scripts/docker-check-new-clients.sh 'dotnet pack clients/fsharp/Flags2Env\.FSharp\.fsproj -c Release'
require_contains scripts/docker-check-new-clients.sh 'OreSoftware\.Flags2Env\.\*\.nupkg'
require_contains scripts/docker-check-new-clients.sh 'OreSoftware\.Flags2Env\.FSharp\.\*\.nupkg'
require_contains scripts/docker-check-new-clients.sh 'missing net6\.0 library'
forbid_contains scripts/docker-check-new-clients.sh 'FLAGS2ENV_FIXTURE=tests/fixtures|FLAGS2ENV_NATIVE_LIB=build/libflags2env\.so.*dotnet|LD_LIBRARY_PATH=build.*dotnet'
require_contains scripts/docker-check-new-clients.sh 'cmake --build /tmp/flags2env-cpp-build --verbose'
require_contains README.md 'undefined dynamic_lookup'
require_contains .github/workflows/client-packaging.yml 'scripts/audit-client-packaging\.sh'
require_contains .github/workflows/client-packaging.yml 'npm run release:audit'
require_contains .github/workflows/client-packaging.yml 'scripts/docker-check-new-clients\.sh'
require_contains .github/workflows/client-packaging.yml 'full_docker_checks'
require_contains .github/workflows/client-packaging.yml 'tests/run\.sh'
require_contains .github/workflows/client-packaging.yml 'tests/codegen-docker/run\.sh'
require_contains tests/codegen-docker/Dockerfile 'FROM dart:stable AS test-dart'
require_contains tests/codegen-docker/Dockerfile 'FROM node:22-bookworm AS test-nodejs'
require_contains tests/codegen-docker/nodejs/main.ts 'f2e\.coerce'
require_contains tests/codegen-docker/run.sh 'json-schema'
require_contains .github/workflows/cli-flags-audit.yml 'scripts/audit-changed-cli-flags\.sh'
require_contains .github/workflows/cli-flags-audit.yml '\*\*/\.cli-flags\.toml'
require_contains .github/workflows/cli-flags-audit.yml '\*\*/\.env'
require_contains scripts/audit-changed-cli-flags.sh 'audit env'

for path in \
  clients/cpp/test.cpp \
  clients/scala/src/main/scala/com/oresoftware/flags2env/Flags2Env.scala \
  clients/groovy/src/main/groovy/com/oresoftware/flags2env/Flags2Env.groovy \
  clients/kotlin/src/main/kotlin/com/oresoftware/flags2env/Flags2Env.kt \
  clients/clojure/src/com/oresoftware/flags2env.clj \
  clients/csharp/Flags2EnvTest.cs \
  clients/fsharp/Flags2EnvTest.fs \
  clients/rust/tests/smoke.rs \
  clients/elixir/test.exs \
  clients/erlang/flags2env_test.erl \
  clients/gleam/test.gleam \
  clients/r/R/flags2env.R \
  clients/r/tests/smoke.R \
  clients/matlab/+flags2env/defaultHeaderPath.m \
  clients/matlab/test.m \
  clients/fortran/src/flags2env.f90 \
  clients/fortran/test.f90 \
  clients/zig/src/flags2env.zig \
  clients/zig/test.zig \
  clients/crystal/src/flags2env.cr \
  clients/solidity/contracts/Flags2Env.sol \
  clients/perl/test.pl \
  clients/lua/test.lua \
  clients/nim/test.nim \
  clients/crystal/test.cr \
  clients/julia/test/runtests.jl \
  clients/haskell/test.hs \
  clients/ocaml/test.ml \
  clients/reasonml/src/Test.re
do
  require_path "$path"
done

for path in \
  clients/cpp/test.cpp \
  clients/crystal/test.cr \
  clients/fortran/test.f90 \
  clients/haskell/test.hs \
  clients/julia/test/runtests.jl \
  clients/lua/test.lua \
  clients/nim/test.nim \
  clients/ocaml/test.ml \
  clients/reasonml/src/Test.re \
  clients/rust/tests/smoke.rs \
  clients/zig/test.zig
do
  forbid_contains "$path" 'tests/fixtures|\.\./\.\./tests'
done

native_lib="$(native_library_name)"
require_contains src/parser.h 'f2e_generate_types_from_file'
require_contains src/parser.h 'f2e_coerce_json_from_file'
require_contains clients/nodejs/addon.c 'coerceJson'
require_contains clients/nodejs/addon.c 'generateTypes'
require_contains clients/nodejs/lib.mjs 'export function coerce'
require_contains clients/nodejs/lib.mjs 'export function parseFromArgs'
require_contains clients/nodejs/lib.mjs 'export function generateTypes'
require_contains clients/nodejs/lib.cjs 'CoercionError'
require_contains clients/nodejs/lib.ts 'export function coerce'
require_contains clients/nodejs/cli.mjs '"generate"'
audit_rendered_js_client nodejs package.json binding.gyp addon.c src/parser.c src/parser.h lib.mjs lib.cjs lib.ts cli.mjs
audit_rendered_js_client bun package.json "native/$native_lib" lib.mjs lib.cjs lib.ts
audit_rendered_js_client deno deno.json "native/$native_lib" mod.ts lib.ts
audit_npm_pack_client solidity "contracts/Flags2Env.sol package.json README.md LICENSE" "test.js test.ts Dockerfile"
audit_perl_manifest
audit_ruby_gem
audit_r_staging
audit_matlab_archive
audit_docker_check_plan

if [ "$status" -eq 0 ]; then
  printf 'client packaging audit passed\n'
fi
exit "$status"

require_contains clients/oreslang/README.md 'evidence-gated'
require_contains contracts/oreslang-client-backends.v1.json '"unsupported_is_pass": false'
require_contains contracts/oreslang-client-backends.v1.json '"zero_step_ci_is_pass": false'
require_contains scripts/publish-client.sh 'clients/oreslang/v\$\{PACKAGE_VERSION'
require_contains clients/deno/deno.json '"native"'
require_contains scripts/render-client.mjs 'src/parser\.c'
require_contains scripts/render-client.mjs 'native'
forbid_contains scripts/publish-client.sh 'cp src/parser\.c src/parser\.h dist/r/src/'
require_contains scripts/publish-client.sh 'npm publish --access public'
require_contains scripts/publish-client.sh 'node scripts/render-client\.mjs deno dist/deno'
require_contains scripts/publish-client.sh '\$\{PYTHON:-python3\} -m build'
require_contains scripts/publish-client.sh 'twine upload'
require_contains scripts/publish-client.sh 'clients/golang/v\$'
require_contains scripts/publish-client.sh 'git tag "\$\{PACKAGE_VERSION:\?set PACKAGE_VERSION\}"'
require_contains scripts/publish-client.sh 'git push origin "v\$\{PACKAGE_VERSION\}"'
require_contains scripts/publish-client.sh 'scripts/publish-homebrew\.sh --release'
require_contains scripts/publish-client.sh 'mvn -P release deploy'
require_contains scripts/publish-client.sh 'gradle -Prelease publish'
require_contains scripts/publish-client.sh 'sbt publishSigned sonatypeBundleRelease'
require_contains scripts/publish-client.sh 'publish-central-ossrh-compat\.sh'
require_contains scripts/publish-client.sh 'dotnet nuget push'
require_contains scripts/publish-client.sh 'gem push'
require_contains scripts/publish-client.sh 'dart pub publish'
require_contains scripts/publish-client.sh 'mix hex.publish'
require_contains scripts/publish-client.sh 'rebar3 hex publish'
require_contains scripts/publish-client.sh 'gleam publish --yes'
require_contains scripts/publish-client.sh 'cabal upload'
require_contains scripts/publish-client.sh 'opam publish submit'
require_contains scripts/publish-client.sh 'opam lint flags2env-reason\.opam'
require_contains scripts/publish-client.sh 'cpan-upload'
require_contains scripts/publish-client.sh 'luarocks upload flags2env-0\.1\.0-1\.rockspec'
require_contains scripts/publish-client.sh 'nimble publish'
require_contains scripts/publish-client.sh 'submit_cran'
require_contains scripts/publish-client.sh 'zip -r flags2env-matlab\.zip \+flags2env native README\.md LICENSE'
require_contains scripts/publish-client.sh '@JuliaRegistrator register subdir=clients/julia'
require_contains scripts/docker-check-new-clients.sh 'dotnet run'
require_contains scripts/docker-check-new-clients.sh 'dotnet run --project /tmp/f2e-csharp-test/f2e-csharp-test\.csproj'
require_contains scripts/docker-check-new-clients.sh 'dotnet run --project /tmp/f2e-fsharp-test/f2e-fsharp-test\.fsproj'
require_contains scripts/docker-check-new-clients.sh 'dotnet pack clients/csharp/Flags2Env\.csproj -c Release'
require_contains scripts/docker-check-new-clients.sh 'dotnet pack clients/fsharp/Flags2Env\.FSharp\.fsproj -c Release'
require_contains scripts/docker-check-new-clients.sh 'OreSoftware\.Flags2Env\.\*\.nupkg'
require_contains scripts/docker-check-new-clients.sh 'OreSoftware\.Flags2Env\.FSharp\.\*\.nupkg'
require_contains scripts/docker-check-new-clients.sh 'missing net6\.0 library'
forbid_contains scripts/docker-check-new-clients.sh 'FLAGS2ENV_FIXTURE=tests/fixtures|FLAGS2ENV_NATIVE_LIB=build/libflags2env\.so.*dotnet|LD_LIBRARY_PATH=build.*dotnet'
require_contains scripts/docker-check-new-clients.sh 'cmake --build /tmp/flags2env-cpp-build --verbose'
require_contains README.md 'undefined dynamic_lookup'
require_contains .github/workflows/client-packaging.yml 'scripts/audit-client-packaging\.sh'
require_contains .github/workflows/client-packaging.yml 'npm run release:audit'
require_contains .github/workflows/client-packaging.yml 'scripts/docker-check-new-clients\.sh'
require_contains .github/workflows/client-packaging.yml 'full_docker_checks'
require_contains .github/workflows/client-packaging.yml 'tests/run\.sh'
require_contains .github/workflows/client-packaging.yml 'tests/codegen-docker/run\.sh'
require_contains tests/codegen-docker/Dockerfile 'FROM dart:stable AS test-dart'
require_contains tests/codegen-docker/Dockerfile 'FROM node:22-bookworm AS test-nodejs'
require_contains tests/codegen-docker/nodejs/main.ts 'f2e\.coerce'
require_contains tests/codegen-docker/run.sh 'json-schema'
require_contains .github/workflows/cli-flags-audit.yml 'scripts/audit-changed-cli-flags\.sh'
require_contains .github/workflows/cli-flags-audit.yml '\*\*/\.cli-flags\.toml'
require_contains .github/workflows/cli-flags-audit.yml '\*\*/\.env'
require_contains scripts/audit-changed-cli-flags.sh 'audit env'

for path in \
  clients/cpp/test.cpp \
  clients/scala/src/main/scala/com/oresoftware/flags2env/Flags2Env.scala \
  clients/groovy/src/main/groovy/com/oresoftware/flags2env/Flags2Env.groovy \
  clients/kotlin/src/main/kotlin/com/oresoftware/flags2env/Flags2Env.kt \
  clients/clojure/src/com/oresoftware/flags2env.clj \
  clients/csharp/Flags2EnvTest.cs \
  clients/fsharp/Flags2EnvTest.fs \
  clients/rust/tests/smoke.rs \
  clients/elixir/test.exs \
  clients/erlang/flags2env_test.erl \
  clients/gleam/test.gleam \
  clients/r/R/flags2env.R \
  clients/r/tests/smoke.R \
  clients/matlab/+flags2env/defaultHeaderPath.m \
  clients/matlab/test.m \
  clients/fortran/src/flags2env.f90 \
  clients/fortran/test.f90 \
  clients/zig/src/flags2env.zig \
  clients/zig/test.zig \
  clients/crystal/src/flags2env.cr \
  clients/solidity/contracts/Flags2Env.sol \
  clients/perl/test.pl \
  clients/lua/test.lua \
  clients/nim/test.nim \
  clients/crystal/test.cr \
  clients/julia/test/runtests.jl \
  clients/haskell/test.hs \
  clients/ocaml/test.ml \
  clients/reasonml/src/Test.re
do
  require_path "$path"
done

for path in \
  clients/cpp/test.cpp \
  clients/crystal/test.cr \
  clients/fortran/test.f90 \
  clients/haskell/test.hs \
  clients/julia/test/runtests.jl \
  clients/lua/test.lua \
  clients/nim/test.nim \
  clients/ocaml/test.ml \
  clients/reasonml/src/Test.re \
  clients/rust/tests/smoke.rs \
  clients/zig/test.zig
do
  forbid_contains "$path" 'tests/fixtures|\.\./\.\./tests'
done

native_lib="$(native_library_name)"
require_contains src/parser.h 'f2e_generate_types_from_file'
require_contains src/parser.h 'f2e_coerce_json_from_file'
require_contains clients/nodejs/addon.c 'coerceJson'
require_contains clients/nodejs/addon.c 'generateTypes'
require_contains clients/nodejs/lib.mjs 'export function coerce'
require_contains clients/nodejs/lib.mjs 'export function parseFromArgs'
require_contains clients/nodejs/lib.mjs 'export function generateTypes'
require_contains clients/nodejs/lib.cjs 'CoercionError'
require_contains clients/nodejs/lib.ts 'export function coerce'
require_contains clients/nodejs/cli.mjs '"generate"'
audit_rendered_js_client nodejs package.json binding.gyp addon.c src/parser.c src/parser.h lib.mjs lib.cjs lib.ts cli.mjs
audit_rendered_js_client bun package.json "native/$native_lib" lib.mjs lib.cjs lib.ts
audit_rendered_js_client deno deno.json "native/$native_lib" mod.ts lib.ts
audit_npm_pack_client solidity "contracts/Flags2Env.sol package.json README.md LICENSE" "test.js test.ts Dockerfile"
audit_perl_manifest
audit_ruby_gem
audit_r_staging
audit_matlab_archive
audit_docker_check_plan

if [ "$status" -eq 0 ]; then
  printf 'client packaging audit passed\n'
fi
exit "$status"
