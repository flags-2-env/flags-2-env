# flags-2-env nested command scope visibility

Run `node formal/attolang/model_check.mjs`. The bounded state enumeration checks positive/negative witnesses and includes a deliberately broken guard as a mutation negative control.

`flag_policy.atto` is a source-only AttoLang oracle (draft `.atto` syntax); CI does NOT compile or execute this source or drive the production implementation.

This enumerates four command scopes and four declaration scopes, checking that global flags are visible and command-scoped flags cannot leak into siblings. It does not prove real argv parsing, aliases, allow_unknown overrides, TOML validation, C memory safety or runtime language bindings. Existing CBMC/SMT/Kani/browser proofs remain independent.

To make stronger claims, add an exact-head production trace/refinement adapter and execute the `.atto` program on five real compiler backends (Java, LLVM, Wasm, Forge and .NET), with nonzero executed steps and reviewed receipts.
