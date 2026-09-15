#!/usr/bin/env python3
"""Verify flags2env help and Bash/Zsh completion against one TOML contract."""

from __future__ import annotations

import argparse
import errno
import fcntl
import os
import pty
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import termios
import tomllib
import unicodedata
from pathlib import Path
from typing import Any, Iterator

SAFE_COMMAND = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$")
ANSI_ESCAPE = re.compile(r"\x1b(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])")
BOX_DRAWING = re.compile(r"[\u2500-\u257f]")


def die(message: str) -> int:
    print(f"flags2env shell contract: {message}", file=sys.stderr)
    return 1


def command_basename(command: str) -> str:
    base = re.split(r"[/\\]", command.rstrip("/\\"))[-1]
    if not SAFE_COMMAND.fullmatch(base):
        raise ValueError(f"unsafe command name: {command!r}")
    return base


def run(
    argv: list[str],
    cwd: Path,
    env: dict[str, str],
    stdin: str | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        argv,
        cwd=cwd,
        env=env,
        input=stdin,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def terminal_help(
    cli: Path,
    command: str,
    scope: tuple[str, ...],
    cwd: Path,
    env: dict[str, str],
    columns: int,
) -> tuple[int, str]:
    child_env = dict(env)
    child_env.update(COLUMNS=str(columns), LINES="40")
    argv = [str(cli), command, *scope, "--help"]
    pid, master = pty.fork()
    if pid == 0:
        try:
            fcntl.ioctl(
                1,
                termios.TIOCSWINSZ,
                struct.pack("HHHH", 40, columns, 0, 0),
            )
            os.chdir(cwd)
            os.execve(str(cli), argv, child_env)
        except BaseException as error:  # pragma: no cover
            print(f"exec failed: {error}", file=sys.stderr)
            os._exit(127)

    chunks: list[bytes] = []
    try:
        while True:
            try:
                chunk = os.read(master, 65536)
            except OSError as error:
                if error.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            chunks.append(chunk)
    finally:
        os.close(master)
    _, status = os.waitpid(pid, 0)
    return os.waitstatus_to_exitcode(status), b"".join(chunks).decode(
        "utf-8", "replace"
    )


def scopes(
    config: dict[str, Any], path: tuple[str, ...] = ()
) -> Iterator[tuple[str, ...]]:
    yield path
    commands = config.get("commands", {})
    if not isinstance(commands, dict):
        return
    for name, command in commands.items():
        if isinstance(name, str) and isinstance(command, dict):
            yield from scopes(command, (*path, name))


def at_scope(root: dict[str, Any], path: tuple[str, ...]) -> dict[str, Any]:
    current = root
    for name in path:
        commands = current.get("commands", {})
        if not isinstance(commands, dict) or not isinstance(commands.get(name), dict):
            raise ValueError(f"invalid command scope: {' '.join(path)}")
        current = commands[name]
    return current


def option_names(name: str, spec: dict[str, Any]) -> list[str]:
    aliases = spec.get("aliases")
    long_names = (
        [value for value in aliases if isinstance(value, str) and value]
        if isinstance(aliases, list)
        else []
    )
    if not long_names:
        long_names = [name.replace("_", "-")]
    result = [f"--{value}" for value in long_names]
    short = spec.get("short")
    if isinstance(short, str) and len(short) == 1:
        result.append(f"-{short}")
    return result


def visible_flags(
    root: dict[str, Any], path: tuple[str, ...]
) -> list[tuple[list[str], str | None]]:
    containers = [at_scope(root, path[:index]) for index in range(len(path), 0, -1)] + [
        root
    ]
    global_table = root.get("global", {})
    if isinstance(global_table, dict):
        containers.append(global_table)

    result: list[tuple[list[str], str | None]] = []
    claimed: set[str] = set()
    for container in containers:
        table = container.get("flags", {})
        if not isinstance(table, dict):
            continue
        for name, spec in table.items():
            if not isinstance(name, str) or not isinstance(spec, dict):
                continue
            names = option_names(name, spec)
            if names[0] in claimed:
                continue
            claimed.add(names[0])
            description = spec.get("help", spec.get("description"))
            result.append(
                (
                    names,
                    description
                    if isinstance(description, str) and description
                    else None,
                )
            )
    return result


def normalized(value: str) -> str:
    value = ANSI_ESCAPE.sub(" ", value)
    value = BOX_DRAWING.sub(" ", value)
    value = value.replace("|", " ").replace("\r", " ")
    return re.sub(r"\s+", " ", value).strip()


def semantic_tokens(value: str) -> list[str]:
    # Terminal renderers may vary spacing around punctuation when columns wrap
    # (for example `sql | json`, `machine-readable`, or `CI/AI`). Keep the
    # exact normalized substring as the strongest check, then compare ordered
    # semantic tokens within the already-isolated description column.
    text = unicodedata.normalize("NFC", normalized(value))
    # Preserve Unicode words and symbols such as currency and lock glyphs.
    # Dropping every non-ASCII character makes missing multilingual help pass.
    return [
        token.casefold()
        for token in re.findall(r"[^\W_]+|[^\w\s]", text)
        if any(unicodedata.category(char)[0] in "LMNS" for char in token)
    ]


def description_matches(expected: str, rendered_column: str) -> bool:
    exact = normalized(expected)
    if exact in rendered_column:
        return True
    expected_tokens = semantic_tokens(expected)
    if not expected_tokens:
        return False
    rendered_tokens = iter(semantic_tokens(rendered_column))
    return all(
        any(candidate == token for candidate in rendered_tokens)
        for token in expected_tokens
    )


def terminal_cells(line: str) -> list[str]:
    """Index table borders by terminal cells rather than Python characters."""
    cells: list[str] = []
    for char in line:
        codepoint = ord(char)
        if unicodedata.category(char) in {"Mn", "Me"} or codepoint in {0x200B, 0x200C, 0x200D}:
            if cells:
                cells[-1] += char
            continue
        cells.append(char)
        if unicodedata.east_asian_width(char) in {"W", "F"} or 0x1F300 <= codepoint <= 0x1FAFF:
            cells.append("")
    return cells


def table_column(output: str, headers: set[str]) -> str:
    """Reconstruct one rendered table column across terminal-wrapped rows.

    flags2env supports compact two-column help as well as caller-selected four-
    and five-column layouts. Long values can wrap independently in adjacent
    columns, so searching the normalized whole table can interleave unrelated
    text. Locate the requested header dynamically and concatenate only that
    cell from every continuation row.
    """

    clean = ANSI_ESCAPE.sub("", output).replace("│", "|").replace("\r", "")
    bounds: tuple[int, int] | None = None
    fragments: list[str] = []
    for line in clean.splitlines():
        if bounds is None:
            for header in headers:
                header_index = line.find(header)
                if header_index < 0:
                    continue
                left = line.rfind("|", 0, header_index)
                right = line.find("|", header_index + len(header))
                if left >= 0 and right > left:
                    bounds = (left + 1, right)
                    break
            continue
        start, end = bounds
        cells = terminal_cells(line)
        if len(cells) <= end or cells[start - 1] != "|" or cells[end] != "|":
            continue
        value = "".join(cells[start:end]).strip()
        if value and value not in headers:
            fragments.append(value)
    return normalized(" ".join(fragments))


def check_help(
    cli: Path,
    command: str,
    contract: Path,
    root: dict[str, Any],
    env: dict[str, str],
) -> None:
    for scope in scopes(root):
        label = " ".join((command, *scope))
        for columns in (132, 70):
            status, output = terminal_help(
                cli, command, scope, contract.parent, env, columns
            )
            if status != 0:
                raise RuntimeError(
                    f"{label} --help exited {status} at COLUMNS={columns}:\n{output}"
                )
            if "Option(s)" not in output:
                raise RuntimeError(f"{label} --help has no options table:\n{output}")
            if output.lstrip().startswith("{") or '{"' in output:
                raise RuntimeError(f"{label} --help printed JSON:\n{output}")

            option_column = table_column(output, {"Option(s)"}).replace(" ", "")
            description_column = table_column(output, {"Description", "Details"})
            for names, description in visible_flags(root, scope):
                if not any(name in option_column for name in names):
                    raise RuntimeError(f"{label} --help omitted {names}:\n{output}")
                if description and not description_matches(
                    description, description_column
                ):
                    raise RuntimeError(
                        f"{label} --help omitted description {description!r}; "
                        f"rendered description column was {description_column!r}:\n{output}"
                    )


def completion_tokens(root: dict[str, Any]) -> list[str]:
    result = [name for names, _ in visible_flags(root, ()) for name in names]
    commands = root.get("commands", {})
    if isinstance(commands, dict):
        for name, command in commands.items():
            if isinstance(name, str):
                result.append(name)
            aliases = command.get("aliases") if isinstance(command, dict) else None
            if isinstance(aliases, list):
                result.extend(value for value in aliases if isinstance(value, str))
    return result


def check_bash(
    script: str,
    command: str,
    expected: list[str],
    cwd: Path,
    env: dict[str, str],
    path: Path,
) -> None:
    path.write_text(script, encoding="utf-8")
    syntax = run(["bash", "-n", str(path)], cwd, env)
    if syntax.returncode:
        raise RuntimeError(f"invalid Bash completion syntax:\n{syntax.stderr}")
    probe = r'''
set -euo pipefail
source "$COMPLETION_FILE"
spec="$(complete -p -- "$COMMAND_NAME")"
[[ "$spec" =~ -F[[:space:]]+([^[:space:]]+) ]]
fn="${BASH_REMATCH[1]}"
COMP_WORDS=("$COMMAND_NAME" "-")
COMP_CWORD=1
COMP_LINE="$COMMAND_NAME -"
COMP_POINT="${#COMP_LINE}"
COMPREPLY=()
"$fn"
printf '%s\n' "${COMPREPLY[@]}"
'''
    probe_env = dict(env)
    probe_env.update(COMPLETION_FILE=str(path), COMMAND_NAME=command)
    result = run(["bash", "--noprofile", "--norc", "-c", probe], cwd, probe_env)
    if result.returncode:
        raise RuntimeError(
            f"Bash completion failed to register/execute:\n{result.stdout}{result.stderr}"
        )
    if expected and not any(token in result.stdout.splitlines() for token in expected):
        raise RuntimeError(
            f"Bash completion returned none of {expected!r}:\n{result.stdout}"
        )


def check_zsh(
    script: str,
    command: str,
    expected: list[str],
    cwd: Path,
    env: dict[str, str],
    directory: Path,
) -> None:
    zsh = shutil.which("zsh")
    if not zsh:
        raise RuntimeError("zsh is required")
    function = f"_{command_basename(command)}"
    path = directory / function
    path.write_text(script, encoding="utf-8")
    syntax = run([zsh, "-n", str(path)], cwd, env)
    if syntax.returncode:
        raise RuntimeError(f"invalid Zsh completion syntax:\n{syntax.stderr}")
    probe = r'''
set -eu
fpath=("$COMPLETION_DIR" $fpath)
autoload -Uz compinit
compinit -i -d "$ZCOMPDUMP"
registered="${_comps[$COMMAND_NAME]-}"
[[ -n "$registered" ]]
autoload +X "$registered"
[[ -n "${functions[$registered]-}" ]]
'''
    probe_env = dict(env)
    probe_env.update(
        COMPLETION_DIR=str(directory),
        COMMAND_NAME=command,
        ZCOMPDUMP=str(directory / ".zcompdump"),
    )
    result = run([zsh, "-f", "-c", probe], cwd, probe_env)
    if result.returncode:
        raise RuntimeError(
            f"Zsh completion failed to register/autoload:\n{result.stdout}{result.stderr}"
        )
    if expected and not any(token in script for token in expected):
        raise RuntimeError(
            f"Zsh completion omitted all declared candidates {expected!r}"
        )


def check_install(
    cli: Path,
    command: str,
    contract: Path,
    env: dict[str, str],
    home: Path,
) -> None:
    home.mkdir()
    bash_dir, zsh_dir = home / "bash", home / "zfunc"
    bashrc, zshrc = home / ".bashrc", home / ".zshrc"
    install_env = dict(env)
    install_env.update(
        HOME=str(home),
        ZDOTDIR=str(home),
        F2E_BASH_COMPLETION_DIR=str(bash_dir),
        F2E_ZSH_COMPLETION_DIR=str(zsh_dir),
        F2E_BASHRC=str(bashrc),
        F2E_ZSHRC=str(zshrc),
    )
    for shell in ("bash", "zsh"):
        for _ in range(2):
            result = run(
                [
                    str(cli),
                    "completion",
                    "install",
                    shell,
                    command,
                    str(contract),
                ],
                contract.parent,
                install_env,
            )
            if result.returncode or "Installed" not in result.stdout:
                raise RuntimeError(
                    f"{shell} completion install failed:\n{result.stdout}{result.stderr}"
                )

    safe = command_basename(command)
    if not (bash_dir / safe).is_file() or not (zsh_dir / f"_{safe}").is_file():
        raise RuntimeError("completion install did not create both shell files")
    if bashrc.read_text().count(f"# flags2env completion: bash {safe}") != 1:
        raise RuntimeError("Bash completion install is not idempotent")
    if zshrc.read_text().count(f"# flags2env completion: zsh {safe}") != 1:
        raise RuntimeError("Zsh completion install is not idempotent")

    bash_env = dict(install_env)
    bash_env.update(RC=str(bashrc), COMMAND=command)
    if run(
        [
            "bash",
            "--noprofile",
            "--norc",
            "-c",
            'source "$RC"; complete -p -- "$COMMAND"',
        ],
        contract.parent,
        bash_env,
    ).returncode:
        raise RuntimeError("installed Bash completion is not registered")

    zsh = shutil.which("zsh")
    if not zsh or run([zsh, "-n", str(zshrc)], contract.parent, install_env).returncode:
        raise RuntimeError("installed Zsh rc snippet is not valid syntax")
    zsh_env = dict(install_env)
    zsh_env.update(
        COMPLETION_DIR=str(zsh_dir),
        COMMAND=command,
        ZCOMPDUMP=str(home / ".zcompdump"),
    )
    zsh_probe = (
        'fpath=("$COMPLETION_DIR" $fpath); autoload -Uz compinit; '
        'compinit -i -d "$ZCOMPDUMP"; [[ -n "${_comps[$COMMAND]-}" ]]'
    )
    if run([zsh, "-f", "-c", zsh_probe], contract.parent, zsh_env).returncode:
        raise RuntimeError("installed Zsh completion is not registered")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", required=True)
    parser.add_argument("--contract", required=True)
    parser.add_argument("--command", required=True)
    parser.add_argument("--install", action="store_true")
    args = parser.parse_args()

    cli, contract = Path(args.cli).resolve(), Path(args.contract).resolve()
    try:
        command_basename(args.command)
        if not cli.is_file() or not contract.is_file():
            raise ValueError(f"missing CLI or contract: {cli}, {contract}")
        with contract.open("rb") as handle:
            root = tomllib.load(handle)
    except (ValueError, OSError, tomllib.TOMLDecodeError) as error:
        return die(str(error))

    env = dict(os.environ)
    env["FLAGS2ENV_CONFIG"] = str(contract)
    audit = run([str(cli), "audit", str(contract)], contract.parent, env)
    if audit.returncode:
        return die(f"contract audit failed:\n{audit.stdout}{audit.stderr}")

    try:
        with tempfile.TemporaryDirectory(prefix="flags2env-shell-") as raw:
            temp = Path(raw)
            check_help(cli, args.command, contract, root, env)
            expected = completion_tokens(root)
            bash = run(
                [str(cli), "completion", "bash", args.command, str(contract)],
                contract.parent,
                env,
            )
            zsh = run(
                [str(cli), "completion", "zsh", args.command, str(contract)],
                contract.parent,
                env,
            )
            if bash.returncode or zsh.returncode:
                raise RuntimeError(
                    f"completion generation failed:\n{bash.stderr}{zsh.stderr}"
                )
            check_bash(
                bash.stdout,
                args.command,
                expected,
                contract.parent,
                env,
                temp / "completion.bash",
            )
            zfunc = temp / "zfunc"
            zfunc.mkdir()
            check_zsh(
                zsh.stdout,
                args.command,
                expected,
                contract.parent,
                env,
                zfunc,
            )
            if args.install:
                check_install(cli, args.command, contract, env, temp / "home")
    except RuntimeError as error:
        return die(str(error))

    print(
        f"flags2env shell contract: ok command={args.command} "
        f"scopes={sum(1 for _ in scopes(root))} "
        f"install={'yes' if args.install else 'no'}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
