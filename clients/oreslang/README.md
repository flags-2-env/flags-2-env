# flags2env — Oreslang client (native bridge, experimental)

This directory contains the Oreslang client source contract and an ABI-stable host adapter. The client is implemented, but **release support remains evidence-gated** until the backend PRs execute the same pinned fixture and the full String/Fnc host path is demonstrated where each backend claims it.

## Contract

- `f2e_ores_parse(config, argv_json)`: parse explicit argv JSON against a
  reviewed, absolute `.cli-flags.toml` path; return a UTF-8 JSON map.
- `f2e_ores_coerce(config, values_json)`: invoke the native typed-coercion
  boundary; return its JSON report, not a guessed map.
- Both return `f2e_ores_result { data, length, status }`. Statuses are 0 `ok`,
  1 `invalid_input`, 2 `native_failure`, 3 `input_too_large`,
  4 `output_too_large`, and 5 `released`. A null pointer is never silently
  interpreted as an empty configuration.
- The caller must copy result bytes into actor-owned memory **before**
  `f2e_ores_free`. Free exactly once; the function clears the result.
- No environment mutation occurs in the bridge. A higher-level Oreslang
  adapter should return a typed Result, and any application of parsed values
  must be explicit at startup, never implicit in an actor handler.
- Use `rt borrow` for input views and `rt take` for owned result copies;
  do not expose raw C pointers or pointer syntax in public Oreslang APIs.
- `host_parse_blocking_with` and `host_coerce_blocking_with` are explicitly
  host-blocking-only embedding primitives. The embedding runtime must move the
  entire call to an admitted blocking worker; actor carriers and ordinary guest
  code must not invoke them directly. The default release API remains gated on
  an explicit `suspends`/Future host boundary.

## Building

Compile `native/flags2env_ores_bridge.c` with package-local
`native/parser.c` and include `native/parser.h`. CI requires those vendored
parser bytes to match the repository's canonical `src/parser.c` and
`src/parser.h`, so the package is self-contained without semantic drift.

## Required release gates

1. Bind this ABI in Oreslang Java/Graal, LLVM, WASM, Cranelift and .NET host
   runtimes; WASM must use an explicit host import rather than assuming C FFI.
   Cranelift currently proves only the shared checked-i64 status slice and
   remains a full-client capability gap.
2. Test exact JSON bytes and typed coercion against the existing C fixtures.
3. Reject relative config paths, null inputs, malformed argv JSON, unknown
   flags and schema errors. Establish a race-safe trusted-config admission
   policy before claiming symlink/untrusted-path protection; path-string checks
   alone are not sufficient.
4. Verify byte ownership, double-free safety, bounded input/output, timeout,
   cancellation, and cross-tenant isolation.
5. Compile and execute identical native `.ores` guest fixtures on each
   backend. Unsupported backends are not passes.
6. Require exact-head stepful CI, compiler hashes, guest receipts and review.

Do not publish or advertise supported status until these gates pass.
