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
- fixtures proving the same input either succeeds with the same semantic value or fails in every client.
