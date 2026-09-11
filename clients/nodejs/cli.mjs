#!/usr/bin/env node
import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, join } from "node:path";
import {
  auditConfig,
  auditConfigStatus,
  auditEnv,
  auditEnvStatus,
  completionScript,
  generateTypes,
  parse,
} from "./lib.mjs";

function usage(stream = process.stderr) {
  stream.write(
    "usage:\n" +
      "  f2e [argv...]\n" +
      "  f2e audit [config]\n" +
      "  f2e audit env [config] [env]\n" +
      "  f2e generate <language> [config] [--name TypeName]\n" +
      "  f2e completion <bash|zsh> <command> [config]\n" +
      "  f2e completion install <bash|zsh> <command> [config]\n",
  );
}

function runGenerate(args) {
  if (args.length === 0 || args[0] === "--help" || args[0] === "-h") {
    usage(args.length === 0 ? process.stderr : process.stdout);
    return args.length === 0 ? 2 : 0;
  }

  const language = args[0];
  let configPath;
  let typeName;
  for (let index = 1; index < args.length; index += 1) {
    const token = args[index];
    if (token === "--name" || token === "-n") {
      if (index + 1 >= args.length) {
        usage();
        return 2;
      }
      typeName = args[index += 1];
      continue;
    }
    if (token.startsWith("--name=")) {
      typeName = token.slice("--name=".length);
      continue;
    }
    if (token === "--config" || token === "-c") {
      if (index + 1 >= args.length) {
        usage();
        return 2;
      }
      configPath = args[index += 1];
      continue;
    }
    if (token.startsWith("--config=")) {
      configPath = token.slice("--config=".length);
      continue;
    }
    if (token.startsWith("-") || configPath) {
      usage();
      return 2;
    }
    configPath = token;
  }

  process.stdout.write(generateTypes(language, { configPath, typeName }));
  return 0;
}

function printJson(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}

function safeName(command) {
  return basename(command || "flags2env").replace(/[^A-Za-z0-9_.-]/g, "_") || "flags2env";
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, "'\\''")}'`;
}

function completionDir(shell) {
  if (shell === "bash") {
    if (process.env.F2E_BASH_COMPLETION_DIR) {
      return process.env.F2E_BASH_COMPLETION_DIR;
    }
    if (process.env.F2E_COMPLETION_DIR) {
      return process.env.F2E_COMPLETION_DIR;
    }
    if (process.env.XDG_DATA_HOME) {
      return join(process.env.XDG_DATA_HOME, "bash-completion", "completions");
    }
    return join(homedir(), ".local", "share", "bash-completion", "completions");
  }
  if (shell === "zsh") {
    if (process.env.F2E_ZSH_COMPLETION_DIR) {
      return process.env.F2E_ZSH_COMPLETION_DIR;
    }
    if (process.env.F2E_COMPLETION_DIR) {
      return process.env.F2E_COMPLETION_DIR;
    }
    return join(process.env.ZDOTDIR || homedir(), ".zfunc");
  }
  throw new Error(`unsupported completion shell: ${shell}`);
}

function rcPath(shell) {
  if (shell === "bash") {
    return process.env.F2E_BASHRC || join(homedir(), ".bashrc");
  }
  if (shell === "zsh") {
    return process.env.F2E_ZSHRC || join(process.env.ZDOTDIR || homedir(), ".zshrc");
  }
  throw new Error(`unsupported completion shell: ${shell}`);
}

function appendOnce(path, marker, block) {
  const existing = existsSync(path) ? readFileSync(path, "utf8") : "";
  if (!existing.includes(marker)) {
    appendFileSync(path, block);
  }
}

function installCompletion(shell, command, configPath) {
  const script = completionScript(shell, command, { configPath });
  const commandName = safeName(command);
  const dir = completionDir(shell);
  const fileName = shell === "zsh" ? `_${commandName}` : commandName;
  const outPath = join(dir, fileName);
  mkdirSync(dir, { recursive: true });
  writeFileSync(outPath, script);

  const marker = `# flags2env completion: ${shell} ${commandName}`;
  const rc = rcPath(shell);
  if (shell === "bash") {
    appendOnce(rc, marker, `\n${marker}\n[ -f ${shellQuote(outPath)} ] && . ${shellQuote(outPath)}\n`);
  } else {
    appendOnce(
      rc,
      marker,
      `\n${marker}\nif [ -d ${shellQuote(dir)} ]; then\n  fpath=(${shellQuote(dir)} $fpath)\n  autoload -Uz compinit\n  compinit\nfi\n`,
    );
  }

  process.stdout.write(`Installed ${shell} completion for ${commandName} to ${outPath}\n`);
}

function main(argv) {
  const [command, ...rest] = argv;
  let parsedForCli;

  if (["generate", "gen", "codegen"].includes(command)) {
    return runGenerate(rest);
  }

  if (command) {
    parsedForCli = parse([process.argv[1], ...argv]);
    if (parsedForCli.isHelpMenu) {
      parsedForCli.printTable();
      return 0;
    }
  }

  if (!command || command === "help" || command === "-h") {
    usage(process.stdout);
    return 0;
  }

  if (command === "audit" || command === "--audit") {
    if (rest[0] === "env" || rest[0] === "--env") {
      const report = auditEnv({ configPath: rest[1], envPath: rest[2] });
      printJson(report);
      return auditEnvStatus({ configPath: rest[1], envPath: rest[2] });
    }
    const configPath = rest[0] === "config" ? rest[1] : rest[0];
    const report = auditConfig({ configPath });
    printJson(report);
    return auditConfigStatus({ configPath });
  }

  if (["env-audit", "audit-env", "env-check"].includes(command)) {
    const report = auditEnv({ configPath: rest[0], envPath: rest[1] });
    printJson(report);
    return auditEnvStatus({ configPath: rest[0], envPath: rest[1] });
  }

  if (["completion", "completions", "autocomplete"].includes(command)) {
    if (rest[0] === "install") {
      if (rest.length < 3) {
        usage();
        return 2;
      }
      installCompletion(rest[1], rest[2], rest[3]);
      return 0;
    }
    if (rest.length < 2) {
      usage();
      return 2;
    }
    process.stdout.write(completionScript(rest[0], rest[1], { configPath: rest[2] }));
    return 0;
  }

  if (["install-completion", "install-autocomplete"].includes(command)) {
    if (rest.length < 2) {
      usage();
      return 2;
    }
    installCompletion(rest[0], rest[1], rest[2]);
    return 0;
  }

  printJson(parsedForCli || parse([process.argv[1], ...argv]));
  return 0;
}

try {
  process.exitCode = main(process.argv.slice(2));
} catch (error) {
  process.stderr.write(`f2e: ${error.message}\n`);
  process.exitCode = 1;
}
