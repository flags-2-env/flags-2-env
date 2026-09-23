import {
  coerce,
  parse,
  parseProcess,
  parseStructured,
  type EnvMap,
  type Flags2EnvOptions,
  type StructuredParseResult,
  type TableWriter,
} from "./lib.js";

export type TypedConfigShape = Readonly<Record<string, unknown>>;

export type TypedParseResult<T extends object = Record<string, unknown>> = T &
  Record<string, unknown> & {
    readonly isHelpMenu: boolean;
    printTable(target?: TableWriter): string;
  };

export type TypedStructuredParseResult<T extends object = Record<string, unknown>> = Omit<
  StructuredParseResult,
  "flags" | "providedFlags" | "dotenv" | "dotenvOverrides"
> & {
  flags: T & Record<string, unknown>;
  providedFlags: Partial<T> & Record<string, unknown>;
  dotenv: Partial<T> & Record<string, unknown>;
  dotenvOverrides: Partial<T> & Record<string, unknown>;
};

function attachHelpMetadata<T extends object>(
  target: T,
  source: { readonly isHelpMenu: boolean; printTable(target?: TableWriter): string },
): T & { readonly isHelpMenu: boolean; printTable(target?: TableWriter): string } {
  Object.defineProperties(target, {
    isHelpMenu: {
      enumerable: false,
      value: source.isHelpMenu,
    },
    printTable: {
      enumerable: false,
      value: source.printTable,
    },
  });
  return target as T & { readonly isHelpMenu: boolean; printTable(target?: TableWriter): string };
}

function projectTyped<T extends object>(values: EnvMap, options: Flags2EnvOptions): T & Record<string, unknown> {
  // Keep parse-derived/meta keys while replacing declared config keys with the
  // schema-coerced values returned by the native .cli-flags.toml contract.
  return Object.assign({ ...values } as Record<string, unknown>, coerce<T>(values, options)) as T &
    Record<string, unknown>;
}

/**
 * Parse argv and project declared .cli-flags.toml keys to runtime values.
 *
 * Pair this with generated types for exact key/value knowledge:
 *
 *   // flags2env generate-types typescript > generated/cli-config.ts
 *   const config = parseTyped<CliConfig>();
 *   config.PORT;       // number when PORT is declared int
 *   config.DEBUG;      // boolean when DEBUG is declared bool
 *
 * parse() remains the raw string EnvMap API so process.env-compatible callers
 * do not receive a silent breaking change.
 */
export function parseTyped<T extends object = Record<string, unknown>>(
  argv: readonly unknown[] = process.argv,
  options: Flags2EnvOptions = {},
): TypedParseResult<T> {
  const raw = parse(argv, options);
  return attachHelpMetadata(projectTyped<T>(raw, options), raw) as TypedParseResult<T>;
}

/** Parse process argv and project declared config keys to runtime values. */
export function parseProcessTyped<T extends object = Record<string, unknown>>(
  options: Flags2EnvOptions = {},
): TypedParseResult<T> {
  const raw = parseProcess(options);
  return attachHelpMetadata(projectTyped<T>(raw, options), raw) as TypedParseResult<T>;
}

/**
 * Structured parse with all four configuration channels schema-coerced while
 * command/diagnostic/source-order metadata remains unchanged.
 */
export function parseStructuredTyped<T extends object = Record<string, unknown>>(
  argv: readonly unknown[] = process.argv,
  options: Flags2EnvOptions = {},
): TypedStructuredParseResult<T> {
  const raw = parseStructured(argv, options);
  return attachHelpMetadata(
    {
      ...raw,
      flags: projectTyped<T>(raw.flags, options),
      providedFlags: projectTyped<Partial<T>>(raw.providedFlags, options),
      dotenv: projectTyped<Partial<T>>(raw.dotenv, options),
      dotenvOverrides: projectTyped<Partial<T>>(raw.dotenvOverrides, options),
    },
    raw,
  ) as TypedStructuredParseResult<T>;
}

export default {
  parseTyped,
  parseProcessTyped,
  parseStructuredTyped,
};
