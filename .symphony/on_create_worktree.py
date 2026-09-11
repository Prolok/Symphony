#!/usr/bin/env python3

from __future__ import annotations

import json
import re
import shutil
import sys
from pathlib import Path
import os

MANAGED_BINARIES = ("symphony", "sym-codex")
LINEAR_PROJECT_SLUG = "LINEAR_PROJECT_SLUG"
LINEAR_TEST_PROJECT_SLUG = "LINEAR_TEST_PROJECT_SLUG"
ENV_KEY_PATTERN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
APP_PROJECT_KEYS = {
    LINEAR_PROJECT_SLUG, LINEAR_TEST_PROJECT_SLUG, "LINEAR_TEAM_KEY", "LINEAR_ASSIGNEE",
    "LINEAR_APP_CLIENT_ID", "LINEAR_APP_WORKSPACE_ID", "LINEAR_APP_USER_ID", "LINEAR_APP_INSTALLATION_ID",
}
MODEL_KEYS = {"SYM_CODEX_MODEL", "SYM_CODEX_REASONING_EFFORT", "SYM_CODEX_SERVICE_TIER", "SYM_CODEX_HUMAN_SERVICE_TIER"}


def copy_env_local(source: Path, target: Path) -> None:
    if not source.is_file():
        return

    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)
    target.chmod(0o600)


def copy_public_env_values(source: Path, target: Path, keys: set[str]) -> None:
    if target.exists() or not source.is_file():
        return
    values = {}
    for line in source.read_text(encoding="utf-8").splitlines():
        candidate = re.sub(r"^export\s+", "", line.strip()).split("=", 1)[0].strip()
        if candidate in keys:
            parsed = parse_env_assignment(line)
            if parsed is not None:
                values[parsed[0]] = parsed[1]
    if values:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("".join(f"{key}={quote_env_value(value)}\n" for key, value in values.items()), encoding="utf-8")
        target.chmod(0o600)


def read_env_value(path: Path, key: str) -> str | None:
    if not path.is_file():
        return None

    result = None

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        candidate = re.sub(r"^export\s+", "", raw_line.strip()).split("=", 1)[0].strip()
        if candidate != key:
            continue
        parsed = parse_env_assignment(raw_line)

        if parsed is None:
            continue

        name, value = parsed

        if name == key:
            result = value

    return result


def read_env_value_with_overrides(paths: list[Path], key: str) -> str | None:
    value = None

    for path in paths:
        override = read_env_value(path, key)

        if override is not None:
            value = override

    return value


def parse_env_assignment(raw_line: str) -> tuple[str, str] | None:
    line = raw_line.strip()

    if not line or line.startswith("#"):
        return None

    export_parts = line.split(None, 1)

    if export_parts[0] == "export":
        line = export_parts[1].lstrip() if len(export_parts) == 2 else ""

    if "=" not in line:
        return None

    raw_name, raw_value = line.split("=", 1)
    name = raw_name.strip()

    if not ENV_KEY_PATTERN.fullmatch(name):
        return None

    value = parse_env_value(raw_value)

    if value is None:
        return None

    return name, value


def parse_env_value(raw_value: str) -> str | None:
    value = raw_value.lstrip()

    if value == "":
        return ""

    if value.startswith('"'):
        return parse_quoted_env_value(value, '"', decode_json_string)

    if value.startswith("'"):
        return parse_quoted_env_value(value, "'", lambda quoted: quoted)

    return re.sub(r"\s+#.*$", "", value).strip()


def parse_quoted_env_value(
    value: str,
    quote: str,
    decode_value,
) -> str | None:
    quoted, rest = take_quoted_segment(value[1:], quote)

    if quoted is None:
        return None

    trailing = rest.strip()

    if trailing and not trailing.startswith("#"):
        return None

    return decode_value(quoted)


def take_quoted_segment(value: str, quote: str) -> tuple[str | None, str]:
    escaped = False
    quoted = []

    for index, char in enumerate(value):
        if quote == '"' and escaped:
            quoted.append("\\" + char)
            escaped = False
            continue

        if quote == '"' and char == "\\":
            escaped = True
            continue

        if char == quote:
            return "".join(quoted), value[index + 1 :]

        quoted.append(char)

    if escaped:
        quoted.append("\\")

    return None, ""


def decode_json_string(value: str) -> str | None:
    try:
        decoded = json.loads(f'"{value}"')
    except json.JSONDecodeError:
        return None

    return decoded if isinstance(decoded, str) else None


def set_env_value(path: Path, key: str, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    assignment = f"{key}={quote_env_value(value)}"

    if path.is_file():
        lines = path.read_text(encoding="utf-8").splitlines()
    else:
        lines = []

    replaced = False
    updated_lines = []

    for line in lines:
        parsed = parse_env_assignment(line)

        if parsed is not None and parsed[0] == key:
            updated_lines.append(assignment)
            replaced = True
        else:
            updated_lines.append(line)

    if not replaced:
        updated_lines.append(assignment)

    path.write_text("\n".join(updated_lines) + "\n", encoding="utf-8")
    path.chmod(0o600)


def quote_env_value(value: str) -> str:
    escaped = (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("\t", "\\t")
    )

    return f'"{escaped}"'


def ensure_managed_symlink(workspace: Path, binary_name: str) -> None:
    if os.environ.get("SYMPHONY_RELEASE_ROOT"):
        return
    target = workspace / binary_name
    link_path = managed_link_path(workspace, binary_name)
    link_path.parent.mkdir(parents=True, exist_ok=True)

    if link_path.is_symlink():
        if link_path.readlink() == target:
            return

        link_path.unlink()
    elif link_path.exists():
        if link_path.is_dir():
            raise IsADirectoryError(f"cannot replace directory with symlink: {link_path}")

        link_path.unlink()

    link_path.symlink_to(target)


def managed_link_path(workspace: Path, binary_name: str) -> Path:
    return Path.home() / ".local" / "bin" / f"{binary_name}-{workspace.name}"


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        script_name = Path(argv[0]).name if argv else "on_create_worktree.py"
        print(f"usage: {script_name} <source_repo> <workspace>", file=sys.stderr)
        return 2

    source_repo = Path(argv[1]).expanduser().resolve()
    workspace = Path(argv[2]).expanduser().resolve()
    app_mode = os.environ.get("SYMPHONY_LINEAR_AUTH_MODE") == "app"
    project_source = source_repo / ".symphony" / ".env.local"
    project_target = workspace / ".symphony" / ".env.local"
    preserve_project_target = app_mode and project_target.exists()
    if app_mode:
        copy_public_env_values(project_source, project_target, APP_PROJECT_KEYS)
    else:
        copy_env_local(project_source, project_target)
    test_project_slug = read_env_value_with_overrides(
        [
            source_repo / ".symphony" / ".env",
            source_repo / ".symphony" / ".env.local",
        ],
        LINEAR_TEST_PROJECT_SLUG,
    )

    if test_project_slug is not None and not preserve_project_target:
        set_env_value(
            workspace / ".symphony" / ".env.local",
            LINEAR_PROJECT_SLUG,
            test_project_slug,
        )

    if app_mode:
        copy_public_env_values(source_repo / ".env.local", workspace / ".env.local", MODEL_KEYS)
    else:
        copy_env_local(source_repo / ".env.local", workspace / ".env.local")

    for binary_name in MANAGED_BINARIES:
        ensure_managed_symlink(workspace, binary_name)

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
