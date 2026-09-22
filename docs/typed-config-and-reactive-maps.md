# Typed config and `ores-reactive-maps`

`flags-2-env` has two distinct jobs at the application boundary:

1. resolve textual configuration sources (`argv`, live environment, dotenv, defaults) according to `.cli-flags.toml` precedence;
2. project declared keys into application values according to the schema in `.cli-flags.toml`.

Those jobs should stay distinct internally even when an SDK exposes a convenience API that performs both.

## Raw strings first, typed application values second

Operating-system environment variables and CLI tokens are strings. The raw `parse()` API therefore remains string-valued and safe to merge into `process.env`.

Application code that wants values should use `@oresoftware/f2e/typed`:

```ts
import { parseTyped } from "@oresoftware/f2e/typed";
import type { CliConfig } from "./generated/cli-config.js";

const config = parseTyped<CliConfig>();
```

`parseTyped()` resolves sources first and then runs the native `coerce()` contract over the result. Parse-derived metadata that is not a declared config key is preserved unchanged.

Use generated types to make keys and values exact at compile time:

```sh
flags2env generate-types typescript > generated/cli-config.ts
```

## Dynamic discovery, static typing

Finding `.cli-flags.toml` may remain dynamic. The fleet-standard locator is `ores-config-discovery`: starting from the working directory, find the nearest matching config without crossing the repository boundary.

Compile-time typing is different: a compiler cannot derive a stable type from whichever config file might be discovered later at runtime. The generated type therefore needs a **hard, static import target**.

Recommended flow:

```text
build / sync
  -> ores-config-discovery locates one concrete .cli-flags.toml
  -> flags2env parses + normalizes that file
  -> generated/cli-config.ts (or .rs/.dart/.go/...) is emitted
  -> application source statically imports generated/cli-config

runtime
  -> flags2env dynamically locates .cli-flags.toml again
  -> parser resolves argv/env/dotenv/defaults
  -> runtime config fingerprint is compared with generated fingerprint
  -> values are coerced using that schema
```

For TypeScript the consumer should look like:

```ts
import type { CliConfig } from "./generated/cli-config.js";
import { parseTyped } from "@oresoftware/f2e/typed";

const config: CliConfig = parseTyped<CliConfig>();
```

The generated artifact should contain a stable schema/config fingerprint alongside the type declaration. `parseTyped` (or a stricter `parseTypedChecked`) can compare that fingerprint to the runtime-discovered config and fail closed when a nested `.cli-flags.toml` or changed file no longer matches the type compiled into the application.

This is especially important because nearest-wins discovery intentionally permits a nested config to override the repository-root config. Dynamic lookup remains useful, but it must not silently invalidate a statically generated type.

`ores-config-discovery` is currently a Rust crate while the authoritative flags2env parser is C. Do not add C-to-Rust FFI solely for directory walking. Near term:

- use `ores-config-discovery` directly in Rust/build/codegen entrypoints;
- keep C runtime discovery behavior aligned through shared conformance fixtures;
- move to one direct implementation when the parser/runtime boundary can consume the Rust locator without adding an otherwise unnecessary FFI layer.

## Value model

The existing native schema supports:

- `string`
- `bool` / `boolean`
- `int` / `integer`
- `float` / numeric values
- `json`
- `array` / `list` / `json-array`
- `map` / `object` / `dictionary` / `json-object`

`array` values are JSON arrays at the textual boundary, so nested arrays already round-trip at runtime, for example `[[1,2],[3,4]]`. The current schema does **not** constrain an array's element type, so generated language types correctly use an unknown/any element type today.

The next schema hardening step is recursive element typing. The preferred authoring grammar is:

```toml
[flags.ports]
env = "PORTS"
type = "array<int>"

[flags.features]
env = "FEATURES"
type = "array<bool>"

[flags.names]
env = "NAMES"
type = "array<string>"

[flags.matrix]
env = "MATRIX"
type = "array<array<int>>"
```

Aliases such as `int[]`, `bool[]`, `string[]`, and `int[][]` can be accepted as input sugar, but a single canonical recursive representation should be used internally.

The native parser should normalize TOML into a schema JSON IR and drive **both** runtime coercion and every language generator from that IR. For example:

```json
{
  "PORTS": { "type": "array", "items": { "type": "integer" } },
  "MATRIX": {
    "type": "array",
    "items": { "type": "array", "items": { "type": "integer" } }
  }
}
```

That avoids implementing a second TOML parser in each SDK and gives JSON Schema generation the same recursive information used by runtime coercion.

## Relationship to `ores-reactive-maps`

`ores-reactive-maps` should remain source/schema agnostic. Its layers represent the raw values supplied by env, flags, Redis, files, tests, or a control plane. `flags-2-env` owns `.cli-flags.toml`, so it owns coercion.

The correct ordering is therefore:

```text
raw string layers
  -> reactive precedence resolution
  -> resolved string snapshot
  -> flags2env schema coercion
  -> typed application config
```

Do **not** independently coerce every source before reactive precedence. That duplicates parsing policy across sources and can make two textual representations of the same value behave differently depending on which layer supplied them.

`@oresoftware/f2e/reactive` intentionally uses a structural `ReactiveStringMapLike` boundary rather than importing `@oresoftware/ores-reactive-maps` in the core package. This keeps the integration one-way without forcing all `flags-2-env` consumers to install the reactive package or inherit its Node engine floor.

```ts
import { ReactiveMap } from "@oresoftware/ores-reactive-maps";
import {
  installResolvedLayer,
  typedSnapshot,
} from "@oresoftware/f2e/reactive";
import type { CliConfig } from "./generated/cli-config.js";

const runtime = new ReactiveMap();
installResolvedLayer(runtime, process.argv);

const config = typedSnapshot<CliConfig>(runtime);
```

The reverse dependency remains prohibited: `ores-reactive-maps` must not import `flags-2-env`.

## Follow-up native work

The recursive typed-array work should add one normalized schema AST/JSON IR and use it for all of the following in one parity suite:

- strict argv/env/default coercion;
- TypeScript, Rust, Go, Dart, Python, Java, C#, and JSON Schema generation;
- recursive arrays, including nested arrays;
- integer validation (full token, range/safe range appropriate to target contract);
- finite floating-point validation;
- boolean alias normalization;
- exact object/array JSON validation;
- generated config/schema fingerprinting and runtime verification;
- discovery conformance against `ores-config-discovery`;
- fixtures proving the same input either succeeds with the same semantic value or fails in every client.
