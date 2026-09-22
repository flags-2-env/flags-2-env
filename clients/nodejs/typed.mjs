import { coerce, parse, parseProcess, parseStructured } from "./lib.mjs";

function copyHelpMetadata(value, source) {
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
  return value;
}

export function parseTyped(argv = process.argv, options = {}) {
  const raw = parse(argv, options);
  return copyHelpMetadata(coerce(raw, options), raw);
}

export function parseProcessTyped(options = {}) {
  const raw = parseProcess(options);
  return copyHelpMetadata(coerce(raw, options), raw);
}

export function parseStructuredTyped(argv = process.argv, options = {}) {
  const raw = parseStructured(argv, options);
  const value = {
    ...raw,
    flags: coerce(raw.flags, options),
  };
  return copyHelpMetadata(value, raw);
}

export default {
  parseTyped,
  parseProcessTyped,
  parseStructuredTyped,
};
