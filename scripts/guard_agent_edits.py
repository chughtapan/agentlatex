#!/usr/bin/env python3
"""Deny unmarked Codex edits to TeX and BibTeX in AgentEdit projects."""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path
from typing import Any


POLICY_FILE = ".agentedit.json"
DIRECT_WRITE_TOOLS = {
    "write",
    "edit",
    "multiedit",
    "apply_patch",
    "write_file",
    "edit_file",
}
SHELL_TOOLS = {"exec", "exec_command", "bash", "shell"}
MUTATING_SHELL_RE = re.compile(
    r"(?:\bapply_patch\b|\bsed\b[^\n]*(?:\s-i\b|--in-place)|"
    r"\bperl\b[^\n]*\s-pi\b|\b(?:tee|cp|mv)\b|"
    r"\blatexindent\b[^\n]*(?:\s-w\b|--overwrite)|"
    r">\s*[^\s;&|]+\.(?:tex|bib)\b)",
    re.IGNORECASE,
)
PATCH_HEADER_RE = re.compile(
    r"^\*{3} (?:Add|Update|Delete) File:\s*(.+?\.(?:tex|bib))\s*$",
    re.MULTILINE | re.IGNORECASE,
)
PATH_RE = re.compile(r"(?<![\w.-])([\w./#-]+\.(?:tex|bib))\b", re.IGNORECASE)
BOOTSTRAP_MARKER_DEFAULT = "AGENTEDIT-BOOTSTRAP"


def collect_strings(value: Any) -> list[str]:
    if isinstance(value, str):
        return [value]
    if isinstance(value, dict):
        result: list[str] = []
        for item in value.values():
            result.extend(collect_strings(item))
        return result
    if isinstance(value, list):
        result = []
        for item in value:
            result.extend(collect_strings(item))
        return result
    return []


def find_policy_root(start: Path) -> Path | None:
    current = start.resolve()
    for candidate in (current, *current.parents):
        if (candidate / POLICY_FILE).is_file():
            return candidate
    return None


