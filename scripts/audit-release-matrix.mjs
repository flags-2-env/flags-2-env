#!/usr/bin/env node
import { existsSync, readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join } from "node:path";

const root = new URL("..", import.meta.url).pathname;

const requiredClients = [
  "nodejs", "python", "java", "kotlin", "scala", "groovy", "clojure",
  "rust", "golang", "c", "cpp", "csharp", "fsharp", "php", "ruby",
  "swift", "dart", "elixir", "erlang", "gleam", "haskell", "ocaml",
  "reasonml", "perl", "lua", "nim", "r", "matlab", "julia", "fortran",
  "zig", "crystal", "solidity", "bash", "zsh", "oreslang",
];

const expectedRepositories = {
  nodejs: "npm Registry",
  python: "PyPI",
  java: "Maven Central / Sonatype",
  kotlin: "Maven Central / Sonatype",
  scala: "Maven Central / Sonatype",
  groovy: "Maven Central / Sonatype",
  clojure: "Maven Central / Sonatype",
  rust: "crates.io",
  golang: "Git repository / pkg.go.dev",
  c: "Git repository / Homebrew source build",
  cpp: "Git repository / source archive",
  csharp: "NuGet Gallery",
  fsharp: "NuGet Gallery",
  php: "Packagist",
  ruby: "RubyGems.org",
  swift: "Git repository / SwiftPM",
  dart: "pub.dev",
  elixir: "Hex.pm",
  erlang: "Hex.pm",
  gleam: "Hex.pm",
  haskell: "Hackage",
  ocaml: "opam Repository",
  reasonml: "opam Repository",
  perl: "CPAN",
  lua: "LuaRocks Repository",
  nim: "Nimble Package Index",
  r: "CRAN / R-universe",
  matlab: "Source archive / Git repository",
  julia: "Julia General Registry",
  fortran: "Git repository / fpm package",
  zig: "Git repository / Zig package",
  crystal: "Git repository / Shards",
  solidity: "npm Registry",
  bash: "Homebrew / Git repository",
  zsh: "Homebrew / Git repository",
  oreslang: "Git repository / source archive",
};

