#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import {
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const tmp = mkdtempSync(join(tmpdir(), "flags2env-readme-"));
const snippets = extractUsageSnippets(readFileSync(join(root, "README.md"), "utf8"));
const suffix = process.platform === "darwin" ? "dylib" : process.platform === "win32" ? "dll" : "so";
const sharedLib = join(root, "build", process.platform === "win32" ? "flags2env.dll" : `libflags2env.${suffix}`);
const fixtureConfig = join(root, "tests", "fixtures", ".cli-flags.toml");
const fixtureCwd = join(root, "tests", "fixtures", "nested", "deeper");
const toolCacheEnv = {
  PUB_CACHE: join(tmp, "pub-cache"),
  GOCACHE: join(tmp, "go-build-cache"),
  GOMODCACHE: join(tmp, "go-mod-cache"),
};
for (const cacheDir of Object.values(toolCacheEnv)) {
  mkdirSync(cacheDir, { recursive: true });
}

try {
  run("build core", "make", ["all"], { cwd: root });

  testNode();
  testBun();
  testDeno();
  testC();
  testDart();
  testGo();
  testErlang();
  testGleam();
  testJava();
  testPython();
  testRuby();
  testPHP();
  testRust();
  testSwift();

  console.log("README snippet smoke tests passed");
} finally {
  rmSync(tmp, { recursive: true, force: true });
}

