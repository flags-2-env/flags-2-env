"use strict";

const { coerce, parse } = require("./lib.cjs");

function assertReactiveMap(map) {
  if (!map || typeof map.replaceLayer !== "function" || typeof map.getAllEntries !== "function") {
    throw new TypeError("reactive map must expose replaceLayer() and getAllEntries()");
  }
}

function installResolvedLayer(map, argv = process.argv, options = {}) {
  assertReactiveMap(map);
  const {
    layerName = "flags2env",
    source = "flags2env",
    priority = 200,
    ...flagsOptions
  } = options;
  const raw = parse(argv, flagsOptions);
  map.replaceLayer(String(layerName), String(source), Number(priority), raw);
  return map;
}

function typedSnapshot(map, options = {}) {
  assertReactiveMap(map);
  const entries = map.getAllEntries();
  const raw = Object.create(null);
  for (const [key, entry] of Object.entries(entries)) {
    if (!entry || typeof entry.value !== "string") {
      throw new TypeError(`reactive entry ${key} must contain a string value before flags2env coercion`);
    }
    raw[key] = entry.value;
  }
  return Object.assign({ ...raw }, coerce(raw, options));
}

module.exports = {
  installResolvedLayer,
  typedSnapshot,
  default: {
    installResolvedLayer,
    typedSnapshot,
  },
};
