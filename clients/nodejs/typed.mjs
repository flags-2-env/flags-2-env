import {
  coerce,
  parse,
  parseProcess,
  parseStructured,
} from "./lib.mjs";

function attachHelpMetadata(target, source) {
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
  return target;
}

function projectTyped(values, options) {
  // Preserve parse-derived/meta keys as-is while replacing every declared
  // .cli-flags.toml env key with its schema-coerced value.
  return Object.assign({ ...values }, coerce(values, options));
}

/**
 * Parse argv and return an application-config snapshot whose declared keys are
 * coerced according to .cli-flags.toml. Existing parse() intentionally remains
 * the raw/string env-map API for process.env compatibility.
 */
export function parseTyped(argv = process.argv, options = {}) {
  const raw = parse(argv, options);
  return attachHelpMetadata(projectTyped(raw, options), raw);
}

/** Parse the current process argv and coerce declared config keys. */
export function parseProcessTyped(options = {}) {
  const raw = parseProcess(options);
  return attachHelpMetadata(projectTyped(raw, options), raw);
}

/**
 * Structured parse with each string-valued configuration channel projected
 * through the same .cli-flags.toml coercion contract. Diagnostic arrays,
 * command metadata, and source ordering remain unchanged.
 */
export function parseStructuredTyped(argv = process.argv, options = {}) {
  const raw = parseStructured(argv, options);
  return attachHelpMetadata(
    {
      ...raw,
      flags: projectTyped(raw.flags, options),
      providedFlags: projectTyped(raw.providedFlags, options),
      dotenv: projectTyped(raw.dotenv, options),
      dotenvOverrides: projectTyped(raw.dotenvOverrides, options),
    },
    raw,
  );
}

export default {
  parseTyped,
  parseProcessTyped,
  parseStructuredTyped,
};