function extractUsageSnippets(markdown) {
  const usage = markdown.split("\n## Usage\n")[1]?.split("\n## Parser Notes\n")[0] ?? "";
  const out = new Map();
  let heading = "";
  let inFence = false;
  let fenceLang = "";
  let buffer = [];

  for (const line of usage.split("\n")) {
    const headingMatch = line.match(/^### (.+)$/) ?? line.match(/^<summary>(.+)<\/summary>$/);
    if (!inFence && headingMatch) {
      heading = headingMatch[1];
      continue;
    }
    const fenceMatch = line.match(/^```(\w*)$/);
    if (fenceMatch) {
      if (!inFence) {
        inFence = true;
        fenceLang = fenceMatch[1];
        buffer = [];
      } else {
        inFence = false;
        if (heading && !out.has(heading)) {
          out.set(heading, { lang: fenceLang, code: buffer.join("\n") });
        }
      }
      continue;
    }
    if (inFence) {
      buffer.push(line);
    }
  }
  return out;
}

function snippet(name) {
  const value = snippets.get(name);
  if (!value) {
    throw new Error(`README snippet not found: ${name}`);
  }
  return value.code;
}

function run(label, command, args, options = {}) {
  console.log(`readme-snippet: ${label}`);
  const result = spawnSync(command, args, {
    cwd: options.cwd ?? root,
    env: { ...process.env, ...toolCacheEnv, ...(options.env ?? {}) },
    encoding: "utf8",
    stdio: options.stdio ?? "pipe",
  });
  if (result.status !== 0) {
    throw new Error([
      `${label} failed with exit ${result.status}`,
      result.stdout,
      result.stderr,
    ].filter(Boolean).join("\n"));
  }
  return result;
}

function has(command) {
  return spawnSync("sh", ["-c", `command -v ${command}`], { stdio: "ignore" }).status === 0;
}

function canRun(command, args = ["--version"]) {
  if (!has(command)) {
    return false;
  }
  return spawnSync(command, args, { stdio: "ignore" }).status === 0;
}

function skip(label, reason) {
  console.log(`readme-snippet: skipping ${label}; ${reason}`);
}

function mkdirp(path) {
  mkdirSync(path, { recursive: true });
}

function write(path, content) {
  mkdirp(dirname(path));
  writeFileSync(path, content);
}

function linkOrCopy(source, destination) {
  mkdirp(dirname(destination));
  try {
    symlinkSync(source, destination);
  } catch {
    cpSync(source, destination, { recursive: true });
  }
}

function makeSnippetProject(name) {
  const dir = join(tmp, name);
  mkdirp(dir);
  cpSync(fixtureConfig, join(dir, ".cli-flags.toml"));
  linkOrCopy(join(root, "build"), join(dir, "build"));
  return dir;
}

function jsAssert() {
  return `
if (combined.DEBUG !== "true" || combined.PORT !== "8181" || combined.COLOR !== "true") {
  throw new Error("unexpected combined map: " + JSON.stringify(combined));
}
`;
}

function testNode() {
  if (!has("node")) {
    skip("Node.js", "node not found");
    return;
  }

  const addon = join(root, "clients", "nodejs", "build", "Release", "flags2env.node");
  if (!existsSync(addon)) {
    run("build Node.js addon", "npx", ["node-gyp", "rebuild"], { cwd: join(root, "clients", "nodejs") });
  }

  const dir = makeSnippetProject("nodejs");
  const pkg = join(dir, "node_modules", "@oresoftware", "f2e");
  write(join(pkg, "package.json"), JSON.stringify({ type: "module", exports: { ".": "./lib.mjs" } }));
  write(join(pkg, "lib.mjs"), reexportModule(join(root, "clients", "nodejs", "lib.mjs")));
  write(join(dir, "snippet.mjs"), `${snippet("Node.js")}\n${jsAssert()}`);
  run("Node.js README snippet", "node", [join(dir, "snippet.mjs"), "--debug=t", "--port", "8181"], {
    cwd: dir,
    env: { FLAGS2ENV_NODE_ADDON: addon },
  });
}

function testBun() {
  if (!has("bun")) {
    skip("Bun", "bun not found");
    return;
  }

  const dir = makeSnippetProject("bun");
  const pkg = join(dir, "node_modules", "@oresoftware", "f2e");
  write(join(pkg, "package.json"), JSON.stringify({ type: "module", exports: { "./bun": "./bun.mjs" } }));
  write(join(pkg, "bun.mjs"), reexportModule(join(root, "clients", "bun", "lib.mjs")));
  write(join(dir, "snippet.mjs"), `${snippet("Bun")}\n${jsAssert()}`);
  run("Bun README snippet", "bun", [join(dir, "snippet.mjs"), "--debug=t", "--port", "8181"], {
    cwd: dir,
    env: { FLAGS2ENV_NATIVE_LIB: sharedLib },
  });
}

function testDeno() {
  if (!has("deno")) {
    skip("Deno", "deno not found");
    return;
  }

  const dir = makeSnippetProject("deno");
  mkdirp(join(dir, "clients", "deno", "native"));
  cpSync(join(root, "clients", "deno", "lib.ts"), join(dir, "clients", "deno", "lib.ts"));
  cpSync(join(root, "clients", "deno", "mod.ts"), join(dir, "clients", "deno", "mod.ts"));
  linkOrCopy(sharedLib, join(dir, "clients", "deno", "native", process.platform === "win32" ? "flags2env.dll" : `libflags2env.${suffix}`));
  write(join(dir, "snippet.ts"), `${snippet("Deno")}\n${jsAssert()}`);
  run("Deno README snippet", "deno", ["run", "--allow-ffi", "--allow-read", "--allow-env", join(dir, "snippet.ts"), "--debug=t", "--port", "8181"], { cwd: dir });
}

function testC() {
  const dir = makeSnippetProject("c");
  const source = join(dir, "snippet.c");
  const bin = join(dir, "snippet");
  write(source, snippet("C"));
  run("C README snippet compile", "cc", [
    "-std=c99",
    "-Wall",
    "-Wextra",
    "-Wpedantic",
    "-I", root,
    "-I", join(root, "src"),
    source,
    join(root, "clients", "c", "lib.c"),
    join(root, "src", "parser.c"),
    "-o", bin,
  ]);
  const result = run("C README snippet", bin, ["app", "--debug=t", "--port", "8181"], { cwd: dir });
  if (!result.stdout.includes("PORT=8181")) {
    throw new Error(`C README snippet returned unexpected output: ${result.stdout}`);
  }
}

function testDart() {
  if (!has("dart")) {
    skip("Dart", "dart not found");
    return;
  }

  const dir = makeSnippetProject("dart");
  write(join(dir, "pubspec.yaml"), `name: readme_snippet\nversion: 1.0.0\nenvironment:\n  sdk: ^3.0.0\ndependencies:\n  flags2env:\n    path: ${join(root, "clients", "dart")}\n`);
  write(join(dir, "bin", "main.dart"), snippet("Dart"));
  write(join(dir, "bin", "assert.dart"), `
import 'main.dart' as snippet;

void main() {
  final combined = snippet.getEnvMap(['--debug=t', '--port', '8181']);
  if (combined['DEBUG'] != 'true' || combined['PORT'] != '8181' || combined['COLOR'] != 'true') {
    throw StateError('unexpected combined map: $combined');
  }
}
`);
  run("Dart README snippet deps", "dart", ["pub", "get"], { cwd: dir });
  run("Dart README snippet", "dart", ["run", "bin/main.dart", "--debug=t", "--port", "8181"], { cwd: dir });
  run("Dart README snippet assertion", "dart", ["run", "bin/assert.dart"], { cwd: dir });
}

function testGo() {
  if (!has("go")) {
    skip("Go", "go not found");
    return;
  }

  const dir = makeSnippetProject("go");
  write(join(dir, "go.mod"), `module readme_snippet\n\ngo 1.22\n\nrequire github.com/oresoftware/flags-2-env/clients/golang v0.0.0\n\nreplace github.com/oresoftware/flags-2-env/clients/golang => ${join(root, "clients", "golang")}\n`);
  write(join(dir, "main.go"), snippet("Go"));
  write(join(dir, "main_test.go"), `
package main

import "testing"

func TestReadmeGetEnvMap(t *testing.T) {
	combined, err := getEnvMap([]string{"--debug=t", "--port", "8181"})
	if err != nil {
		t.Fatal(err)
	}
	if combined["DEBUG"] != "true" || combined["PORT"] != "8181" || combined["COLOR"] != "true" {
		t.Fatalf("unexpected combined map: %#v", combined)
	}
}
`);
  run("Go README snippet", "go", ["run", ".", "--debug=t", "--port", "8181"], { cwd: dir });
  run("Go README snippet assertion", "go", ["test", "."], { cwd: dir });
}

function testErlang() {
  if (!has("erlc")) {
    skip("Erlang", "erlc not found");
    return;
  }

  const dir = makeSnippetProject("erlang");
  write(join(dir, "my_app.erl"), snippet("Erlang"));
  run("Erlang README snippet compile", "erlc", [join(dir, "my_app.erl")], { cwd: dir });
}

function testGleam() {
  if (!has("gleam")) {
    skip("Gleam", "gleam not found");
    return;
  }

  const dir = makeSnippetProject("gleam");
  write(join(dir, "gleam.toml"), `name = "readme_snippet"\nversion = "1.0.0"\n\n[dependencies]\ngleam_stdlib = ">= 0.34.0 and < 2.0.0"\n`);
  write(join(dir, "src", "flags2env.gleam"), readFileSync(join(root, "clients", "gleam", "src", "flags2env.gleam"), "utf8"));
  write(join(dir, "src", "main.gleam"), snippet("Gleam"));
  run("Gleam README snippet compile", "gleam", ["build"], { cwd: dir });
}

function testJava() {
  if (!canRun("javac", ["-version"])) {
    skip("Java", "javac not found or no JDK is installed");
    return;
  }

  const dir = makeSnippetProject("java");
  write(join(dir, "Main.java"), snippet("Java"));
  run("Java README snippet compile", "javac", [
    "-d", join(dir, "classes"),
    join(root, "clients", "java", "src", "main", "java", "com", "oresoftware", "flags2env", "Flags2Env.java"),
    join(dir, "Main.java"),
  ]);
}

function testPython() {
  if (!has("python3")) {
    skip("Python", "python3 not found");
    return;
  }

  const dir = makeSnippetProject("python");
  write(join(dir, "snippet.py"), `${snippet("Python")}\nassert combined["DEBUG"] == "true", combined\nassert combined["PORT"] == "8181", combined\nassert combined["COLOR"] == "true", combined\n`);
  run("Python README snippet", "python3", [join(dir, "snippet.py"), "--debug=t", "--port", "8181"], {
    cwd: dir,
    env: { PYTHONPATH: join(root, "clients", "python") },
  });
}

function testRuby() {
  if (!has("ruby")) {
    skip("Ruby", "ruby not found");
    return;
  }

  const dir = makeSnippetProject("ruby");
  mkdirp(join(dir, "clients", "ruby"));
  cpSync(join(root, "clients", "ruby", "lib.rb"), join(dir, "clients", "ruby", "lib.rb"));
  write(join(dir, "snippet.rb"), `${snippet("Ruby")}\nraise "unexpected combined map: #{combined.inspect}" unless combined["DEBUG"] == "true" && combined["PORT"] == "8181" && combined["COLOR"] == "true"\n`);
  run("Ruby README snippet", "ruby", [join(dir, "snippet.rb"), "--debug=t", "--port", "8181"], {
    cwd: dir,
    env: { FLAGS2ENV_NATIVE_LIB: sharedLib },
  });
}

function testPHP() {
  if (!has("php")) {
    skip("PHP", "php not found");
    return;
  }

  const dir = makeSnippetProject("php");
  mkdirp(join(dir, "clients", "php"));
  cpSync(join(root, "clients", "php", "lib.php"), join(dir, "clients", "php", "lib.php"));
  write(join(dir, "snippet.php"), `${snippet("PHP")}\nif (($combined["DEBUG"] ?? null) !== "true" || ($combined["PORT"] ?? null) !== "8181" || ($combined["COLOR"] ?? null) !== "true") { throw new RuntimeException("unexpected combined map"); }\n`);
  run("PHP README snippet", "php", ["-d", "ffi.enable=true", join(dir, "snippet.php"), "--debug=t", "--port", "8181"], {
    cwd: dir,
    env: { FLAGS2ENV_NATIVE_LIB: sharedLib },
  });
}

function testRust() {
  if (!has("cargo")) {
    skip("Rust", "cargo not found");
    return;
  }

  const dir = makeSnippetProject("rust");
  write(join(dir, "Cargo.toml"), `[package]\nname = "readme_snippet"\nversion = "0.1.0"\nedition = "2021"\n\n[dependencies]\nflags2env = { path = "${join(root, "clients", "rust")}" }\n`);
  write(join(dir, "src", "main.rs"), snippet("Rust"));
  run("Rust README snippet", "cargo", ["run", "--quiet", "--", "--debug=t", "--port", "8181"], {
    cwd: dir,
    env: dynamicLibraryEnv(),
  });
}

function testSwift() {
  if (!has("swiftc")) {
    skip("Swift", "swiftc not found");
    return;
  }

  const dir = makeSnippetProject("swift");
  const main = join(dir, "main.swift");
  const bin = join(dir, "snippet");
  write(main, `${snippet("Swift")}\nif combined["DEBUG"] != "true" || combined["PORT"] != "8181" || combined["COLOR"] != "true" { fatalError("unexpected combined map: \\(combined)") }\n`);
  run("Swift README snippet compile", "swiftc", [join(root, "clients", "swift", "lib.swift"), main, "-o", bin]);
  run("Swift README snippet", bin, ["--debug=t", "--port", "8181"], {
    cwd: dir,
    env: { ...dynamicLibraryEnv(), FLAGS2ENV_NATIVE_LIB: sharedLib },
  });
}

function reexportModule(path) {
  const url = pathToFileURL(path).href;
  return `export * from ${JSON.stringify(url)};\nimport mod from ${JSON.stringify(url)};\nexport default mod;\n`;
}

function dynamicLibraryEnv() {
  if (process.platform === "darwin") {
    return { DYLD_LIBRARY_PATH: join(root, "build") };
  }
  if (process.platform === "win32") {
    return { PATH: `${join(root, "build")};${process.env.PATH ?? ""}` };
  }
  return { LD_LIBRARY_PATH: join(root, "build") };
}
