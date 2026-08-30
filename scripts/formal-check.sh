#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mode=${1:-all}
readonly proof_timeout=600
readonly solver_kill_grace=10

require_timeout() {
  command -v timeout >/dev/null || {
    echo "GNU timeout is required; run this command through nix develop" >&2
    return 1
  }
}

run_manifest() {
  command -v jq >/dev/null || {
    echo "jq is required; run this command through nix develop" >&2
    return 1
  }

  local manifest="$repo_root/formal/fmctl.json"
  echo "==> Manifest: ${manifest#"$repo_root/"}"
  jq --exit-status '
    type == "object"
    and ((keys | sort) == ([
      "gitRef",
      "heuristics",
      "languages",
      "paths",
      "repoUrl",
      "schemaVersion"
    ] | sort))
    and .schemaVersion == "formal-methods.v1"
    and .repoUrl == "https://github.com/flags-2-env/flags-2-env.git"
    and (.gitRef | type == "string"
      and test("^[A-Za-z0-9][A-Za-z0-9._/-]{0,179}$")
      and contains("..") == false
      and startswith("-") == false)
    and (.paths | type == "array"
      and length > 0
      and length <= 64
      and length == (unique | length)
      and all(
        type == "string"
        and length > 0
        and length <= 240
        and startswith("/") == false
        and contains("\\") == false
        and (split("/") | all(. != "." and . != ".."))
      ))
    and (.languages | type == "array"
      and length == 4
      and (sort == ["c", "h", "mjs", "rs"]))
    and (.heuristics | type == "boolean")
  ' "$manifest" >/dev/null

  local declared_path resolved_path
  while IFS= read -r declared_path; do
    resolved_path=$(realpath "$repo_root/$declared_path") || {
      echo "manifest path does not exist: $declared_path" >&2
      return 1
    }
    case "$resolved_path/" in
      "$repo_root"/*) ;;
      *)
        echo "manifest path escapes the repository: $declared_path" >&2
        return 1
        ;;
    esac
  done < <(jq -r '.paths[]' "$manifest")
}

run_cbmc() {
  command -v cbmc >/dev/null || {
    echo "cbmc is required; run this command through nix develop" >&2
    return 1
  }
  require_timeout

  local harness="$repo_root/formal/cbmc/parser_harness.c"
  local proof
  for proof in \
    harness_size_bounds \
    harness_strlcpy \
    harness_option_shape \
    harness_coercion_slot_bounds; do
    echo "==> CBMC: $proof"
    timeout \
      --signal=TERM \
      --kill-after="${solver_kill_grace}s" \
      "${proof_timeout}s" \
      cbmc "$harness" \
      --function "$proof" \
      --drop-unused-functions \
      --reachability-slice-fb \
      --bounds-check \
      --pointer-check \
      --pointer-overflow-check \
      --signed-overflow-check \
      --unsigned-overflow-check \
      --conversion-check \
      --div-by-zero-check \
      --unwind 10 \
      --unwinding-assertions \
      --trace \
      --verbosity 3
  done

  # terminal_context proofs run without --conversion-check: the scanner's
  # (unsigned char) casts feeding tolower are the C-mandated idiom for
  # high-bit bytes, and that defined, deliberate value-changing conversion
  # is exactly what --conversion-check lints against. Every segfault-class
  # check (bounds, pointer, overflow, unwinding) stays on.
  local terminal_harness="$repo_root/formal/cbmc/terminal_context_harness.c"
  for proof in \
    harness_ascii_equal_ci \
    harness_ascii_contains_ci \
    harness_path_basename \
    harness_value_truthy \
    harness_parse_columns; do
    echo "==> CBMC: $proof"
    timeout \
      --signal=TERM \
      --kill-after="${solver_kill_grace}s" \
      "${proof_timeout}s" \
      cbmc "$terminal_harness" \
      --function "$proof" \
      --drop-unused-functions \
      --reachability-slice-fb \
      --bounds-check \
      --pointer-check \
      --pointer-overflow-check \
      --signed-overflow-check \
      --unsigned-overflow-check \
      --div-by-zero-check \
      --unwind 10 \
      --unwinding-assertions \
      --trace \
      --verbosity 3
  done
}

run_application_lifecycle() {
  command -v node >/dev/null || {
    echo "node is required; run this command through nix develop" >&2
    return 1
  }

  echo "==> Application surface inventory"
  node "$repo_root/formal/check-application-scope.mjs"
  echo "==> Executable application lifecycle model"
  node "$repo_root/formal/model-check-app-lifecycle.mjs"
}

run_z3() {
  command -v z3 >/dev/null || {
    echo "z3 is required; run this command through nix develop" >&2
    return 1
  }
  require_timeout

  local inventory="$repo_root/formal/smt/obligations.json"
  jq --exit-status '
    type == "object"
    and ((keys | sort) == (["schemaVersion", "specifications"] | sort))
    and .schemaVersion == "flags2env.smt-obligations.v1"
    and (.specifications | type == "array"
      and length > 0
      and length <= 64
      and (map(.path) | length == (unique | length))
      and all(
        type == "object"
        and ((keys | sort) == (["checkSatCount", "path"] | sort))
        and (.path | type == "string"
          and test("^formal/smt/[A-Za-z0-9][A-Za-z0-9._-]*\\.smt2$"))
        and (.checkSatCount | type == "number"
          and floor == .
          and . > 0
          and . <= 256)
      ))
  ' "$inventory" >/dev/null

  local -a specs=()
  local spec relative output line checks size expected_checks actual_checks
  while IFS= read -r -d '' spec; do
    specs+=("$spec")
  done < <(find "$repo_root/formal/smt" -type f -name '*.smt2' -print0 | sort -z)
  local declared_count
  declared_count=$(jq '.specifications | length' "$inventory")
  if (( ${#specs[@]} != declared_count )); then
    echo "SMT inventory declares $declared_count specifications, found ${#specs[@]}" >&2
    return 1
  fi
  for spec in "${specs[@]}"; do
    relative=${spec#"$repo_root/"}
    expected_checks=$(
      jq --exit-status --arg path "$relative" '
        [.specifications[] | select(.path == $path) | .checkSatCount]
        | if length == 1 then .[0] else error("undeclared or duplicate SMT path") end
      ' "$inventory"
    ) || {
      echo "SMT specification is not declared exactly once: $relative" >&2
      return 1
    }
    actual_checks=$(awk '/^[[:space:]]*\(check-sat\)[[:space:]]*$/ { count += 1 } END { print count + 0 }' "$spec")
    if (( actual_checks != expected_checks )); then
      echo "SMT obligation count changed for $relative: expected $expected_checks, found $actual_checks" >&2
      return 1
    fi
    size=$(wc -c <"$spec")
    if (( size > 1048576 )); then
      echo "SMT specification exceeds 1 MiB: ${spec#"$repo_root/"}" >&2
      return 1
    fi
    echo "==> Z3: $relative ($expected_checks obligations)"
    output=$(
      timeout \
        --signal=TERM \
        --kill-after="${solver_kill_grace}s" \
        "${proof_timeout}s" \
        z3 -T:60 -smt2 "$spec"
    )
    checks=0
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      if [[ "$line" != "unsat" ]]; then
        echo "expected an unsat proof obligation, got: $line" >&2
        return 1
      fi
      checks=$((checks + 1))
    done <<<"$output"
    if (( checks != expected_checks )); then
      echo "Z3 returned $checks results for $relative; expected $expected_checks" >&2
      return 1
    fi
  done
}

case "$mode" in
  all)
    run_manifest
    run_application_lifecycle
    run_cbmc
    run_z3
    ;;
  app)
    run_application_lifecycle
    ;;
  manifest)
    run_manifest
    ;;
  cbmc)
    run_cbmc
    ;;
  z3)
    run_z3
    ;;
  *)
    echo "usage: $0 [all|app|manifest|cbmc|z3]" >&2
    exit 2
    ;;
esac
