import { coerce, parse, type Flags2EnvOptions } from "./lib.js";

export interface ReactiveResolvedEntryLike {
  value: string;
  source?: string;
  public?: boolean;
  layer?: string;
}

export interface ReactiveStringMapLike {
  replaceLayer(
    name: string,
    source: string,
    priority: number,
    values: Readonly<Record<string, string>>,
  ): void;
  getAllEntries(): Readonly<Record<string, ReactiveResolvedEntryLike>>;
}

export type ReactiveInstallOptions = Flags2EnvOptions & {
  layerName?: string;
  source?: string;
  priority?: number;
};

function assertReactiveMap(map: ReactiveStringMapLike): void {
  if (!map || typeof map.replaceLayer !== "function" || typeof map.getAllEntries !== "function") {
    throw new TypeError("reactive map must expose replaceLayer() and getAllEntries()");
  }
}

/**
 * Install the authoritative resolved flags2env snapshot as one raw string
 * layer. This is structurally compatible with @oresoftware/ores-reactive-maps
 * without making that independently published package a mandatory dependency.
 */
export function installResolvedLayer<TMap extends ReactiveStringMapLike>(
  map: TMap,
  argv: readonly unknown[] = process.argv,
  options: ReactiveInstallOptions = {},
): TMap {
  assertReactiveMap(map);
  const {
    layerName = "flags2env",
    source = "flags2env",
    priority = 200,
    configPath,
  } = options;
  const raw = parse(argv, configPath ? { configPath } : {});
  map.replaceLayer(layerName, source, priority, raw);
  return map;
}

/**
 * Coerce the current winner for every reactive key using .cli-flags.toml.
 * Reactive layers remain raw strings; schema interpretation happens only after
 * precedence resolution, preventing each source from inventing its own parser.
 */
export function typedSnapshot<T extends object = Record<string, unknown>>(
  map: ReactiveStringMapLike,
  options: Flags2EnvOptions = {},
): T & Record<string, unknown> {
  assertReactiveMap(map);
  const raw: Record<string, string> = Object.create(null) as Record<string, string>;
  for (const [key, entry] of Object.entries(map.getAllEntries())) {
    if (!entry || typeof entry.value !== "string") {
      throw new TypeError(`reactive entry ${key} must contain a string value before flags2env coercion`);
    }
    raw[key] = entry.value;
  }
  return Object.assign({ ...raw } as Record<string, unknown>, coerce<T>(raw, options)) as T &
    Record<string, unknown>;
}

export default {
  installResolvedLayer,
  typedSnapshot,
};
