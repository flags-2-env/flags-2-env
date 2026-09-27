# Flags2Env Gleam

Gleam bindings for the `flags2env` native parser.

The package exposes a Gleam facade over an Erlang native shim. The native shim
loads the same `flags2env` NIF used by the Erlang client.

For command-line admission, prefer the strict APIs:

- `audit_config_status_with_config/1` before accepting a reviewed contract;
- `parse_structured_json_with_config/2` for argv parsing when callers must
  reject unknown options, parse errors, or unexpected positional arguments.

The structured report is the native parser's JSON object containing
`providedFlags`, `command`, `subcommands`, `extras`,
`unknownOptions`, and `errors`. Applications can decode it with their
normal JSON library and fail closed before dispatch.
