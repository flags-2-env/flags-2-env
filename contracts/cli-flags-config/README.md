# `.cli-flags.toml` peer authorities

The shape of `.cli-flags.toml` has two independent, human-authored authorities:

- `main.tsp` — TypeSpec authority;
- `authored.schema.json` — JSON Schema Draft 2020-12 authority.

Neither file is generated from the other. `ORESoftware/typespec-json-schema-validator` (`tjsv`) may generate Schema B from TypeSpec as comparison evidence only and must fail closed when the two authored authorities drift.

`instances/CliFlagsConfig/{valid,invalid}` is shared behavioral evidence for both lanes.

## What belongs here

These contracts own structural shape: root tables, nested command/flag maps, scalar/container types, and accepted aliases for the `commands` table shape.

They intentionally do **not** replace `flags2env audit`. Cross-entry semantics such as duplicate aliases/short flags, env-name collisions, command-scope collisions, `--no-*` namespace conflicts, terminal policy spellings, default/type compatibility, and safe `.env` path rules remain native flags2env responsibilities.

## Build admission

CI should run both:

```sh
flags2env audit .cli-flags.toml

tjsv check \
  --typespec contracts/cli-flags-config/main.tsp \
  --schema contracts/cli-flags-config/authored.schema.json \
  --instances contracts/cli-flags-config/instances
```

The first command proves parser-specific semantics. The second proves TypeSpec/JSON-Schema parity and executes the shared instance corpus.

## Runtime observation

Runtime consumers should parse TOML with the same native parser used by the application, convert the parsed value to its JSON-equivalent object, and evaluate that object against `authored.schema.json` using TJSV's config-instance evaluator.

Runtime schema drift is diagnostic only: emit/log a warning and continue. Existing parse errors or application invariants remain unchanged and may still be fatal when the application cannot safely operate.

Do not write parsed configuration containing secrets to a temporary JSON file. Prefer the evaluator's stdin/API surface.
