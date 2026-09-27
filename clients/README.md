# Runtime Clients

Each runtime client binds to the same C ABI:

```c
char *f2e_parse_process_from_file(const char *config_path);
char *f2e_parse_json_argv_from_file(const char *config_path, const char *argv_json);
char *f2e_completion_script_from_file(const char *config_path, const char *shell, const char *command_name);
char *f2e_generate_types_from_file(const char *config_path, const char *language, const char *type_name);
char *f2e_coerce_json_from_file(const char *config_path, const char *values_json);
char *f2e_audit_env_file_from_file(const char *config_path, const char *env_path);
void f2e_free(char *value);
```

`f2e_parse_process_from_file` reads the current process argv through the host OS where available. `argv_json` is a JSON array of strings for callers that want to pass modified argv explicitly. Parse return values are JSON objects whose keys are environment variable names and whose values are strings. `f2e_coerce_json_from_file` is the explicit typed boundary and returns an `{ok,value}` or `{ok,errors}` report. Generated types, completion scripts, coercion reports, and audit reports are owned strings and must be released through `f2e_free`.

The publishing flow should render only the client for the target runtime, copy in the C source or prebuilt native artifact for that platform, and omit every other `clients/*` directory from the package.

The npm package exposes a Node-backed `f2e` / `flags2env` CLI bin that can generate typed config contracts, generate static bash/zsh completion scripts, install them into user shell locations, and audit `.env` files against `.cli-flags.toml`.

The Bash and Zsh clients are sourceable shell helpers. They call the native
`flags2env shell-env` command and evaluate shell-quoted exports so a function or
script can map its arguments into environment variables in the current shell.

BEAM clients use `clients/erlang/c_src/flags2env_nif.c` as the shared native implementation. Erlang and Elixir load it through the `flags2env` module; Gleam loads the same C implementation through `clients/gleam/src/flags2env_native.erl` so the public Gleam module can still be named `flags2env`. Java uses `clients/java/native/flags2env_jni.c` as a JNI bridge. Kotlin, Scala, Groovy, and Clojure reuse that Java bridge with small facade packages.

Additional native-runtime clients are scaffolded under:

```text
c
cpp
csharp
fsharp
fortran
haskell
julia
lua
matlab
nim
ocaml
perl
r
reasonml
zig
crystal
solidity
```

Solidity is intentionally an adapter, not an on-chain parser. EVM contracts
cannot load a C shared library, read TOML, or inspect process argv, so the
Solidity package verifies off-chain `flags2env` key/value commitments.

## Publishing

Run a client publish script from any client directory. Scripts default to
dry-run output; pass `--release` from CI after credentials are configured:

```sh
clients/nodejs/publish.sh
clients/python/publish.sh --release
clients/kotlin/publish.sh --dry-run
```

See `clients/PUBLISHING.md` for the registry mapping and manifest controls.
