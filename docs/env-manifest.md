# Repository environment audit ownership

`flags-2-env` is intentionally scoped to the public CLI contract in
`.cli-flags.toml` and to environment files explicitly configured by that contract.
It does **not** crawl arbitrary repository TOML files, interpret domain configuration,
inspect `env/enc`, generate a repository-wide `manifest.env`, or maintain a shadow
inventory of domain environment declarations.

The canonical boundaries are:

- **flags-2-env**: audit and parse `.cli-flags.toml`; normalize argv into typed
environment-backed values; apply that contract's configured dotenv precedence; reject
unknown/invalid CLI input; provide help/completion/code-generation projections of the
same CLI contract.
- **ORESoftware/ores-cli**: repository/pre-deploy admission across the wider ORES TOML
family, including `.ores-otel.toml`, `.ores-rl.toml`, `.ores-lru.toml`,
`.auth-shared.toml`, `.opto-sync.toml`, `.fanwaave-cfg.toml`, other root domain TOMLs,
process environment coverage, encrypted `env/enc/*.env.enc` key-shape evidence, and
deterministic aggregate environment manifests.
- **ORESoftware/ores-interfaces**: the independent cross-runtime environment-manifest
contract under `contracts/env-manifest/v1/`, expressed as peer human-authored TypeSpec
and JSON Schema Draft 2020-12 authorities.
- **ORESoftware/typespec-json-schema-validator (TJSV)**: fail-closed parity/admission
between those independent TypeSpec and JSON Schema authorities and their runtime
consumer evidence.

The repository-wide `f2e env-manifest` experiment introduced in
`flags-2-env/flags-2-env#16` was useful for proving deterministic discovery and
profile/key reconciliation, but it placed repository/domain knowledge in the wrong
layer. Its useful behavior is preserved in the `ores-cli` environment-audit work
(`ORESoftware/ores-cli#55` and `#59`) rather than being discarded.

## Runtime rule

At application startup, use flags-2-env to validate/resolve the application's
`.cli-flags.toml` argv boundary. Use `ores-cli`/`ores-entrypoint` as the broader
preflight when the application also depends on domain TOMLs or encrypted environment
files. A required domain environment key must be admitted by the repository contract
and populated by the live process after the deployment secret/env-file layer has been
applied; merely having a key name in ciphertext is not equivalent to a populated
runtime value.

`f2e audit env` remains valid for checking one dotenv input against
`.cli-flags.toml`. It is deliberately not a replacement for `oresc audit env`.