def load_policy(root: Path) -> dict[str, Any]:
    try:
        payload = json.loads((root / POLICY_FILE).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return payload if isinstance(payload, dict) else {}


def normalized_tool_name(payload: dict[str, Any]) -> str:
    raw = payload.get("tool_name", payload.get("toolName", ""))
    return str(raw).rsplit(".", 1)[-1].lower()


def tool_input(payload: dict[str, Any]) -> Any:
    return payload.get("tool_input", payload.get("toolInput", {}))


def is_source_mutation(tool: str, material: str) -> bool:
    if tool in DIRECT_WRITE_TOOLS:
        return True
    if tool in SHELL_TOOLS:
        return MUTATING_SHELL_RE.search(material) is not None
    return False


def explicit_target_paths(value: Any) -> tuple[bool, list[str]]:
    found_key = False
    paths: list[str] = []
    if isinstance(value, dict):
        for key, item in value.items():
            lowered = str(key).lower()
            if lowered in {"file_path", "filepath", "path", "filename"}:
                found_key = True
                if isinstance(item, str) and item.lower().endswith((".tex", ".bib")):
                    paths.append(item)
            nested_found, nested_paths = explicit_target_paths(item)
            found_key = found_key or nested_found
            paths.extend(nested_paths)
    elif isinstance(value, list):
        for item in value:
            nested_found, nested_paths = explicit_target_paths(item)
            found_key = found_key or nested_found
            paths.extend(nested_paths)
    return found_key, paths


def patch_sections(material: str) -> dict[str, str]:
    matches = list(PATCH_HEADER_RE.finditer(material))
    sections: dict[str, str] = {}
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(material)
        sections[match.group(1).strip()] = material[match.start():end]
    return sections


def target_sections(value: Any, material: str) -> dict[str, str]:
    sections = patch_sections(material)
    if sections:
        return sections

    found_explicit, paths = explicit_target_paths(value)
    if found_explicit:
        return {path: material for path in paths}

    return {match.group(1): material for match in PATH_RE.finditer(material)}


def parse_braced(text: str, start: int) -> tuple[str, int] | None:
    while start < len(text) and text[start].isspace():
        start += 1
    if start >= len(text) or text[start] != "{":
        return None

    depth = 1
    cursor = start + 1
    content_start = cursor
    while cursor < len(text):
        char = text[cursor]
        escaped = cursor > 0 and text[cursor - 1] == "\\"
        if char == "{" and not escaped:
            depth += 1
        elif char == "}" and not escaped:
            depth -= 1
            if depth == 0:
                return text[content_start:cursor], cursor + 1
        cursor += 1
    return None


def valid_agentedit_calls(material: str) -> list[tuple[str, str]]:
    calls: list[tuple[str, str]] = []
    for match in re.finditer(r"\\+agentedit\b", material):
        cursor = match.end()
        arguments: list[str] = []
        for _ in range(4):
            parsed = parse_braced(material, cursor)
            if parsed is None:
                break
            argument, cursor = parsed
            arguments.append(argument)
        if len(arguments) == 4 and arguments[0].strip() and arguments[1].strip():
            calls.append((arguments[0].strip(), arguments[1].strip()))
    return calls


def validate_tex(
    path: str,
    material: str,
    bootstrap_marker: str,
    bootstrap_files: set[str],
    policy_root: Path,
) -> str | None:
    candidate = Path(path)
    if candidate.is_absolute():
        try:
            candidate = candidate.resolve().relative_to(policy_root.resolve())
        except ValueError:
            pass
    normalized_path = candidate.as_posix().removeprefix("./")
    is_bootstrap_file = normalized_path in bootstrap_files
    if is_bootstrap_file and bootstrap_marker and bootstrap_marker in material:
        return None
    if valid_agentedit_calls(material):
        return None
    return (
        f"Blocked edit to {path}: include a complete "
        "\\agentedit{stable-id}{reason}{original}{edited} call in the proposed "
        "change. Additions use an empty original argument."
    )


def validate_bib(path: str, material: str) -> str | None:
    required_patterns = {
        "AGENT-EDIT-BEGIN": r"%\s*AGENT-EDIT-BEGIN:\s*\S+",
        "REASON": r"%\s*REASON:\s*\S+",
        "OLD": r"%\s*OLD:(?:\s*\(none\)|\s*$)",
        "NEW": r"%\s*NEW:",
        "AGENT-EDIT-END": r"%\s*AGENT-EDIT-END:\s*\S+",
        "UNVERIFIED DBLP record": (
            r"%\s*UNVERIFIED:\s*DBLP\s+https://dblp\.org/rec/\S+"
        ),
        "DBLP biburl": (
            r"biburl\s*=\s*\{https://dblp\.org/rec/[^}\s]+\.bib\}"
        ),
    }
    missing = [
        label
        for label, pattern in required_patterns.items()
        if re.search(pattern, material, re.MULTILINE | re.IGNORECASE) is None
    ]
    if not missing:
        return None
    return (
        f"Blocked edit to {path}: the BibTeX provenance record is missing "
        f"{', '.join(missing)}. Retain the commented old entry, active new entry, "
        "reason, and unverified DBLP metadata."
    )


def evaluate(payload: dict[str, Any]) -> tuple[bool, str | None]:
    cwd = Path(str(payload.get("cwd") or os.getcwd()))
    policy_root = find_policy_root(cwd)
    if policy_root is None:
        return True, None

    value = tool_input(payload)
    strings = collect_strings(value)
    material = "\n".join(strings)
    tool = normalized_tool_name(payload)
    if not is_source_mutation(tool, material):
        return True, None

    sections = target_sections(value, material)
    if not sections:
        return True, None

    policy = load_policy(policy_root)
    bootstrap_marker = str(
        policy.get("bootstrap_marker", BOOTSTRAP_MARKER_DEFAULT)
    )
    configured_bootstrap_files = policy.get("bootstrap_files", [])
    bootstrap_files = {
        Path(str(path)).as_posix().removeprefix("./")
        for path in configured_bootstrap_files
        if isinstance(path, str)
    }
    failures: list[str] = []
    for path, section in sections.items():
        lowered = path.lower()
        if lowered.endswith(".tex"):
            failure = validate_tex(
                path,
                section,
                bootstrap_marker,
                bootstrap_files,
                policy_root,
            )
        elif lowered.endswith(".bib"):
            failure = validate_bib(path, section)
        else:
            failure = None
        if failure:
            failures.append(failure)

    if failures:
        return False, " ".join(failures)
    return True, None


def deny(reason: str) -> dict[str, Any]:
    return {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, OSError):
        print(json.dumps(deny("AgentEdit guard could not parse the hook input.")))
        return 0
    if not isinstance(payload, dict):
        print(json.dumps(deny("AgentEdit guard expected a JSON object.")))
        return 0

    allowed, reason = evaluate(payload)
    print("{}" if allowed else json.dumps(deny(reason or "AgentEdit policy failed.")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
