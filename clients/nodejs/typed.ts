import { coerce, parse, parseProcess, parseStructured } from "./lib.js";
import type { Flags2EnvOptions, ParseResult, StructuredParseResult, TableWriter } from "./lib.js";

export type TypedConfigScalar = string | number | boolean | null;
export type TypedConfigValue =
  | TypedConfigScalar
  | TypedConfigValue[]
  | { readonly [key: string]: TypedConfigValue };

export type HelpMetadata = {
  readonly isHelpMenu: boolean;
  printTable(target?: TableWriter): string;
};

export type TypedParseResult<TConfig extends object> = TConfig & HelpMetadata;

export type StructuredTypedParseResult<TConfig extends object> = Omit<
  StructuredParseResult,
  "flags" | "isHelpMenu" | "printTable"
> & {
  flags: TConfig;
} & HelpMetadata;

function copyHelpMetadata<TConfig extends object>(
  value: TConfig,
  source: Pick<ParseResult, "isHelpMenu" | "printTable">,
): TypedParseResult<TConfig> {
  Object.defineProperties(value, {
    isHelpMenu: {
      enumerable: false,
      value: source.isHelpMenu,
    },
    printTable: {
      enumerable: false,
      value: source.printTable,
    },
  });
  return value as TypedParseResult<TConfig>;
}

/**
 * Parse argv through the normal string/env-compatible path, then coerce the
 * resolved values using the same `.cli-flags.toml` schema.
 *
 * For exact keys, generate the config interface at build time from an explicit
 * config path and pass it as `TConfig`. Runtime upward discovery can still be
 * used, but callers that need a compile-time guarantee should pass the same
 * explicit `configPath` used for generation.
 */
export function parseTyped<TConfig extends object = Record<string, unknown>>(
  argv: readonly unknown[] = process.argv,
  options: Flags2EnvOptions = {},
): TypedParseResult<TConfig> {
  const raw = parse(argv, options);
  return copyHelpMetadata(coerce<TConfig>(raw, options), raw);
}

export function parseProcessTyped<TConfig extends object = Record<string, unknown>>(
  options: Flags2EnvOptions = {},
): TypedParseResult<TConfig> {
  const raw = parseProcess(options);
  return copyHelpMetadata(coerce<TConfig>(raw, options), raw);
}

/**
 * Structured parsing keeps env-spread channels string-valued. Only `flags`,
 * the fully resolved application config, is coerced into `TConfig`.
 */
export function parseStructuredTyped<TConfig extends object = Record<string, unknown>>(
  argv: readonly unknown[] = process.argv,
  options: Flags2EnvOptions = {},
): StructuredTypedParseResult<TConfig> {
  const raw = parseStructured(argv, options);
  const value = {
    ...raw,
    flags: coerce<TConfig>(raw.flags, options),
  } as StructuredTypedParseResult<TConfig>;
  return copyHelpMetadata(value, raw) as StructuredTypedParseResult<TConfig>;
}

export default {
  parseTyped,
  parseProcessTyped,
  parseStructuredTyped,
};
