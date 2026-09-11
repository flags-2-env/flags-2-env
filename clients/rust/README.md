# flags2env Rust

Rust bindings for flags2env. The crate includes package-local C parser sources
under `native/` so `cargo package` and downstream builds do not need the
monorepo root.

## Bundled runtime — recommended for CLIs and servers

`BundledFlags2Env` compiles the C parser into the Rust artifact. The resulting
binary is self-contained and does not need `libflags2env.so`,
`libflags2env.dylib`, or `flags2env.dll` in the runtime image.

Prefer an immutable resolved map over mutating the process environment. Also
read process argv through `args_os()` and convert explicitly: `std::env::args()`
panics when the operating system supplies a non-Unicode argument.

```rust
use flags2env::BundledFlags2Env;
use std::collections::HashMap;

fn utf8_argv() -> Result<Vec<String>, Box<dyn std::error::Error>> {
    std::env::args_os()
        .map(|value| {
            value
                .into_string()
                .map_err(|_| "command-line arguments must be valid UTF-8".into())
        })
        .collect()
}

fn resolved_flags() -> Result<HashMap<String, String>, Box<dyn std::error::Error>> {
    let parser = BundledFlags2Env::new();
    parser.audit_config(Some(".cli-flags.toml"))?;
    let argv = utf8_argv()?;
    let parsed = parser.parse_structured(&argv, Some(".cli-flags.toml"))?;
    if !parsed.unknown_options.is_empty() || !parsed.errors.is_empty() {
        return Err(format!(
            "invalid CLI arguments: unknown={:?}, errors={:?}",
            parsed.unknown_options, parsed.errors
        )
        .into());
    }
    Ok(parsed.provided_flags)
}
```

### Help and completions

The bundled client delegates user-facing CLI behavior to the same native
`.cli-flags.toml` authority instead of requiring each Rust binary to add a
second parser just for `--help` or completion generation.

```rust
let parser = flags2env::BundledFlags2Env::new();
let argv = utf8_argv()?;

if parser.is_help_requested(&argv)? {
    let table = parser.help_table_for_argv(
        "my-cli",
        &argv,
        0, // native terminal-width auto-detection
        Some(".cli-flags.toml"),
    )?;
    print!("{table}");
    return Ok(());
}

let bash = parser.completion_script("bash", "my-cli", Some(".cli-flags.toml"))?;
std::fs::write("my-cli.bash", bash)?;
```

Help rendering is command-scope aware (`my-cli remote add --help`), and static
completion scripts are generated from the same command/flag authority used at
runtime.

## Typed coercion and generated interfaces

Generate the Rust shape from the same schema used at runtime:

```sh
f2e generate rust .cli-flags.toml --name CliConfig > src/cli_config.rs
```

The generated module derives `serde::Serialize` and `serde::Deserialize`, so
the application must include `serde` with its `derive` feature. Then merge the
process environment and argv-only overrides and cross the typed boundary once.
Use `vars_os()` for the same reason as `args_os()`: the Unicode-only iterator
can panic on operating-system values that are not valid UTF-8.

```rust
mod cli_config;

use cli_config::CliConfig;
use flags2env::BundledFlags2Env;
use std::collections::HashMap;

fn utf8_environment() -> Result<HashMap<String, String>, Box<dyn std::error::Error>> {
    std::env::vars_os()
        .map(|(name, value)| {
            let name = name
                .into_string()
                .map_err(|_| "environment variable names must be valid UTF-8")?;
            let value = value
                .into_string()
                .map_err(|_| "environment variable values must be valid UTF-8")?;
            Ok((name, value))
        })
        .collect()
}

fn load_config() -> Result<CliConfig, Box<dyn std::error::Error>> {
    let parser = BundledFlags2Env::new();
    let argv = utf8_argv()?;
    let parsed = parser.parse_structured(&argv, Some(".cli-flags.toml"))?;
    if !parsed.unknown_options.is_empty() || !parsed.errors.is_empty() {
        return Err("invalid CLI arguments".into());
    }

    let mut values = utf8_environment()?;
    values.extend(parsed.provided_flags);
    Ok(parser.coerce(&values, Some(".cli-flags.toml"))?)
}
```

`coerce<T, V>()` accepts any serializable object and deserializes the validated
result into `T`. It keeps declared env keys, applies active defaults, and
converts the schema's integers, doubles, booleans, JSON values, arrays, and
maps. Invalid values return `CoercionError::Validation`; use
`validation_errors()` to inspect all conversion failures at once. A
`CoercionError::Deserialize` means the requested Rust type does not agree with
the generated schema. The same method is available on the dynamically loaded
`Flags2Env` client. Use `provided_flags`, not the default-bearing `flags`, when
merging over the live environment; this preserves the default precedence
`CLI > environment > schema default` unless `.cli-flags.toml` explicitly
reorders sources.

Secrets should remain environment-only and be listed under `[env].ignore` in
`.cli-flags.toml`; do not declare secret-bearing flags or defaults.

## Dynamic runtime

`Flags2Env::load(path)` remains available for applications that intentionally
load a separately installed shared library. These callers are responsible for
shipping the matching native library in every release artifact and runtime
image. Do not silently count a source dependency as complete integration if the
shared library is absent in production.
