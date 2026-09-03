#!/usr/bin/env python3
from pathlib import Path

readme_path = Path("README.md")
readme = readme_path.read_text()
old_swift = '    let f2e = try Flags2Env(libraryPath: "./build/libflags2env.dylib")'
new_swift = '''    let nativeLibrary = ProcessInfo.processInfo.environment["FLAGS2ENV_NATIVE_LIB"] ?? {
        #if os(macOS)
        return "./build/libflags2env.dylib"
        #elseif os(Windows)
        return "./build/flags2env.dll"
        #else
        return "./build/libflags2env.so"
        #endif
    }()
    let f2e = try Flags2Env(libraryPath: nativeLibrary)'''
count = readme.count(old_swift)
if count != 2:
    raise SystemExit(f"expected exactly two Swift dynamic-library examples, found {count}")
readme_path.write_text(readme.replace(old_swift, new_swift))

test_path = Path("scripts/test-readme-snippets.mjs")
source = test_path.read_text()
old_php = '''  run("PHP README snippet", "php", ["-d", "ffi.enable=true", join(dir, "snippet.php"), "--debug=t", "--port", "8181"], {
  cwd: dir,
  env: { FLAGS2ENV_NATIVE_LIB: sharedLib },
});'''
new_php = '''  run("PHP README snippet", "php", ["-d", "ffi.enable=true", join(dir, "snippet.php"), "--debug=t", "--port", "8181"], {
    cwd: dir,
    env: { FLAGS2ENV_NATIVE_LIB: sharedLib },
  });'''
if source.count(old_php) != 1:
    raise SystemExit("expected exactly one unformatted PHP README invocation")
source = source.replace(old_php, new_php)

old_swift_run = '  run("Swift README snippet", bin, ["--debug=t", "--port", "8181"], { cwd: dir, env: dynamicLibraryEnv() });'
new_swift_run = '''  run("Swift README snippet", bin, ["--debug=t", "--port", "8181"], {
    cwd: dir,
    env: { ...dynamicLibraryEnv(), FLAGS2ENV_NATIVE_LIB: sharedLib },
  });'''
if source.count(old_swift_run) != 1:
    raise SystemExit("expected exactly one Swift README invocation")
test_path.write_text(source.replace(old_swift_run, new_swift_run))
