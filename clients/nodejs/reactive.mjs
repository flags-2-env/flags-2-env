import { coerce, parse } from "./lib.mjs";

function assertReactiveMap(map) {
  if (!map || typeof map.replaceLayer !== "function" || typeof map.getAllEntries !== "function") {
    throw new TypeError("reactive map must expose replaceLayer() and getAllEntries()");
  }
}

/**
 * Install the fully resolved flags2env snapshot as one string-valued layer.
 *
 * This intentionally uses structural typing instead of importing
 * @oresoftware/ores-reactive-maps. The reactive-map package has a newer Node
 * engine floor and is independently publishable; keeping it optional avoids
 * making every flags2env consumer install it. Pass a ReactiveMap instance from
 * that package when reactive runtime state is desired.
 */
export function installResolvedLayer(map, argv = process.argv, options = {}) {
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

/**
 * Project the currently resolved reactive string map through the same
 * .cli-flags.toml coercion contract used by flags2env typed parsing.
 */
export function typedSnapshot(map, options = {}) {
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

export default {
  installResolvedLayer,
  typedSnapshot,
};
