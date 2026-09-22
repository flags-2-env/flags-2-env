import "@typespec/json-schema";
using TypeSpec.JsonSchema;

namespace Flags2Env.Config;

// Code-generation metadata, not runtime configuration. `f2e generate` reads
// `service` and `type_name` to name the emitted env type and the SERVICE
// constant; the runtime parser recognizes the table, checks its keys, and
// otherwise ignores it.
@id("IdentityConfig")
model IdentityConfig {
  service?: string;
  type_name?: string;
}

@id("HelpConfig")
model HelpConfig {
  url?: string;
  columns?: string[];
  exclude?: string[];
}

@id("EnvConfig")
model EnvConfig {
  files?: string[];
  load?: boolean;
  ignore?: string[];
}

@id("ParseConfig")
model ParseConfig {
  require_equals?: boolean;
  stop_at_first_positional?: boolean;
  positionals_env?: string;
  unknown_options_env?: string;
  errors_env?: string;
  command_env?: string;
  allow_unknown?: boolean;
  allow_hidden?: boolean;
}

@id("FlagSpec")
model FlagSpec {
  env?: string;
  argv?: boolean;
  aliases?: string[];
  short?: string;
  type?: string;
  default?: unknown;
  help?: string;
  description?: string;
  true_aliases?: string[];
  false_aliases?: string[];

  // The native audit owns the finite requires_tty spelling set. The peer
  // shape authorities only require this member to remain a JSON value.
  requires_tty?: unknown;
}

// Name the two map shapes explicitly instead of relying on anonymous
// Record<T> emission. This keeps TypeSpec and authored Schema A structurally
// comparable while preserving the same open-key map semantics.
@id("FlagMap")
model FlagMap is Record<FlagSpec> {}

@id("CommandMap")
model CommandMap is Record<CommandSpec> {}

@id("CommandSpec")
model CommandSpec {
  help?: string;
  description?: string;
  aliases?: string[];
  env?: string;
  allow_unknown?: boolean;
  allow_hidden?: boolean;
  flags?: FlagMap;
  commands?: CommandMap;
  command?: CommandMap;
  subcommands?: CommandMap;
  subcommand?: CommandMap;
}

@id("GlobalConfig")
model GlobalConfig {
  flags?: FlagMap;
}

@id("CliFlagsConfig")
model CliFlagsConfig {
  identity?: IdentityConfig;
  help?: HelpConfig;
  env?: EnvConfig;
  parse?: ParseConfig;
  flags?: FlagMap;
  global?: GlobalConfig;
  commands?: CommandMap;
  command?: CommandMap;
  subcommands?: CommandMap;
  subcommand?: CommandMap;
}
