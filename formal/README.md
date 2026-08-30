# Formal verification

`flags-2-env` keeps its executable specifications beside the native and Rust
implementations:

- `../clients/browser/lifecycle.mjs` is the transition relation executed by
  every stateful browser application path: main-thread calls, worker-client
  startup/backpressure/drain/close, worker-host initialization, and demo
  startup. Runtime code does not keep parallel lifecycle booleans.
- `model-check-app-lifecycle.mjs` imports that exact runtime reducer and
  exhaustively explores every phase/event edge. It checks the full finite graph
  for worker bounds 1 through 4 and every state of the other three machines.
- `smt/application_lifecycle.smt2` independently proves the worker safety
  invariants for an arbitrary positive pending-request bound with Z3. It also
  proves the main-thread, worker-host, and demo transition obligations.
- `application-surfaces.json` is the application inventory, validated against
  `application-surfaces.schema.json`. `check-application-scope.mjs` rejects
  undeclared application and common desktop-framework paths, missing proof
  files, or entrypoints that do not execute the lifecycle reducer.
- `cbmc/parser_harness.c` model-checks bounded calls into the real C parser.
- `cbmc/terminal_context_harness.c` model-checks the terminal-context string
  scanners: case-insensitive comparison, basename slicing, truthiness, and
  the `[20, 10000]` column clamp, over nondeterministic inputs.
- `smt/parser_invariants.smt2` proves parser dispatch invariants with Z3.
- `smt/obligations.json` is the closed proof inventory. The runner requires an
  exact file set and an exact `check-sat` count for every specification, so a
  deleted theorem cannot silently turn a green run into a weaker claim.
- `smt/ownership_lattice.smt2` proves the custom borrow checker's ownership
  state machine sound: within bounded traces, no use-after-free or
  double-free can pass unflagged, the canonical allocate/check/use/free
  contract never flags, and branch merging never forgets a conditional
  free. The model mirrors `tools/borrow-checker/borrow_check.py`
  transition-for-transition; change them together. It proves the abstract
  machine **only** — AST collection, control-flow lowering, summary
  inference, nullability tracking, and waiver parsing are unproved and
  fixture-covered, as `tools/borrow-checker/README.md` sets out under
  "What is proved, and what is not".
- `../clients/rust/src/formal_model.rs` expresses the same dispatch rules in
  Rust and proves them with Kani.
- `fmctl.json` is the repository analysis manifest. It uses the
  `formal-methods.v1` request shape accepted by `dd-formal-methods-server`.

## Application lifecycle claim

The application machines are total and deterministic over their declared
events. They enforce these safety properties:

- new worker work is accepted only in `ready` and below the configured bound;
- `draining` never returns to `ready`, and `closed`/`failed` are absorbing;
- every terminal worker-client state has zero pending requests;
- accepted settlements strictly reduce pending work, so a responsive worker
  reaches graceful close after the finite accepted set drains;
- timeout, abort, worker failure, message failure, and explicit termination all
  reach a controlled terminal state and reject every accepted promise;
- late or unknown response IDs stutter because they no longer own a pending
  request slot;
- the worker host initializes at most once and never dispatches a method before
  successful initialization; and
- main-thread calls reject reentrancy without corrupting the outer call state.

This is a bounded, model-specific guarantee, not a claim that browsers,
operating systems, WebAssembly engines, memory, or user code can never fail.
The executable checker closes drift against the actual JavaScript reducer. The
Z3 model proves the abstract relation for any positive queue bound, while the
browser and fake-worker tests check side effects such as timers, promise
rejection, response IDs, and worker termination. A hung external worker is a
declared input and is forced to `failed` by the bounded close timeout.

There is currently no standalone Electron, Tauri, Flutter, SwiftUI, or native
desktop application in this repository. Separate Flutter and native-desktop
repositories now exist in the `flags-2-env` organization; their lifecycle
contracts and checks remain repository-local and are not covered by this
repository's proof claim. Adding an application here requires an
`application-surfaces.json` entry, a runtime machine, executable conformance
tests, and a proof path; the application-scope audit fails closed for common
desktop markers and any tracked `apps/` tree until that declaration exists.

Run just the application inventory and executable model:

```sh
./scripts/formal-check.sh app
```

Run the C and SMT proofs in the Nix development shell:

```sh
nix develop -c ./scripts/formal-check.sh
```

Run the Rust proofs with Kani:

```sh
cd clients/rust
cargo kani
```

The CBMC harness includes `src/parser.c` directly. This is intentional: it
allows the proof harness to reach file-local parser helpers without creating a
second implementation that could drift.

The `formal-methods.yml` GitHub workflow validates the manifests and runs the
application model, CBMC, Z3, and Kani proofs. Browser runtime changes trigger
both the formal workflow and the browser conformance workflows. It is
repository-local because the currently deployed webhook service is configured
for a different fixed Cargo manifest.

Until an independent `fmctl` schema or executable is published in the
organization, `fmctl.json` deliberately stays wire-compatible with the
deployed `formal-methods.v1` service rather than introducing a second,
unverifiable manifest format.
