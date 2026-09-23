"use strict";

const {
  coerce,
  parse,
  parseProcess,
  parseStructured,
} = require("./lib.cjs");

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
  return Object.assign({ ...values }, coerce(values, options));
}

function parseTyped(argv = process.argv, options = {}) {
  const raw = parse(argv, options);
  return attachHelpMetadata(projectTyped(raw, options), raw);
}

function parseProcessTyped(options = {}) {
  const raw = parseProcess(options);
  return attachHelpMetadata(projectTyped(raw, options), raw);
}

function parseStructuredTyped(argv = process.argv, options = {}) {
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

module.exports = {
  parseTyped,
  parseProcessTyped,
  parseStructuredTyped,
  default: {
    parseTyped,
    parseProcessTyped,
    parseStructuredTyped,
  },
};
