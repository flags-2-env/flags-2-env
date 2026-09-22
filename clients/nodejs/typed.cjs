"use strict";

const { coerce, parse, parseProcess, parseStructured } = require("./lib.cjs");

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

function parseTyped(argv = process.argv, options = {}) {
  const raw = parse(argv, options);
  return copyHelpMetadata(coerce(raw, options), raw);
}

function parseProcessTyped(options = {}) {
  const raw = parseProcess(options);
  return copyHelpMetadata(coerce(raw, options), raw);
}

function parseStructuredTyped(argv = process.argv, options = {}) {
  const raw = parseStructured(argv, options);
  const value = {
    ...raw,
    flags: coerce(raw.flags, options),
  };
  return copyHelpMetadata(value, raw);
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