const packageControls = {
  oreslang: [
    ["clients/oreslang/.ores.pkg.toml", /^name = "flags2env"$/m, "Oreslang package name"],
    ["clients/oreslang/.ores.pkg.toml", /^roots = \["src"\]$/m, "Oreslang package source allowlist"],
    ["clients/oreslang/native/flags2env_ores_bridge.c", /#include "parser\.h"/, "Oreslang bridge uses package-local parser header"],
    ["clients/oreslang/README.md", /release support remains evidence-gated/i, "Oreslang client does not overclaim backend support"],
    ["scripts/publish-client.sh", /clients\/oreslang\/v\$\{PACKAGE_VERSION/, "Oreslang release tag is namespaced"],
    ["contracts/oreslang-client-backends.v1.json", /"unsupported_is_pass": false/, "Oreslang backend contract fails closed on unsupported capability"],
    ["contracts/oreslang-client-backends.v1.json", /"zero_step_ci_is_pass": false/, "Oreslang backend contract rejects zero-step evidence"],
  ],
  nodejs: [
    [".npmignore", /^!clients\/nodejs\//m, "npm allowlist includes Node.js client"],
    [".npmignore", /^!LICENSE$/m, "npm allowlist includes package license"],
    ["package.json", /"files"\s*:\s*\[/, "npm package files allowlist"],
    ["package.json", /"license"\s*:\s*"MIT"/, "npm package declares MIT license"],
    ["package.json", /"LICENSE"/, "npm package includes root license file"],
    ["package.json", /"clients\/nodejs\/lib\.mjs"/, "npm package includes Node.js ESM client"],
    ["package.json", /"clients\/bun\/lib\.mjs"/, "npm package includes Bun entry"],
    ["package.json", /"clients\/deno\/mod\.ts"/, "npm package includes Deno entry"],
    ["clients/nodejs/package.json.ejs", /"license": "MIT"/, "rendered Node.js package declares MIT license"],
    ["clients/bun/package.json.ejs", /"license": "MIT"/, "rendered Bun package declares MIT license"],
    ["clients/deno/deno.json", /"license": "MIT"/, "Deno package declares MIT license"],
  ],
  python: [
    ["clients/python/MANIFEST.in", /^include lib\.py$/m, "PyPI MANIFEST includes runtime module"],
    ["clients/python/MANIFEST.in", /^include flags2env\.py$/m, "PyPI MANIFEST includes public module"],
    ["clients/python/MANIFEST.in", /^include README\.md$/m, "PyPI MANIFEST includes README"],
    ["clients/python/MANIFEST.in", /^include LICENSE$/m, "PyPI MANIFEST includes license file"],
    ["clients/python/MANIFEST.in", /^exclude Dockerfile$/m, "PyPI MANIFEST excludes Dockerfile"],
    ["clients/python/MANIFEST.in", /^exclude publish\.sh$/m, "PyPI MANIFEST excludes publish wrapper"],
    ["clients/python/MANIFEST.in", /^exclude test\.py$/m, "PyPI MANIFEST excludes test file"],
    ["clients/python/pyproject.toml", /setuptools>=77/, "PyPI build backend supports SPDX license metadata"],
    ["clients/python/pyproject.toml", /^license = "MIT"$/m, "PyPI metadata uses SPDX license string"],
    ["clients/python/pyproject.toml", /^license-files = \["LICENSE"\]$/m, "PyPI metadata declares package-local license file"],
    ["scripts/publish-client.sh", /\$\{PYTHON:-python3\} -m build/, "Python publish command defaults to python3"],
    ["scripts/docker-check-new-clients.sh", /run python python:3\.12-bookworm/, "Docker smoke includes Python runtime"],
    ["scripts/docker-check-new-clients.sh", /python -m build && python -m twine check dist\/\*/, "Docker smoke builds and checks PyPI artifacts"],
    ["scripts/docker-check-new-clients.sh", /sdist includes/, "Docker smoke rejects forbidden PyPI sdist files"],
    ["scripts/docker-check-new-clients.sh", /wheel missing dist-info license/, "Docker smoke verifies PyPI wheel license metadata"],
  ],
  java: [
    ["clients/java/pom.xml", /central-publishing-maven-plugin/, "Maven Central publishing plugin"],
    ["clients/java/pom.xml", /<directory>native<\/directory>/, "Maven package uses package-local native sources"],
    ["clients/java/pom.xml", /<include>\*\*\/\*\.c<\/include>/, "Maven package includes C sources"],
    ["clients/java/pom.xml", /<include>\*\*\/\*\.h<\/include>/, "Maven package includes C headers"],
    ["clients/java/pom.xml", /<excludes>[\s\S]*<exclude>\*\*\/publish\.sh<\/exclude>/, "Maven resources exclude publish wrappers"],
    ["clients/java/native/flags2env_jni.c", /#include "parser\.h"/, "JNI source includes package-local parser header"],
    ["clients/java/Dockerfile", /clients\/java\/native\/parser\.c/, "Java Docker smoke builds package-local parser source"],
    ["clients/java/pom.xml", /<artifactId>maven-source-plugin<\/artifactId>[\s\S]*?<goal>jar-no-fork<\/goal>/, "Maven package lifecycle attaches the sources artifact"],
    ["clients/java/pom.xml", /<artifactId>maven-javadoc-plugin<\/artifactId>[\s\S]*?<goal>jar<\/goal>/, "Maven package lifecycle attaches the javadoc artifact"],
    ["scripts/docker-check-new-clients.sh", /run java maven:3\.9-eclipse-temurin-21/, "Docker smoke includes Java Maven runtime"],
    ["scripts/docker-check-new-clients.sh", /mvn -q -f clients\/java\/pom\.xml -DskipTests package/, "Docker smoke runs the Maven package lifecycle"],
    ["scripts/docker-check-new-clients.sh", /Maven artifact includes forbidden local file/, "Docker smoke rejects forbidden Maven artifact files"],
  ],
  kotlin: [
    ["clients/kotlin/build.gradle.kts", /`maven-publish`/, "Gradle maven-publish plugin"],
    ["clients/kotlin/build.gradle.kts", /ossrh-staging-api\.central\.sonatype\.com/, "Kotlin publishes through Central Portal OSSRH compatibility endpoint"],
    ["clients/kotlin/build.gradle.kts", /CENTRAL_TOKEN_USERNAME/, "Kotlin uses Central Portal token env vars"],
    ["clients/kotlin/build.gradle.kts", /artifactId = "flags2env-kotlin"/, "Kotlin artifact id"],
    ["clients/kotlin/build.gradle.kts", /exclude\("publish\.sh"\)/, "Kotlin jar excludes publish wrapper"],
    ["clients/kotlin/build.gradle.kts", /setRequired \{ project\.hasProperty\("release"\) \}/, "Kotlin signing is required for release publishes"],
    ["scripts/publish-client.sh", /gradle -Prelease publish/, "Kotlin/Groovy release command enables Gradle signing"],
    ["scripts/docker-check-new-clients.sh", /gradle -p clients\/kotlin jar sourcesJar javadocJar/, "Docker full smoke builds Kotlin Gradle artifacts"],
    ["scripts/docker-check-new-clients.sh", /flags2env-kotlin-0\.1\.0-sources\.jar/, "Docker full smoke inspects Kotlin sources jar"],
    ["scripts/docker-check-new-clients.sh", /Gradle artifact includes forbidden local file/, "Docker full smoke rejects forbidden Gradle artifact files"],
  ],
  scala: [
    ["clients/scala/build.sbt", /sonatypeCentralHost/, "Scala uses Sonatype Central portal host"],
    ["clients/scala/build.sbt", /publishTo := sonatypePublishToBundle\.value/, "Scala Sonatype bundle publishing"],
    ["clients/scala/build.sbt", /publishMavenStyle := true/, "Scala Maven-style package"],
    ["clients/scala/build.sbt", /Compile \/ packageSrc \/ publishArtifact := true/, "Scala publishes source jar artifact"],
    ["clients/scala/build.sbt", /Compile \/ packageDoc \/ publishArtifact := true/, "Scala publishes doc jar artifact"],
    ["clients/scala/project/plugins.sbt", /sbt-sonatype/, "Scala Sonatype plugin"],
    ["clients/scala/project/plugins.sbt", /sbt-pgp/, "Scala signing plugin"],
    ["scripts/docker-check-new-clients.sh", /sbt -batch -Dsbt\.supershell=false package "Compile \/ packageSrc" "Compile \/ packageDoc"/, "Docker full smoke builds Scala sbt artifacts"],
    ["scripts/docker-check-new-clients.sh", /flags2env-scala_2\.13-0\.1\.0-sources\.jar/, "Docker full smoke inspects Scala sources jar"],
    ["scripts/docker-check-new-clients.sh", /com\/oresoftware\/flags2env\/scala\/Flags2Env\$\.class/, "Docker full smoke inspects Scala class jar"],
    ["scripts/docker-check-new-clients.sh", /Scala artifact includes forbidden local file/, "Docker full smoke rejects forbidden Scala artifact files"],
  ],
  groovy: [
    ["clients/groovy/build.gradle", /id 'maven-publish'/, "Groovy Gradle maven-publish plugin"],
    ["clients/groovy/build.gradle", /ossrh-staging-api\.central\.sonatype\.com/, "Groovy publishes through Central Portal OSSRH compatibility endpoint"],
    ["clients/groovy/build.gradle", /CENTRAL_TOKEN_USERNAME/, "Groovy uses Central Portal token env vars"],
    ["clients/groovy/build.gradle", /artifactId = 'flags2env-groovy'/, "Groovy artifact id"],
    ["clients/groovy/build.gradle", /exclude 'publish\.sh'/, "Groovy jar excludes publish wrapper"],
    ["clients/groovy/build.gradle", /required \{ project\.hasProperty\('release'\) \}/, "Groovy signing is required for release publishes"],
    ["scripts/publish-client.sh", /gradle -Prelease publish/, "Kotlin/Groovy release command enables Gradle signing"],
    ["scripts/docker-check-new-clients.sh", /gradle -p clients\/groovy jar sourcesJar javadocJar/, "Docker full smoke builds Groovy Gradle artifacts"],
    ["scripts/docker-check-new-clients.sh", /flags2env-groovy-0\.1\.0-sources\.jar/, "Docker full smoke inspects Groovy sources jar"],
    ["scripts/docker-check-new-clients.sh", /Gradle artifact includes forbidden local file/, "Docker full smoke rejects forbidden Gradle artifact files"],
  ],
  clojure: [
    ["clients/clojure/build.clj", /sign-and-deploy-file/, "Clojure Sonatype deploy command"],
    ["clients/clojure/build.clj", /ossrh-staging-api\.central\.sonatype\.com/, "Clojure publishes through Central Portal OSSRH compatibility endpoint"],
    ["clients/clojure/build.clj", /source-jar/, "Clojure source jar generation"],
    ["clients/clojure/build.clj", /javadoc-jar-file/, "Clojure javadoc jar path"],
    ["clients/clojure/build.clj", /\(defn javadoc-jar/, "Clojure javadoc jar generation"],
    ["clients/clojure/build.clj", /"-Djavadoc="/, "Clojure deploy attaches javadoc jar"],
    ["clients/clojure/build.clj", /com\.oresoftware\/flags2env-clojure/, "Clojure Maven artifact id"],
    ["scripts/docker-check-new-clients.sh", /clojure -T:build javadoc-jar/, "Docker smoke builds Clojure javadoc jar"],
    ["scripts/docker-check-new-clients.sh", /flags2env-clojure-0\.1\.0-sources\.jar/, "Docker smoke inspects Clojure sources jar"],
    ["scripts/docker-check-new-clients.sh", /META-INF\/maven\/com\.oresoftware\/flags2env-clojure\/pom\.xml/, "Docker smoke inspects Clojure generated POM"],
    ["scripts/docker-check-new-clients.sh", /Clojure artifact includes forbidden local file/, "Docker smoke rejects forbidden Clojure artifact files"],
  ],
  rust: [
    ["clients/rust/Cargo.toml", /^include = \[/m, "Cargo include allowlist"],
    ["clients/rust/Cargo.toml", /^readme = "README\.md"$/m, "Cargo package declares README"],
    ["clients/rust/Cargo.toml", /"LICENSE"/, "Cargo package includes license file"],
    ["clients/rust/Cargo.toml", /"README\.md"/, "Cargo package includes README"],
    ["clients/rust/Cargo.toml", /"native\/\*\*"/, "Cargo includes package-local parser sources"],
    ["clients/rust/Cargo.toml", /"src\/\*\*"/, "Cargo includes Rust source"],
    ["clients/rust/Cargo.toml", /"tests\/\*\*"/, "Cargo includes package-local smoke tests"],
    ["clients/rust/README.md", /Rust bindings/, "crates.io package README"],
    ["clients/rust/LICENSE", /MIT License/, "crates.io package license file"],
    ["clients/rust/Dockerfile", /COPY clients\/rust \.\/clients\/rust/, "Rust Docker smoke copies only the Rust package"],
    ["clients/rust/tests/smoke.rs", /native\/parser\.c/, "Rust smoke test builds package-local parser source"],
    ["scripts/docker-check-new-clients.sh", /run rust rust:1-bookworm/, "Docker smoke includes Rust runtime"],
    ["scripts/docker-check-new-clients.sh", /cargo test && cargo package --allow-dirty/, "Docker smoke tests and packages Rust crate"],
  ],
  golang: [
    ["clients/golang/go.mod", /^module github\.com\/oresoftware\/flags-2-env\/clients\/golang$/m, "Go module path for pkg.go.dev indexing"],
    ["clients/golang/lib.go", /#cgo CFLAGS: -I\./, "Go module builds against package-local C sources"],
    ["clients/golang/lib.go", /#include "parser\.h"/, "Go module includes package-local parser header"],
    ["clients/golang/README.md", /pkg\.go\.dev/, "Go submodule README documents index path"],
    ["clients/golang/LICENSE", /MIT License/, "Go submodule license file"],
    ["scripts/publish-client.sh", /clients\/golang\/v\$\{PACKAGE_VERSION/, "Go submodule release uses path-prefixed tags"],
    ["scripts/docker-check-new-clients.sh", /run golang golang:1\.23-bookworm/, "Docker smoke includes Go runtime"],
    ["scripts/docker-check-new-clients.sh", /cd clients\/golang && go test \.\/\.\.\./, "Docker smoke runs Go module tests"],
  ],
  c: [
    ["Makefile", /^all: shared static cli$/m, "native C build target publishes CLI and libraries"],
    ["packaging/homebrew/Formula/flags2env.rb", /bin\.install "build\/flags2env"/, "Homebrew installs native CLI"],
    ["packaging/homebrew/Formula/flags2env.rb", /lib\.install "build\/libflags2env\.a"/, "Homebrew installs C static library"],
    ["packaging/homebrew/Formula/flags2env.rb", /assert_equal "true", shell_output\("bash/, "Homebrew formula tests bash helper integration"],
    ["scripts/publish-client.sh", /c\)[\s\S]*scripts\/publish-homebrew\.sh --release/, "C publish wrapper runs Homebrew formula release checks"],
    ["clients/c/README.md", /flags2env C/, "C source package README"],
    ["clients/c/LICENSE", /MIT License/, "C source package license file"],
  ],
  cpp: [
    ["clients/cpp/CMakeLists.txt", /add_library\(flags2env_cpp INTERFACE\)/, "C++ package exposes interface target"],
    ["clients/cpp/CMakeLists.txt", /add_library\(flags2env_native STATIC native\/parser\.c\)/, "C++ package builds package-local parser source"],
    ["clients/cpp/CMakeLists.txt", /target_include_directories\(flags2env_cpp INTERFACE include native\)/, "C++ target includes package-local header paths"],
    ["clients/cpp/CMakeLists.txt", /add_test\(NAME flags2env_cpp_smoke/, "C++ CMake registers smoke test"],
    ["clients/cpp/README.md", /flags2env C\+\+/, "C++ source package README"],
    ["clients/cpp/LICENSE", /MIT License/, "C++ source package license file"],
    ["scripts/docker-check-new-clients.sh", /cmake -S clients\/cpp -B \/tmp\/flags2env-cpp-build/, "Docker smoke configures C++ CMake package"],
    ["scripts/docker-check-new-clients.sh", /ctest --test-dir \/tmp\/flags2env-cpp-build --output-on-failure/, "Docker smoke runs C++ CTest package test"],
  ],
  csharp: [
    ["clients/csharp/Flags2Env.nuspec", /<files>/, "NuGet files list"],
    ["clients/csharp/Flags2Env.nuspec", /<readme>README\.md<\/readme>/, "NuGet nuspec declares package README"],
    ["clients/csharp/Flags2Env.nuspec", /src="README\.md"/, "NuGet nuspec includes package README"],
    ["clients/csharp/Flags2Env.csproj", /<PackageReadmeFile>README\.md<\/PackageReadmeFile>/, "dotnet pack declares package README"],
    ["clients/csharp/Flags2Env.csproj", /Include="README\.md"[\s\S]*PackagePath=""/, "dotnet pack includes package README"],
    ["clients/csharp/Flags2Env.nuspec", /native\/parser\.c/, "NuGet includes package-local parser source"],
    ["clients/csharp/Flags2Env.nuspec", /native\/parser\.h/, "NuGet includes package-local parser header"],
    ["clients/csharp/Flags2Env.csproj", /Include="native\/parser\.c"[\s\S]*PackagePath="native\/"/, "dotnet pack includes package-local parser source"],
    ["clients/csharp/Flags2Env.csproj", /Include="native\/parser\.h"[\s\S]*PackagePath="native\/"/, "dotnet pack includes package-local parser header"],
    ["clients/csharp/Flags2EnvTest.cs", /clients\/csharp\/native\/parser\.c/, "C# smoke test can build package-local parser source"],
    ["scripts/docker-check-new-clients.sh", /dotnet pack clients\/csharp\/Flags2Env\.csproj -c Release/, "Docker smoke packs C# NuGet package"],
    ["scripts/docker-check-new-clients.sh", /OreSoftware\.Flags2Env\.\*\.nupkg/, "Docker smoke inspects C# NuGet package"],
  ],
  fsharp: [
    ["clients/fsharp/Flags2Env.FSharp.nuspec", /<files>/, "NuGet files list"],
    ["clients/fsharp/Flags2Env.FSharp.nuspec", /<readme>README\.md<\/readme>/, "NuGet nuspec declares package README"],
    ["clients/fsharp/Flags2Env.FSharp.nuspec", /src="README\.md"/, "NuGet nuspec includes package README"],
    ["clients/fsharp/Flags2Env.FSharp.fsproj", /<PackageReadmeFile>README\.md<\/PackageReadmeFile>/, "dotnet pack declares package README"],
    ["clients/fsharp/Flags2Env.FSharp.fsproj", /Include="README\.md"[\s\S]*PackagePath=""/, "dotnet pack includes package README"],
    ["clients/fsharp/Flags2Env.FSharp.nuspec", /native\/parser\.c/, "NuGet includes package-local parser source"],
    ["clients/fsharp/Flags2Env.FSharp.nuspec", /native\/parser\.h/, "NuGet includes package-local parser header"],
    ["clients/fsharp/Flags2Env.FSharp.fsproj", /Include="native\/parser\.c"[\s\S]*PackagePath="native\/"/, "dotnet pack includes package-local parser source"],
    ["clients/fsharp/Flags2Env.FSharp.fsproj", /Include="native\/parser\.h"[\s\S]*PackagePath="native\/"/, "dotnet pack includes package-local parser header"],
    ["clients/fsharp/Flags2EnvTest.fs", /SetDllImportResolver/, "F# smoke test resolves package-local parser library"],
    ["scripts/docker-check-new-clients.sh", /dotnet pack clients\/fsharp\/Flags2Env\.FSharp\.fsproj -c Release/, "Docker smoke packs F# NuGet package"],
    ["scripts/docker-check-new-clients.sh", /OreSoftware\.Flags2Env\.FSharp\.\*\.nupkg/, "Docker smoke inspects F# NuGet package"],
  ],
  php: [
    ["clients/php/composer.json", /"archive"\s*:\s*\{/, "Composer archive controls"],
    ["clients/php/composer.json", /"license"\s*:\s*"MIT"/, "Composer package declares MIT license"],
    ["clients/php/README.md", /PHP bindings/, "Composer package README"],
    ["clients/php/LICENSE", /MIT License/, "Composer package license file"],
    ["clients/php/composer.json", /"\/Dockerfile"/, "Composer archive excludes Dockerfile"],
    ["clients/php/composer.json", /"\/publish\.sh"/, "Composer archive excludes publish wrapper"],
    ["clients/php/composer.json", /"\/test\.php"/, "Composer archive excludes tests"],
    ["scripts/docker-check-new-clients.sh", /run php php:8\.3-cli/, "Docker smoke includes PHP runtime"],
    ["scripts/docker-check-new-clients.sh", /php -d ffi\.enable=true clients\/php\/test\.php/, "Docker smoke runs PHP FFI client test"],
    ["scripts/docker-check-new-clients.sh", /composer archive --format=zip/, "Docker smoke builds Composer archive"],
    ["scripts/docker-check-new-clients.sh", /Composer archive includes forbidden local file/, "Docker smoke rejects forbidden Composer archive files"],
  ],
  ruby: [
    ["clients/ruby/flags2env.gemspec", /spec\.files\s*=\s*\[/, "RubyGems files list"],
    ["clients/ruby/flags2env.gemspec", /"lib\.rb"/, "RubyGems includes runtime file"],
    ["clients/ruby/flags2env.gemspec", /"README\.md"/, "RubyGems includes README"],
    ["clients/ruby/flags2env.gemspec", /"LICENSE"/, "RubyGems includes license file"],
    ["clients/ruby/README.md", /Ruby bindings/, "RubyGems package README"],
    ["clients/ruby/LICENSE", /MIT License/, "RubyGems package license file"],
  ],
  dart: [
    ["clients/dart/pubspec.yaml", /^description:/m, "pub.dev package description"],
    ["clients/dart/pubspec.yaml", /^repository:/m, "pub.dev repository metadata"],
    ["clients/dart/.pubignore", /^Dockerfile$/m, "pub.dev excludes Dockerfile"],
    ["clients/dart/.pubignore", /^\.dart_tool\/$/m, "pub.dev excludes local Dart tool state"],
    ["clients/dart/.pubignore", /^pubspec\.lock$/m, "pub.dev excludes app lockfile"],
    ["clients/dart/.pubignore", /^test\.dart$/m, "pub.dev excludes test file"],
    ["clients/dart/.pubignore", /^publish\.sh$/m, "pub.dev excludes publish wrapper"],
    ["scripts/docker-check-new-clients.sh", /run dart dart:stable/, "Docker smoke includes Dart runtime"],
    ["scripts/docker-check-new-clients.sh", /dart pub publish --dry-run/, "Docker smoke runs Dart publish dry-run"],
  ],
  swift: [
    ["Package.swift", /path: "clients\/swift"/, "root SwiftPM manifest points at Swift client"],
    ["Package.swift", /exclude: \["Dockerfile", "Package\.swift", "test\.swift", "publish\.sh"\]/, "root SwiftPM manifest excludes non-runtime files"],
    ["clients/swift/Package.swift", /exclude: \["Dockerfile", "test\.swift", "publish\.sh"\]/, "SwiftPM target excludes non-runtime files"],
    ["scripts/publish-client.sh", /git tag "\$\{PACKAGE_VERSION:\?set PACKAGE_VERSION\}"/, "Swift release uses full semantic version tag"],
    ["scripts/docker-check-new-clients.sh", /run swift swift:6\.0/, "Docker full smoke includes Swift runtime"],
    ["scripts/docker-check-new-clients.sh", /swift package --disable-sandbox --scratch-path \/tmp\/flags2env-swift-build describe --type json/, "Docker full smoke validates SwiftPM manifest"],
    ["scripts/docker-check-new-clients.sh", /swift build --disable-sandbox --scratch-path \/tmp\/flags2env-swift-build -c release/, "Docker full smoke builds SwiftPM package"],
    ["scripts/docker-check-new-clients.sh", /swiftc clients\/swift\/lib\.swift clients\/swift\/test\.swift/, "Docker full smoke compiles Swift client"],
  ],
  elixir: [
    ["clients/elixir/mix.exs", /name: "flags2env_elixir"/, "Elixir Hex package name avoids Erlang package collision"],
    ["clients/elixir/mix.exs", /erlc_paths: \["native"\]/, "Elixir package compiles package-local Erlang module"],
    ["clients/elixir/mix.exs", /"LICENSE"/, "Elixir Hex package includes license file"],
    ["clients/elixir/mix.exs", /"native\/flags2env\.erl"/, "Elixir Hex package includes Erlang facade"],
    ["clients/elixir/mix.exs", /"native\/flags2env_nif\.c"/, "Elixir Hex package includes NIF source"],
    ["clients/elixir/mix.exs", /"native\/parser\.c"/, "Elixir Hex package includes parser source"],
    ["clients/elixir/mix.exs", /"native\/parser\.h"/, "Elixir Hex package includes parser header"],
    ["clients/elixir/README.md", /flags2env_elixir/, "Elixir package README documents Hex package name"],
    ["clients/elixir/LICENSE", /MIT License/, "Elixir package license file"],
    ["clients/elixir/Dockerfile", /clients\/elixir\/native\/parser\.c/, "Elixir Docker smoke builds package-local parser source"],
    ["clients/elixir/test.exs", /System\.at_exit/, "Elixir smoke test removes generated TOML fixture"],
  ],
  erlang: [
    ["clients/erlang/rebar.config", /\{plugins, \[rebar3_hex\]\}/, "Erlang Hex publishing plugin"],
    ["clients/erlang/rebar.config", /\{src_dirs, \["src"\]\}/, "Erlang rebar source directory"],
    ["clients/erlang/src/flags2env.app.src", /\{application, flags2env,/, "Erlang OTP app metadata for Hex package"],
    ["clients/erlang/src/flags2env.app.src", /\{vsn, "0\.1\.0"\}/, "Erlang OTP app version"],
    ["clients/erlang/rebar.config", /\{files, \["src\/flags2env\.erl", "src\/flags2env\.app\.src", "c_src\/flags2env_nif\.c", "c_src\/parser\.c", "c_src\/parser\.h", "rebar\.config", "README\.md", "LICENSE"\]\}/, "Hex package file list"],
    ["clients/erlang/README.md", /Erlang bindings/, "Hex package README"],
    ["clients/erlang/LICENSE", /MIT License/, "Hex package license file"],
    ["clients/erlang/flags2env_test.erl", /file:delete\(Config\)/, "Erlang smoke test removes generated TOML fixture"],
    ["clients/erlang/c_src/flags2env_nif.c", /#include "parser\.h"/, "Erlang NIF includes package-local parser header"],
    ["clients/erlang/Dockerfile", /clients\/erlang\/c_src\/parser\.c/, "Erlang Docker smoke builds package-local parser source"],
    ["scripts/docker-check-new-clients.sh", /run erlang-hex erlang:27/, "Docker smoke includes Erlang Hex package runtime"],
    ["scripts/docker-check-new-clients.sh", /rebar3 hex build package/, "Docker smoke builds Erlang Hex package tarball"],
    ["scripts/docker-check-new-clients.sh", /Erlang Hex package missing/, "Docker smoke verifies required Erlang Hex package files"],
    ["scripts/docker-check-new-clients.sh", /Erlang Hex package includes forbidden local file/, "Docker smoke rejects forbidden Erlang Hex package files"],
  ],
  gleam: [
    ["clients/gleam/gleam.toml", /^repository = /m, "Gleam package repository metadata"],
    ["clients/gleam/gleam.toml", /^licences = \["MIT"\]/m, "Gleam package license metadata"],
    ["clients/gleam/README.md", /Gleam bindings/, "Gleam package README"],
    ["clients/gleam/LICENSE", /MIT License/, "Gleam package license file"],
    ["clients/gleam/Dockerfile", /clients\/erlang\/c_src\/parser\.c/, "Gleam Docker smoke builds package-local parser source"],
    ["scripts/publish-client.sh", /gleam\)[\s\S]*gleam publish --yes/, "Gleam publish uses native Hex publisher"],
  ],
  haskell: [
    ["clients/haskell/flags2env.cabal", /^extra-source-files:/m, "Cabal source manifest controls"],
    ["clients/haskell/flags2env.cabal", /^license-file: LICENSE$/m, "Cabal declares package-local license file"],
    ["clients/haskell/flags2env.cabal", /^  LICENSE$/m, "Cabal sdist includes package-local license file"],
    ["clients/haskell/flags2env.cabal", /^  README\.md$/m, "Cabal sdist includes package-local README file"],
    ["clients/haskell/flags2env.cabal", /^  exposed-modules: Flags2Env/m, "Cabal exposes runtime module"],
    ["clients/haskell/flags2env.cabal", /^test-suite flags2env-smoke$/m, "Cabal exposes smoke test suite"],
    ["clients/haskell/flags2env.cabal", /^  main-is: test\.hs$/m, "Cabal smoke test entrypoint"],
    ["scripts/docker-check-new-clients.sh", /cabal sdist/, "Docker full smoke builds Hackage sdist archive"],
    ["scripts/docker-check-new-clients.sh", /Hackage sdist includes forbidden local file/, "Docker full smoke rejects forbidden Hackage sdist files"],
  ],
  ocaml: [
    ["clients/ocaml/flags2env.opam", /^build: \[/m, "opam build metadata"],
    ["clients/ocaml/flags2env.opam", /\{with-test\}/, "opam test metadata"],
    ["clients/ocaml/README.md", /OCaml bindings/, "opam package README"],
    ["clients/ocaml/LICENSE", /MIT License/, "opam package license file"],
    ["clients/ocaml/dune-project", /\(package/, "OCaml dune package metadata"],
    ["clients/ocaml/dune", /\(test/, "OCaml dune smoke test"],
    ["clients/ocaml/test.ml", /Sys\.remove config_path/, "OCaml smoke test removes generated TOML fixture"],
    ["scripts/docker-check-new-clients.sh", /clients\/ocaml && FLAGS2ENV_NATIVE_LIB=\/work\/build\/libflags2env\.so dune runtest/, "Docker full smoke runs OCaml Dune tests"],
    ["scripts/docker-check-new-clients.sh", /dune install --prefix="\$\(opam var prefix\)" flags2env/, "Docker full smoke installs OCaml package for ReasonML"],
  ],
  reasonml: [
    ["clients/reasonml/flags2env-reason.opam", /^build: \[/m, "opam build metadata"],
    ["clients/reasonml/flags2env-reason.opam", /"reason"/, "ReasonML opam Reason syntax dependency"],
    ["clients/reasonml/flags2env-reason.opam", /"flags2env"/, "ReasonML opam depends on OCaml package"],
    ["clients/reasonml/flags2env-reason.opam", /\{with-test\}/, "ReasonML opam test metadata"],
    ["clients/reasonml/README.md", /ReasonML facade/, "opam package README"],
    ["clients/reasonml/LICENSE", /MIT License/, "opam package license file"],
    ["clients/reasonml/dune-project", /\(name flags2env-reason\)/, "ReasonML Dune package name matches opam file"],
    ["clients/reasonml/src/dune", /\(test/, "ReasonML dune smoke test"],
    ["clients/reasonml/src/Test.re", /Sys\.remove\(configPath\)/, "ReasonML smoke test removes generated TOML fixture"],
    ["scripts/publish-client.sh", /opam lint flags2env-reason\.opam/, "ReasonML publish command lints non-colliding opam file"],
    ["scripts/docker-check-new-clients.sh", /cd \.\.\/reasonml && FLAGS2ENV_NATIVE_LIB=\/work\/build\/libflags2env\.so dune runtest/, "Docker full smoke runs ReasonML Dune tests"],
  ],
  perl: [
    ["clients/perl/Makefile.PL", /LICENSE => 'mit'/, "CPAN declares MIT license"],
    ["clients/perl/README.md", /Perl bindings/, "CPAN package README"],
    ["clients/perl/LICENSE", /MIT License/, "CPAN package license file"],
    ["clients/perl/MANIFEST.SKIP", /^\^blib\//m, "CPAN skips build output"],
    ["clients/perl/MANIFEST.SKIP", /^\^Makefile\$/m, "CPAN skips generated Makefile"],
    ["clients/perl/MANIFEST.SKIP", /^\^MYMETA\\\./m, "CPAN skips generated MYMETA files"],
    ["clients/perl/MANIFEST.SKIP", /^\^publish\\\.sh\$/m, "CPAN skips publish wrapper"],
    ["clients/perl/MANIFEST.SKIP", /^\^test\\\.pl\$/m, "CPAN skips repo-local smoke test"],
    ["scripts/audit-client-packaging.sh", /make dist/, "Client packaging audit builds CPAN dist archive"],
    ["scripts/audit-client-packaging.sh", /Perl CPAN dist includes forbidden file/, "Client packaging audit rejects forbidden CPAN dist files"],
  ],
  lua: [
    ["clients/lua/flags2env-dev-1.rockspec", /^build = \{/m, "LuaRocks build metadata"],
    ["clients/lua/README.md", /LuaJIT FFI bindings/, "LuaRocks package README"],
    ["clients/lua/LICENSE", /MIT License/, "LuaRocks package license file"],
    ["clients/lua/flags2env-dev-1.rockspec", /flags2env = "clients\/lua\/flags2env\.lua"/, "LuaRocks dev module mapping from repository root"],
    ["clients/lua/flags2env-0.1.0-1.rockspec", /^version = "0\.1\.0-1"$/m, "LuaRocks stable version"],
    ["clients/lua/flags2env-0.1.0-1.rockspec", /tag = "v0\.1\.0"/, "LuaRocks stable source tag"],
    ["clients/lua/flags2env-0.1.0-1.rockspec", /flags2env = "clients\/lua\/flags2env\.lua"/, "LuaRocks stable module mapping from repository root"],
    ["clients/lua/test.lua", /os\.remove\(config\)/, "Lua smoke test removes generated TOML fixture"],
    ["scripts/docker-check-new-clients.sh", /luarocks lint clients\/lua\/flags2env-0\.1\.0-1\.rockspec/, "Docker smoke lints stable LuaRocks rockspec"],
    ["scripts/docker-check-new-clients.sh", /luarocks lint clients\/lua\/flags2env-dev-1\.rockspec/, "Docker smoke lints dev LuaRocks rockspec"],
  ],
  nim: [
    ["clients/nim/flags2env.nimble", /^installFiles\s+=\s+@\["flags2env\.nim"\]/m, "Nimble install file list"],
    ["clients/nim/README.md", /Nim bindings/, "Nimble package README"],
    ["clients/nim/LICENSE", /MIT License/, "Nimble package license file"],
    ["clients/nim/test.nim", /import std\/os/, "Nim smoke test imports filesystem cleanup support"],
    ["clients/nim/test.nim", /removeFile\(config\)/, "Nim smoke test removes generated TOML fixture"],
    ["scripts/docker-check-new-clients.sh", /cd clients\/nim && nimble check/, "Docker smoke validates Nimble package metadata"],
  ],
  r: [
    ["clients/r/.Rbuildignore", /^\^Dockerfile\$$/m, "R build excludes Dockerfile"],
    ["clients/r/.Rbuildignore", /^\^publish\\\.sh\$$/m, "R build excludes publish wrapper"],
    ["clients/r/DESCRIPTION", /License: MIT \+ file LICENSE/, "R package declares MIT license file"],
    ["clients/r/LICENSE", /COPYRIGHT HOLDER: ORESoftware/, "R package license template file"],
    ["clients/r/README.md", /R bindings/, "R package README"],
    ["clients/r/src/Makevars", /^OBJECTS = flags2env_r\.o parser\.o$/m, "R package links both the wrapper and package-local parser objects"],
    ["clients/r/src/Makevars", /^PKG_CPPFLAGS = -I\.$/m, "R package resolves its package-local parser header"],
    ["clients/r/man/flags2env.Rd", /\\alias\{parse_flags\}[\s\S]*\\alias\{parse_process\}[\s\S]*\\alias\{apply_flags\}/, "R package documents its exported API"],
    ["clients/r/src/flags2env_r.c", /#include "parser\.h"/, "R staged package includes local parser header"],
    ["clients/r/tests/smoke.R", /parse_flags/, "R package smoke test"],
    ["clients/r/tests/smoke.R", /on\.exit\(unlink\(config\), add = TRUE\)/, "R smoke test removes generated TOML fixture"],
    ["scripts/docker-check-new-clients.sh", /R CMD build clients\/r/, "Docker smoke builds CRAN source package"],
    ["scripts/docker-check-new-clients.sh", /R CMD check --no-manual flags2env_0\.1\.0\.tar\.gz/, "Docker smoke checks CRAN source package"],
    ["scripts/docker-check-new-clients.sh", /R source package missing/, "Docker smoke verifies required R source package files"],
    ["scripts/docker-check-new-clients.sh", /R source package includes forbidden local file/, "Docker smoke rejects forbidden R source package files"],
  ],
  matlab: [
    ["clients/matlab/README.md", /MATLAB bindings use `loadlibrary`/, "MATLAB source-archive usage docs"],
    ["clients/matlab/README.md", /native\/parser\.h/, "MATLAB docs mention package-local loadlibrary header"],
    ["clients/matlab/LICENSE", /MIT License/, "MATLAB source archive license file"],
    ["clients/matlab/+flags2env/defaultHeaderPath.m", /native/, "MATLAB default header path is package-local"],
    ["clients/matlab/+flags2env/ensureLoaded.m", /flags2env\.defaultHeaderPath\(\)/, "MATLAB loader uses package-local default header"],
    ["clients/matlab/test.m", /flags2env\.parse/, "MATLAB smoke test"],
    ["scripts/publish-client.sh", /zip -r flags2env-matlab\.zip \+flags2env native README\.md LICENSE/, "MATLAB publish command archives MATLAB source, native source, README, and license"],
    ["scripts/audit-client-packaging.sh", /MATLAB source archive missing/, "Client packaging audit verifies required MATLAB source archive files"],
    ["scripts/audit-client-packaging.sh", /MATLAB source archive includes forbidden file/, "Client packaging audit rejects forbidden MATLAB source archive files"],
  ],
  julia: [
    ["clients/julia/Project.toml", /^name = "Flags2Env"$/m, "Julia package name"],
    ["clients/julia/Project.toml", /^uuid = "[0-9a-f-]{36}"$/m, "Julia package UUID"],
    ["clients/julia/Project.toml", /^version = "0\.1\.0"$/m, "Julia package version"],
    ["clients/julia/Project.toml", /^\[compat\]/m, "Julia compatibility metadata"],
    ["clients/julia/REGISTRATION.md", /@JuliaRegistrator register subdir=clients\/julia/, "Julia subdir Registrator instruction"],
    ["clients/julia/test/runtests.jl", /atexit/, "Julia smoke test removes generated TOML fixture"],
  ],
  fortran: [
    ["clients/fortran/fpm.toml", /^name = "flags2env"$/m, "fpm package name"],
    ["clients/fortran/fpm.toml", /^version = "0\.1\.0"$/m, "fpm package version"],
    ["clients/fortran/fpm.toml", /^license = "MIT"$/m, "fpm package license metadata"],
    ["clients/fortran/fpm.toml", /^\[library\]/m, "fpm library metadata"],
    ["clients/fortran/fpm.toml", /^\[\[test\]\]/m, "fpm smoke test metadata"],
    ["clients/fortran/fpm.toml", /^source-dir = "src"$/m, "fpm library source directory"],
    ["clients/fortran/fpm.toml", /^main = "test\.f90"$/m, "fpm smoke test entrypoint"],
    ["clients/fortran/README.md", /Fortran bindings/, "fpm package README"],
    ["clients/fortran/LICENSE", /MIT License/, "fpm package license file"],
    ["scripts/docker-check-new-clients.sh", /clients\/fortran\/src\/parser\.c/, "Fortran Docker smoke builds package-local parser source"],
  ],
  zig: [
    ["clients/zig/build.zig.zon", /\.minimum_zig_version = "0\.14\.0"/, "Zig package minimum toolchain version"],
    ["clients/zig/build.zig.zon", /\.paths/, "Zig package manifest path allowlist"],
    ["clients/zig/build.zig.zon", /"test\.zig"/, "Zig package includes its smoke test"],
    ["clients/zig/build.zig.zon", /"README\.md"/, "Zig package includes README"],
    ["clients/zig/build.zig.zon", /"LICENSE"/, "Zig package includes license file"],
    ["clients/zig/build.zig", /b\.addModule\("flags2env"/, "Zig package module"],
    ["clients/zig/build.zig", /b\.step\("test", "Run Zig smoke tests"\)/, "Zig smoke test target"],
    ["clients/zig/build.zig", /native\/parser\.c/, "Zig package builds against package-local C parser"],
    ["clients/zig/build.zig", /b\.path\("native"\)/, "Zig package uses package-local include path"],
    ["clients/zig/README.md", /Zig bindings/, "Zig package README"],
    ["clients/zig/LICENSE", /MIT License/, "Zig package license file"],
    ["scripts/docker-check-new-clients.sh", /run zig kassany\/bookworm-ziglang:0\.14\.0/, "Zig Docker smoke uses the package minimum toolchain"],
  ],
  crystal: [
    ["clients/crystal/shard.yml", /^name: flags2env$/m, "Shard package name"],
    ["clients/crystal/shard.yml", /^version: 0\.1\.0$/m, "Shard package version"],
    ["clients/crystal/shard.yml", /^license: MIT$/m, "Shard package license metadata"],
    ["clients/crystal/shard.yml", /^repository: https:\/\/github\.com\/flags-2-env\/flags-2-env$/m, "Shard package repository metadata"],
    ["clients/crystal/shard.yml", /^crystal: /m, "Shard Crystal version constraint"],
    ["clients/crystal/README.md", /Crystal bindings/, "Shard package README"],
    ["clients/crystal/LICENSE", /MIT License/, "Shard package license file"],
    ["scripts/docker-check-new-clients.sh", /cd clients\/crystal && shards install &&/, "Docker smoke resolves the lockless Crystal library manifest"],
    ["scripts/docker-check-new-clients.sh", /crystal run --link-flags "-L\/work\/build" clients\/crystal\/test\.cr/, "Crystal Docker smoke links the repository-native library explicitly"],
  ],
  solidity: [
    ["clients/solidity/package.json", /"files"\s*:\s*\[[\s\S]*"contracts"[\s\S]*"README\.md"[\s\S]*"LICENSE"[\s\S]*\]/, "Solidity npm package files allowlist"],
    ["clients/solidity/README.md", /Solidity/, "Solidity npm package README"],
    ["clients/solidity/LICENSE", /MIT License/, "Solidity npm package license file"],
    ["clients/solidity/package.json", /"solc":/, "Solidity compiler smoke dependency"],
    ["clients/solidity/package.json", /"overrides"\s*:\s*\{[\s\S]*"tmp": "\^0\.2\.6"/, "Solidity compiler dependency overrides its vulnerable temporary-file helper"],
    ["clients/solidity/package-lock.json", /"node_modules\/tmp"[\s\S]*"version": "0\.2\.[6-9]/, "Solidity compiler lockfile resolves a patched temporary-file helper"],
    ["scripts/docker-check-new-clients.sh", /cd clients\/solidity && npm ci --ignore-scripts && npm audit/, "Solidity Docker smoke uses its lockfile and rejects vulnerable dependencies"],
    ["scripts/docker-check-new-clients.sh", /Solidity npm package missing/, "Docker smoke verifies Solidity npm package files"],
    ["scripts/docker-check-new-clients.sh", /Solidity npm package includes forbidden local file/, "Docker smoke rejects forbidden Solidity npm package files"],
  ],
  bash: [
    ["packaging/homebrew/Formula/flags2env.rb", /clients\/bash\/flags2env\.bash/, "Homebrew installs bash helper"],
    ["packaging/homebrew/Formula/flags2env.rb", /flags2env_apply --debug/, "Homebrew test exercises bash helper"],
    ["scripts/publish-client.sh", /bash\|zsh\)[\s\S]*scripts\/publish-homebrew\.sh --release/, "Bash helper publish wrapper runs Homebrew release checks"],
    ["clients/bash/README.md", /flags2env Bash/, "Bash helper README"],
    ["clients/bash/LICENSE", /MIT License/, "Bash helper license file"],
  ],
  zsh: [
    ["packaging/homebrew/Formula/flags2env.rb", /clients\/zsh\/flags2env\.zsh/, "Homebrew installs zsh helper"],
    ["packaging/homebrew/Formula/flags2env.rb", /assert_path_exists pkgshare\/"shell\/flags2env\.zsh"/, "Homebrew test checks zsh helper installation"],
    ["packaging/homebrew/Formula/flags2env.rb", /zsh-helper-test/, "Homebrew test exercises zsh helper when zsh is available"],
    ["packaging/homebrew/Formula/flags2env.rb", /\/bin\/zsh/, "Homebrew zsh helper test uses the system zsh path"],
    ["scripts/publish-client.sh", /bash\|zsh\)[\s\S]*scripts\/publish-homebrew\.sh --release/, "Zsh helper publish wrapper runs Homebrew release checks"],
    ["clients/zsh/README.md", /flags2env Zsh/, "Zsh helper README"],
    ["clients/zsh/LICENSE", /MIT License/, "Zsh helper license file"],
  ],
};

const forbiddenPackageContent = {
  csharp: [
    ["clients/csharp/Flags2Env.nuspec", /\.\.\/\.\.\/src|\.\.\/\.\.\/clients/, "C# NuGet spec reaches outside package root"],
    ["clients/csharp/Flags2Env.csproj", /\.\.\/\.\.\/src/, "C# project pack item reaches outside package root"],
    ["clients/csharp/Flags2EnvTest.cs", /build\/libflags2env|tests\/fixtures|\.\.\/\.\.\/tests/, "C# smoke test depends on repo build output or fixture tree"],
  ],
  fsharp: [
    ["clients/fsharp/Flags2Env.FSharp.nuspec", /\.\.\/\.\.\/src|\.\.\/\.\.\/clients/, "F# NuGet spec reaches outside package root"],
    ["clients/fsharp/Flags2Env.FSharp.fsproj", /\.\.\/\.\.\/src/, "F# project pack item reaches outside package root"],
    ["clients/fsharp/Flags2EnvTest.fs", /build\/libflags2env|tests\/fixtures|\.\.\/\.\.\/tests/, "F# smoke test depends on repo build output or fixture tree"],
  ],
  elixir: [
    ["clients/elixir/Dockerfile", /COPY src|COPY tests|src\/parser\.c|tests\/fixtures|clients\/erlang/, "Elixir Docker smoke depends on repo source, fixtures, or Erlang client tree"],
    ["clients/elixir/test.exs", /tests\/fixtures|\.\.\/\.\.\/tests|\.\.\/\.cli-flags\.toml/, "Elixir smoke test depends on repo fixture tree"],
  ],
  java: [
    ["clients/java/pom.xml", /\.\.\/\.\.\/src/, "Java Maven package reaches into repo source directory"],
    ["clients/java/native/flags2env_jni.c", /\.\.\/\.\.\/\.\.\/src\/parser\.h/, "JNI source reaches into repo source directory"],
    ["clients/java/Dockerfile", /COPY src|COPY tests|src\/parser\.c/, "Java Docker smoke depends on repo source or fixture tree"],
  ],
  erlang: [
    ["clients/erlang/c_src/flags2env_nif.c", /\.\.\/\.\.\/src\/parser\.h/, "Erlang NIF reaches into repo source directory"],
    ["clients/erlang/Dockerfile", /COPY src|COPY tests|tests\/fixtures/, "Erlang Docker smoke depends on repo source or fixture tree"],
    ["clients/erlang/flags2env_test.erl", /tests\/fixtures|\.\.\/\.\.\/tests/, "Erlang smoke test depends on repo fixture tree"],
  ],
  gleam: [
    ["clients/gleam/Dockerfile", /COPY src|COPY tests|tests\/fixtures/, "Gleam Docker smoke depends on repo source or fixture tree"],
    ["clients/gleam/test.gleam", /\/repo\/tests|tests\/fixtures/, "Gleam smoke test depends on repo fixture tree"],
  ],
  rust: [
    ["clients/rust/Dockerfile", /COPY src|COPY tests|src\/parser\.c|tests\/fixtures|make all|LD_LIBRARY_PATH/, "Rust Docker smoke depends on repo source, fixtures, or build artifacts"],
    ["clients/rust/tests/smoke.rs", /\.\.\/\.\.\/build|tests\/fixtures|\.\.\/\.\.\/tests/, "Rust smoke test depends on repo build output or fixture tree"],
  ],
  cpp: [
    ["clients/cpp/test.cpp", /tests\/fixtures|\.\.\/\.\.\/tests/, "C++ smoke test depends on repo fixture tree"],
  ],
  crystal: [
    ["clients/crystal/test.cr", /tests\/fixtures|\.\.\/\.\.\/tests/, "Crystal smoke test depends on repo fixture tree"],
  ],
  fortran: [
    ["clients/fortran/test.f90", /tests\/fixtures|\.\.\/\.\.\/tests/, "Fortran smoke test depends on repo fixture tree"],
  ],
  haskell: [
    ["clients/haskell/test.hs", /tests\/fixtures|\.\.\/\.\.\/tests/, "Haskell smoke test depends on repo fixture tree"],
  ],
  julia: [
    ["clients/julia/test/runtests.jl", /tests\/fixtures|\.\.\/\.\.\/tests/, "Julia smoke test depends on repo fixture tree"],
  ],
  lua: [
    ["clients/lua/test.lua", /tests\/fixtures|\.\.\/\.\.\/tests/, "Lua smoke test depends on repo fixture tree"],
  ],
  nim: [
    ["clients/nim/test.nim", /tests\/fixtures|\.\.\/\.\.\/tests/, "Nim smoke test depends on repo fixture tree"],
  ],
  ocaml: [
    ["clients/ocaml/test.ml", /tests\/fixtures|\.\.\/\.\.\/tests/, "OCaml smoke test depends on repo fixture tree"],
  ],
  reasonml: [
    ["clients/reasonml/src/Test.re", /tests\/fixtures|\.\.\/\.\.\/tests/, "ReasonML smoke test depends on repo fixture tree"],
  ],
  r: [
    ["clients/r/src/Makevars", /\.\.\/\.\.\/\.\.\/src/, "R Makevars reaches into repository source directory"],
    ["scripts/publish-client.sh", /cp src\/parser\.c src\/parser\.h dist\/r\/src\//, "R publish command stages repository-root parser sources"],
  ],
  matlab: [
    ["clients/matlab/+flags2env/apply.m", /fullfile\(pwd, "src", "parser\.h"\)/, "MATLAB apply uses repo-root parser header default"],
    ["clients/matlab/+flags2env/ensureLoaded.m", /fullfile\(pwd, "src", "parser\.h"\)/, "MATLAB loader uses repo-root parser header default"],
    ["clients/matlab/+flags2env/parse.m", /fullfile\(pwd, "src", "parser\.h"\)/, "MATLAB parse uses repo-root parser header default"],
    ["clients/matlab/+flags2env/parseProcess.m", /fullfile\(pwd, "src", "parser\.h"\)/, "MATLAB parseProcess uses repo-root parser header default"],
    ["clients/matlab/README.md", /tests\/fixtures/, "MATLAB README example depends on repo fixture tree"],
  ],
  zig: [
    ["clients/zig/test.zig", /tests\/fixtures|\.\.\/\.\.\/tests/, "Zig smoke test depends on repo fixture tree"],
  ],
};

const matrix = [
  {
    language: "JavaScript",
    client: "nodejs",
    repository: "npm Registry",
    controls: [".npmignore", "package.json", "clients/nodejs/package.json.ejs", "clients/bun/package.json.ejs", "clients/deno/deno.json", "scripts/render-client.mjs"],
    sources: ["clients/nodejs/lib.mjs", "clients/nodejs/lib.cjs", "clients/nodejs/lib.ts", "clients/nodejs/addon.c"],
    tests: ["clients/nodejs/test.mjs", "clients/nodejs/test.cjs", "clients/nodejs/test.ts"],
    publishIncludes: ["npm publish --access public"],
  },
  {
    language: "Python",
    client: "python",
    repository: "PyPI",
    controls: ["clients/python/MANIFEST.in", "clients/python/pyproject.toml", "clients/python/LICENSE", "scripts/docker-check-new-clients.sh"],
    sources: ["clients/python/lib.py", "clients/python/flags2env.py"],
    tests: ["clients/python/test.py"],
    publishIncludes: ["twine upload"],
  },
  {
    language: "Java",
    client: "java",
    repository: "Maven Central / Sonatype",
    controls: ["clients/java/pom.xml", "scripts/docker-check-new-clients.sh"],
    sources: ["clients/java/src/main/java/com/oresoftware/flags2env/Flags2Env.java", "clients/java/native/flags2env_jni.c", "clients/java/native/parser.c", "clients/java/native/parser.h"],
    tests: ["clients/java/src/test/java/com/oresoftware/flags2env/Flags2EnvTest.java"],
    publishIncludes: ["mvn -P release deploy"],
  },
  {
    language: "Kotlin",
    client: "kotlin",
    repository: "Maven Central / Sonatype",
    controls: ["clients/kotlin/build.gradle.kts", "scripts/docker-check-new-clients.sh"],
    sources: ["clients/kotlin/src/main/kotlin/com/oresoftware/flags2env/Flags2Env.kt"],
    tests: [],
    publishIncludes: ["gradle -Prelease publish", "publish-central-ossrh-compat.sh"],
  },
  {
    language: "Scala",
    client: "scala",
    repository: "Maven Central / Sonatype",
    controls: ["clients/scala/build.sbt", "clients/scala/project/plugins.sbt", "scripts/docker-check-new-clients.sh"],
    sources: ["clients/scala/src/main/scala/com/oresoftware/flags2env/Flags2Env.scala"],
    tests: [],
    publishIncludes: ["sbt publishSigned sonatypeBundleRelease"],
  },
  {
    language: "Groovy",
    client: "groovy",
    repository: "Maven Central / Sonatype",
    controls: ["clients/groovy/build.gradle", "scripts/docker-check-new-clients.sh"],
    sources: ["clients/groovy/src/main/groovy/com/oresoftware/flags2env/Flags2Env.groovy"],
    tests: [],
    publishIncludes: ["gradle -Prelease publish", "publish-central-ossrh-compat.sh"],
  },
  {
    language: "Clojure",
    client: "clojure",
    repository: "Maven Central / Sonatype",
    controls: ["clients/clojure/build.clj", "clients/clojure/deps.edn", "scripts/docker-check-new-clients.sh"],
    sources: ["clients/clojure/src/com/oresoftware/flags2env.clj"],
    tests: [],
    publishIncludes: ["clojure -T:build", "publish-central-ossrh-compat.sh"],
  },
  {
    language: "Rust",
    client: "rust",
    repository: "crates.io",
    controls: ["clients/rust/Cargo.toml", "clients/rust/Dockerfile", "clients/rust/README.md", "clients/rust/LICENSE", "scripts/docker-check-new-clients.sh"],
    sources: ["clients/rust/src/lib.rs", "clients/rust/native/parser.c", "clients/rust/native/parser.h"],
    tests: ["clients/rust/tests/smoke.rs"],
    publishIncludes: ["cargo publish"],
  },
  {
    language: "Go",
    client: "golang",
    repository: "Git repository / pkg.go.dev",
    controls: ["clients/golang/go.mod", "clients/golang/README.md", "clients/golang/LICENSE", "scripts/docker-check-new-clients.sh"],
    sources: ["clients/golang/lib.go", "clients/golang/parser.c", "clients/golang/parser.h"],
    tests: ["clients/golang/lib_test.go"],
    publishIncludes: ["git tag \"clients/golang/v"],
  },
  {
    language: "C",
    client: "c",
    repository: "Git repository / Homebrew source build",
    controls: ["Makefile", "packaging/homebrew/Formula/flags2env.rb", "scripts/publish-client.sh", "clients/c/README.md", "clients/c/LICENSE"],
    sources: ["clients/c/lib.c", "clients/c/lib.h", "src/parser.c", "src/parser.h"],
    tests: ["clients/c/test.c"],
    publishIncludes: ["git tag", "scripts/publish-homebrew.sh --release"],
  },
  {
    language: "C++",
    client: "cpp",
    repository: "Git repository / source archive",
    controls: ["clients/cpp/CMakeLists.txt", "clients/cpp/README.md", "clients/cpp/LICENSE", "scripts/docker-check-new-clients.sh"],
    sources: ["clients/cpp/include/flags2env.hpp", "clients/cpp/native/parser.c", "clients/cpp/native/parser.h"],
    tests: ["clients/cpp/test.cpp"],
    publishIncludes: ["git tag"],
  },
  {
    language: "C#",
    client: "csharp",
    repository: "NuGet Gallery",
    controls: ["clients/csharp/Flags2Env.nuspec", "clients/csharp/Flags2Env.csproj", "clients/csharp/README.md", "scripts/docker-check-new-clients.sh"],
    sources: ["clients/csharp/Flags2Env.cs", "clients/csharp/native/parser.c", "clients/csharp/native/parser.h"],
    tests: ["clients/csharp/Flags2EnvTest.cs"],
    publishIncludes: ["dotnet nuget push"],
  },
  {
    language: "F#",
    client: "fsharp",
    repository: "NuGet Gallery",
    controls: ["clients/fsharp/Flags2Env.FSharp.nuspec", "clients/fsharp/Flags2Env.FSharp.fsproj", "clients/fsharp/README.md", "scripts/docker-check-new-clients.sh"],
    sources: ["clients/fsharp/Flags2Env.fs", "clients/fsharp/native/parser.c", "clients/fsharp/native/parser.h"],
    tests: ["clients/fsharp/Flags2EnvTest.fs"],
    publishIncludes: ["dotnet nuget push"],
  },
  {
    language: "PHP",
    client: "php",
    repository: "Packagist",
    controls: ["clients/php/composer.json", "clients/php/README.md", "clients/php/LICENSE", "scripts/docker-check-new-clients.sh"],
    sources: ["clients/php/lib.php"],
    tests: ["clients/php/test.php"],
    publishIncludes: ["composer archive"],
  },
  {
    language: "Ruby",
    client: "ruby",
    repository: "RubyGems.org",
    controls: ["clients/ruby/flags2env.gemspec", "clients/ruby/README.md", "clients/ruby/LICENSE"],
    sources: ["clients/ruby/lib.rb"],
    tests: ["clients/ruby/test.rb"],
    publishIncludes: ["gem push"],
  },
  {
    language: "Swift",
    client: "swift",
    repository: "Git repository / SwiftPM",
    controls: ["Package.swift", "clients/swift/Package.swift", "scripts/docker-check-new-clients.sh"],
    sources: ["clients/swift/lib.swift"],
    tests: ["clients/swift/test.swift"],
    publishIncludes: ["git tag \"${PACKAGE_VERSION"],
  },
  {
    language: "Dart",
    client: "dart",
    repository: "pub.dev",
    controls: ["clients/dart/pubspec.yaml", "clients/dart/.pubignore", "clients/dart/LICENSE", "clients/dart/README.md", "clients/dart/CHANGELOG.md", "scripts/docker-check-new-clients.sh"],
    sources: ["clients/dart/lib.dart", "clients/dart/lib/flags2env.dart"],
    tests: ["clients/dart/test.dart"],
    publishIncludes: ["dart pub publish"],
  },
  {
    language: "Elixir",
    client: "elixir",
    repository: "Hex.pm",
    controls: ["clients/elixir/mix.exs", "clients/elixir/README.md", "clients/elixir/LICENSE"],
    sources: ["clients/elixir/lib.ex", "clients/elixir/native/flags2env.erl", "clients/elixir/native/flags2env_nif.c", "clients/elixir/native/parser.c", "clients/elixir/native/parser.h"],
    tests: ["clients/elixir/test.exs"],
    publishIncludes: ["mix hex.publish"],
  },
  {
    language: "Erlang",
    client: "erlang",
    repository: "Hex.pm",
    controls: ["clients/erlang/rebar.config", "clients/erlang/src/flags2env.app.src", "clients/erlang/README.md", "clients/erlang/LICENSE", "scripts/docker-check-new-clients.sh"],
    sources: ["clients/erlang/src/flags2env.erl", "clients/erlang/c_src/flags2env_nif.c", "clients/erlang/c_src/parser.c", "clients/erlang/c_src/parser.h"],
    tests: ["clients/erlang/flags2env_test.erl"],
    publishIncludes: ["rebar3 hex publish"],
  },
  {
    language: "Gleam",
    client: "gleam",
    repository: "Hex.pm",
    controls: ["clients/gleam/gleam.toml", "clients/gleam/README.md", "clients/gleam/LICENSE", "scripts/publish-client.sh"],
    sources: ["clients/gleam/src/flags2env.gleam", "clients/gleam/src/flags2env_native.erl"],
    tests: ["clients/gleam/test.gleam"],
    publishIncludes: ["gleam publish --yes"],
  },
  {
    language: "Haskell",
    client: "haskell",
    repository: "Hackage",
    controls: ["clients/haskell/flags2env.cabal", "clients/haskell/LICENSE", "scripts/docker-check-new-clients.sh"],
    sources: ["clients/haskell/src/Flags2Env.hs"],
    tests: ["clients/haskell/test.hs"],
    publishIncludes: ["cabal upload"],
  },
  {
    language: "OCaml",
    client: "ocaml",
    repository: "opam Repository",
    controls: ["clients/ocaml/flags2env.opam", "clients/ocaml/dune-project", "clients/ocaml/dune", "clients/ocaml/README.md", "clients/ocaml/LICENSE"],
    sources: ["clients/ocaml/lib/flags2env.ml"],
    tests: ["clients/ocaml/test.ml"],
    publishIncludes: ["opam publish submit"],
  },
  {
    language: "ReasonML",
    client: "reasonml",
    repository: "opam Repository",
    controls: ["clients/reasonml/flags2env-reason.opam", "clients/reasonml/dune-project", "clients/reasonml/src/dune", "clients/reasonml/README.md", "clients/reasonml/LICENSE"],
    sources: ["clients/reasonml/src/Flags2Env.re"],
    tests: ["clients/reasonml/src/Test.re"],
    publishIncludes: ["opam publish submit"],
  },
  {
    language: "Perl",
    client: "perl",
    repository: "CPAN",
    controls: ["clients/perl/Makefile.PL", "clients/perl/MANIFEST.SKIP", "clients/perl/LICENSE", "clients/perl/README.md", "scripts/audit-client-packaging.sh"],
    sources: ["clients/perl/lib/Flags2Env.pm"],
    tests: ["clients/perl/test.pl"],
    publishIncludes: ["cpan-upload"],
  },
  {
    language: "Lua",
    client: "lua",
    repository: "LuaRocks Repository",
    controls: ["clients/lua/flags2env-dev-1.rockspec", "clients/lua/flags2env-0.1.0-1.rockspec", "clients/lua/README.md", "clients/lua/LICENSE", "scripts/docker-check-new-clients.sh"],
    sources: ["clients/lua/flags2env.lua"],
    tests: ["clients/lua/test.lua"],
    publishIncludes: ["luarocks upload"],
  },
  {
    language: "Nim",
    client: "nim",
    repository: "Nimble Package Index",
    controls: ["clients/nim/flags2env.nimble", "clients/nim/README.md", "clients/nim/LICENSE", "scripts/docker-check-new-clients.sh"],
    sources: ["clients/nim/flags2env.nim"],
    tests: ["clients/nim/test.nim"],
    publishIncludes: ["nimble publish"],
  },
  {
    language: "R",
    client: "r",
    repository: "CRAN / R-universe",
    controls: ["clients/r/DESCRIPTION", "clients/r/.Rbuildignore", "clients/r/README.md", "clients/r/LICENSE", "scripts/docker-check-new-clients.sh"],
    sources: ["clients/r/R/flags2env.R", "clients/r/src/flags2env_r.c", "clients/r/src/parser.c", "clients/r/src/parser.h"],
    tests: ["clients/r/tests/smoke.R"],
    publishIncludes: ["submit_cran"],
  },
  {
    language: "MATLAB",
    client: "matlab",
    repository: "Source archive / Git repository",
    controls: ["clients/matlab/README.md", "clients/matlab/LICENSE", "scripts/publish-client.sh", "scripts/audit-client-packaging.sh"],
    sources: [
      "clients/matlab/+flags2env/parse.m",
      "clients/matlab/+flags2env/apply.m",
      "clients/matlab/+flags2env/defaultHeaderPath.m",
      "clients/matlab/native/parser.c",
      "clients/matlab/native/parser.h",
    ],
    tests: ["clients/matlab/test.m"],
    publishIncludes: ["zip -r flags2env-matlab.zip"],
  },
  {
    language: "Julia",
    client: "julia",
    repository: "Julia General Registry",
    controls: ["clients/julia/Project.toml", "clients/julia/LICENSE", "clients/julia/README.md", "clients/julia/REGISTRATION.md"],
    sources: ["clients/julia/src/Flags2Env.jl"],
    tests: ["clients/julia/test/runtests.jl"],
    publishIncludes: ["Registrator"],
  },
  {
    language: "Fortran",
    client: "fortran",
    repository: "Git repository / fpm package",
    controls: ["clients/fortran/fpm.toml", "clients/fortran/README.md", "clients/fortran/LICENSE"],
    sources: ["clients/fortran/src/flags2env.f90", "clients/fortran/src/parser.c", "clients/fortran/src/parser.h"],
    tests: ["clients/fortran/test.f90"],
    publishIncludes: ["git tag"],
  },
  {
    language: "Zig",
    client: "zig",
    repository: "Git repository / Zig package",
    controls: ["clients/zig/build.zig", "clients/zig/build.zig.zon", "clients/zig/README.md", "clients/zig/LICENSE"],
    sources: ["clients/zig/src/flags2env.zig", "clients/zig/native/parser.c", "clients/zig/native/parser.h"],
    tests: ["clients/zig/test.zig"],
    publishIncludes: ["git tag"],
  },
  {
    language: "Crystal",
    client: "crystal",
    repository: "Git repository / Shards",
    controls: ["clients/crystal/shard.yml", "clients/crystal/README.md", "clients/crystal/LICENSE", "scripts/docker-check-new-clients.sh"],
    sources: ["clients/crystal/src/flags2env.cr"],
    tests: ["clients/crystal/test.cr"],
    publishIncludes: ["git tag"],
  },
  {
    language: "Solidity",
    client: "solidity",
    repository: "npm Registry",
    controls: ["clients/solidity/package.json", "clients/solidity/README.md", "clients/solidity/LICENSE", "scripts/docker-check-new-clients.sh"],
    sources: ["clients/solidity/contracts/Flags2Env.sol"],
    tests: ["clients/solidity/package.json"],
    publishIncludes: ["npm publish --access public"],
  },
  {
    language: "Bash",
    client: "bash",
    repository: "Homebrew / Git repository",
    controls: ["packaging/homebrew/Formula/flags2env.rb", "scripts/publish-client.sh", "clients/bash/README.md", "clients/bash/LICENSE"],
    sources: ["clients/bash/flags2env.bash"],
    tests: ["clients/bash/test.bash"],
    publishIncludes: ["scripts/publish-homebrew.sh --release"],
  },
  {
    language: "Zsh",
    client: "zsh",
    repository: "Homebrew / Git repository",
    controls: ["packaging/homebrew/Formula/flags2env.rb", "scripts/publish-client.sh", "clients/zsh/README.md", "clients/zsh/LICENSE"],
    sources: ["clients/zsh/flags2env.zsh"],
    tests: ["clients/zsh/test.zsh"],
    publishIncludes: ["scripts/publish-homebrew.sh --release"],
  },
  {
    language: "Oreslang",
    client: "oreslang",
    repository: "Git repository / source archive",
    controls: [
      "clients/oreslang/.ores.pkg.toml",
      "clients/oreslang/README.md",
      "clients/oreslang/LICENSE",
      "contracts/oreslang-client-backends.v1.json",
    ],
    sources: [
      "clients/oreslang/src/flags2env.ores",
      "clients/oreslang/native/flags2env_ores_bridge.c",
      "clients/oreslang/native/flags2env_ores_bridge.h",
      "clients/oreslang/native/parser.c",
      "clients/oreslang/native/parser.h",
    ],
    tests: [
      "clients/oreslang/tests/client_contract.ores",
      "clients/oreslang/tests/abi-status-scalar.ores",
      "clients/oreslang/tests/source_contract.mjs",
      "clients/oreslang/native/bridge_test.c",
      "clients/oreslang/native/bridge_fault_test.c",
    ],
    publishIncludes: ["git tag \"clients/oreslang/v"],
  },
];

let failures = 0;

function requirePath(entry, kind, path) {
  if (!existsSync(join(root, path))) {
    console.error(`${entry.language}: missing ${kind}: ${path}`);
    failures++;
  }
}

function readText(entry, path) {
  const fullPath = join(root, path);
  if (!existsSync(fullPath)) {
    console.error(`${entry.language}: missing package control: ${path}`);
    failures++;
    return "";
  }
  return readFileSync(fullPath, "utf8");
}

function requirePackageControls(entry) {
  const checks = packageControls[entry.client] || [];
  for (const [path, pattern, description] of checks) {
    const text = readText(entry, path);
    if (text && !pattern.test(text)) {
      console.error(`${entry.language}: package control failed (${description}) in ${path}`);
      failures++;
    }
  }
}

function forbidPackageContent(entry) {
  const checks = forbiddenPackageContent[entry.client] || [];
  for (const [path, pattern, description] of checks) {
    const text = readText(entry, path);
    if (text && pattern.test(text)) {
      console.error(`${entry.language}: forbidden package content (${description}) in ${path}`);
      failures++;
    }
  }
}

function requireMatrixCompleteness() {
  const seen = new Map();
  for (const entry of matrix) {
    if (seen.has(entry.client)) {
      console.error(`${entry.language}: duplicate client entry also used by ${seen.get(entry.client)}`);
      failures++;
    }
    seen.set(entry.client, entry.language);
  }

  for (const client of requiredClients) {
    if (!seen.has(client)) {
      console.error(`missing required client in release matrix: ${client}`);
      failures++;
    }
    if (!packageControls[client]) {
      console.error(`missing package-control assertions for required client: ${client}`);
      failures++;
    }
  }

  for (const entry of matrix) {
    const expected = expectedRepositories[entry.client];
    if (expected && entry.repository !== expected) {
      console.error(`${entry.language}: expected repository "${expected}", got "${entry.repository}"`);
      failures++;
    }
  }
}

function dryRunPublish(entry) {
  const result = spawnSync(`clients/${entry.client}/publish.sh`, ["--dry-run"], {
    cwd: root,
    encoding: "utf8",
  });
  if (result.status !== 0) {
    console.error(`${entry.language}: publish dry-run failed`);
    process.stderr.write(result.stderr);
    failures++;
    return;
  }
  for (const expected of entry.publishIncludes) {
    if (!result.stdout.includes(expected)) {
      console.error(`${entry.language}: publish dry-run missing "${expected}"`);
      failures++;
    }
  }
}

requireMatrixCompleteness();

for (const entry of matrix) {
  requirePath(entry, "client directory", `clients/${entry.client}`);
  requirePath(entry, "publish wrapper", `clients/${entry.client}/publish.sh`);
  for (const path of entry.controls) {
    requirePath(entry, "package control", path);
  }
  for (const path of entry.sources) {
    requirePath(entry, "source", path);
  }
  for (const path of entry.tests) {
    requirePath(entry, "test", path);
  }
  requirePackageControls(entry);
  forbidPackageContent(entry);
  dryRunPublish(entry);
}

if (failures > 0) {
  console.error(`release matrix audit failed with ${failures} issue(s)`);
  process.exit(1);
}

console.log(`release matrix audit passed (${matrix.length} entries)`);
