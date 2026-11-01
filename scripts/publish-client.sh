#!/usr/bin/env sh
set -eu

INVOKED_PATH="$0"
INVOKED_DIR="$(CDPATH= cd -- "$(dirname -- "$INVOKED_PATH")" && pwd)"
SCRIPT_PATH="$INVOKED_PATH"
while [ -L "$SCRIPT_PATH" ]; do
  script_dir="$(dirname -- "$SCRIPT_PATH")"
  target="$(readlink "$SCRIPT_PATH")"
  case "$target" in
    /*) SCRIPT_PATH="$target" ;;
    *) SCRIPT_PATH="$script_dir/$target" ;;
  esac
done

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$SCRIPT_PATH")/.." && pwd)"

client="${1:-}"
case "$client" in
  --*)
    client=""
    ;;
  "")
    ;;
  *)
    shift
    ;;
esac

if [ -z "$client" ]; then
  if [ "$(basename "$(dirname "$INVOKED_DIR")")" = "clients" ]; then
    client="$(basename "$INVOKED_DIR")"
  else
    client="$(basename "$(pwd)")"
  fi
fi

release=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --release)
      release=1
      ;;
    --dry-run)
      release=0
      ;;
    *)
      printf 'usage: %s [client] [--dry-run|--release]\n' "$0" >&2
      exit 2
      ;;
  esac
  shift
done

CLIENT_DIR="$ROOT_DIR/clients/$client"
if [ ! -d "$CLIENT_DIR" ]; then
  printf 'unknown flags2env client: %s\n' "$client" >&2
  exit 2
fi

run() {
  command="$1"
  if [ "$release" -eq 1 ]; then
    printf 'publishing %s: %s\n' "$client" "$command"
    (cd "$CLIENT_DIR" && sh -eu -c "$command")
  else
    printf '[dry-run] %s: %s\n' "$client" "$command"
  fi
}

run_root() {
  command="$1"
  if [ "$release" -eq 1 ]; then
    printf 'publishing %s: %s\n' "$client" "$command"
    (cd "$ROOT_DIR" && sh -eu -c "$command")
  else
    printf '[dry-run] %s: %s\n' "$client" "$command"
  fi
}

case "$client" in
  nodejs)
    run_root 'node scripts/render-client.mjs nodejs dist/nodejs && cd dist/nodejs && npm pack --dry-run && npm publish --access public'
    ;;
  bun)
    run_root 'node scripts/render-client.mjs bun dist/bun && cd dist/bun && npm pack --dry-run && npm publish --access public'
    ;;
  deno)
    run_root 'node scripts/render-client.mjs deno dist/deno && cd dist/deno && deno publish --dry-run && deno publish'
    ;;
  python)
    run '${PYTHON:-python3} -m build && twine check dist/* && twine upload dist/*'
    ;;
  java)
    run 'mvn -P release deploy'
    ;;
  kotlin|groovy)
    run 'gradle -Prelease publish && ../../scripts/publish-central-ossrh-compat.sh "${CENTRAL_NAMESPACE:?set CENTRAL_NAMESPACE}"'
    ;;
  scala)
    run 'sbt publishSigned sonatypeBundleRelease'
    ;;
  clojure)
    run 'clojure -T:build deploy && ../../scripts/publish-central-ossrh-compat.sh "${CENTRAL_NAMESPACE:?set CENTRAL_NAMESPACE}"'
    ;;
  rust)
    run 'cargo package && cargo publish'
    ;;
  golang)
    run_root 'git status --short && git tag "clients/golang/v${PACKAGE_VERSION:?set PACKAGE_VERSION}" && git push origin "clients/golang/v${PACKAGE_VERSION}"'
    ;;
  swift)
    run_root 'git status --short && git tag "${PACKAGE_VERSION:?set PACKAGE_VERSION}" && git push origin "${PACKAGE_VERSION}"'
    ;;
  oreslang)
    run_root 'git status --short && git tag "clients/oreslang/v${PACKAGE_VERSION:?set PACKAGE_VERSION}" && git push origin "clients/oreslang/v${PACKAGE_VERSION}"'
    ;;
  c)
    run_root 'git status --short && git tag "v${PACKAGE_VERSION:?set PACKAGE_VERSION}" && git push origin "v${PACKAGE_VERSION}" && FLAGS2ENV_VERSION="${PACKAGE_VERSION}" scripts/publish-homebrew.sh --release'
    ;;
  bash|zsh)
    run_root 'FLAGS2ENV_VERSION="${PACKAGE_VERSION:?set PACKAGE_VERSION}" scripts/publish-homebrew.sh --release'
    ;;
  cpp|fortran|zig|crystal)
    run 'git status --short && git tag "v${PACKAGE_VERSION:?set PACKAGE_VERSION}" && git push origin "v${PACKAGE_VERSION}"'
    ;;
  solidity)
    run 'npm pack --dry-run && npm publish --access public'
    ;;
  csharp|fsharp)
    run 'dotnet pack -c Release && dotnet nuget push bin/Release/*.nupkg --source https://api.nuget.org/v3/index.json'
    ;;
  php)
    run 'composer validate --strict && composer archive'
    ;;
  ruby)
    run 'gem build flags2env.gemspec && gem push flags2env-*.gem'
    ;;
  dart)
    run 'dart pub publish --dry-run && dart pub publish'
    ;;
  elixir)
    run 'mix hex.build && mix hex.publish'
    ;;
  erlang)
    run 'rebar3 hex build && rebar3 hex publish'
    ;;
  gleam)
    run 'gleam publish --yes'
    ;;
  haskell)
    run 'cabal check && cabal sdist && cabal upload dist-newstyle/sdist/*.tar.gz'
    ;;
  ocaml)
    run 'opam lint flags2env.opam && opam publish prepare && opam publish submit'
    ;;
  reasonml)
    run 'opam lint flags2env-reason.opam && opam publish prepare && opam publish submit'
    ;;
  perl)
    run 'perl Makefile.PL && make manifest && make dist && cpan-upload *.tar.gz'
    ;;
  lua)
    run 'luarocks lint flags2env-0.1.0-1.rockspec && luarocks upload flags2env-0.1.0-1.rockspec'
    ;;
  nim)
    run 'nimble check && nimble publish'
    ;;
  r)
    run_root 'rm -rf dist/r && mkdir -p dist/r && cp -R clients/r/. dist/r/ && cd dist && R CMD build r && R CMD check flags2env_*.tar.gz && pkg="$(ls flags2env_*.tar.gz | tail -1)" && Rscript -e "if (!requireNamespace('\''devtools'\'', quietly = TRUE)) stop('\''install devtools to submit to CRAN'\''); devtools::submit_cran(commandArgs(TRUE)[1])" "$pkg"'
    ;;
  matlab)
    run 'zip -r flags2env-matlab.zip +flags2env native README.md LICENSE'
    ;;
  julia)
    run_root 'julia --project=clients/julia -e "using Pkg; Pkg.instantiate(); Pkg.test()" && printf "%s\n" "@JuliaRegistrator register subdir=clients/julia"'
    ;;
  *)
    printf 'no publish command configured for client: %s\n' "$client" >&2
    exit 2
    ;;
esac
