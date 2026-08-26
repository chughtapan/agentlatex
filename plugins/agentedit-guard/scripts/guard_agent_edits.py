#!/usr/bin/env python3
"""Deny unmarked agent edits to TeX and BibTeX in AgentEdit projects."""

from __future__ import annotations

import dataclasses
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
SHELL_TOOLS = {"exec", "exec_command", "bash", "powershell", "shell"}
MUTATING_SHELL_RE = re.compile(
    r"(?:\bapply_patch\b|\bsed\b[^\n]*(?:\s-i\b|--in-place)|"
    r"\bperl\b[^\n]*\s-pi\b|\b(?:tee|cp|mv)\b|"
    r"\b(?:Add-Content|Out-File|Set-Content)\b|"
    r"\blatexindent\b[^\n]*(?:\s-w\b|--overwrite)|"
    r">\s*[^\s;&|]+\.(?:tex|bib)\b)",
    re.IGNORECASE,
)
PATCH_HEADER_RE = re.compile(
    r"^\*{3} (?:Add|Update|Delete) File:\s*(.+?\.(?:tex|bib))\s*$",
    re.MULTILINE | re.IGNORECASE,
)
PATCH_HUNK_RE = re.compile(r"^@@.*$", re.MULTILINE)
PATH_RE = re.compile(r"(?<![\w.-])([\w./#-]+\.(?:tex|bib))\b", re.IGNORECASE)
BOOTSTRAP_MARKER_DEFAULT = "AGENTEDIT-BOOTSTRAP"
PATH_KEYS = {"file_path", "filepath", "filename", "path"}
PROPOSED_TEXT_KEYS = {
    "content",
    "new_string",
    "new_text",
    "newstring",
    "newtext",
}
COMMAND_KEYS = {"cmd", "command"}
PATCH_KEYS = {"input", "patch"}


@dataclasses.dataclass(frozen=True)
class Mutation:
    """A proposed change to one file before the write tool executes."""

    path: str
    proposed_text: str | None


def find_policy_root(start: Path) -> Path | None:
    current = start.resolve()
    for candidate in (current, *current.parents):
        if (candidate / POLICY_FILE).is_file():
            return candidate
    return None


def resolved_target(path: str, cwd: Path) -> Path:
    candidate = Path(path)
    if not candidate.is_absolute():
        candidate = cwd / candidate
    return candidate.resolve()


def target_policy_root(path: str, cwd: Path) -> Path | None:
    """Find the policy governing PATH, even when CWD is another directory."""
    return find_policy_root(resolved_target(path, cwd).parent)


def load_policy(root: Path) -> dict[str, Any]:
    try:
        payload = json.loads((root / POLICY_FILE).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return payload if isinstance(payload, dict) else {}


def normalized_tool_name(payload: dict[str, Any]) -> str:
    raw = payload.get("tool_name", payload.get("toolName", ""))
    unqualified = str(raw).rsplit(".", 1)[-1]
    return unqualified.rsplit("__", 1)[-1].lower()


def tool_input(payload: dict[str, Any]) -> Any:
    return payload.get("tool_input", payload.get("toolInput", {}))


def is_source_mutation(tool: str, command: str) -> bool:
    if tool in DIRECT_WRITE_TOOLS:
        return True
    if tool in SHELL_TOOLS:
        return MUTATING_SHELL_RE.search(command) is not None
    return False


def string_field(value: dict[str, Any], keys: set[str]) -> str | None:
    """Return the first string field whose normalized key is in KEYS."""
    for key, item in value.items():
        if str(key).lower() in keys and isinstance(item, str):
            return item
    return None


def explicit_target_paths(value: Any) -> list[str]:
    paths: list[str] = []
    if isinstance(value, dict):
        for key, item in value.items():
            lowered = str(key).lower()
            if lowered in PATH_KEYS:
                if isinstance(item, str) and item.lower().endswith(
                    (".tex", ".bib")
                ):
                    paths.append(item)
            paths.extend(explicit_target_paths(item))
    elif isinstance(value, list):
        for item in value:
            paths.extend(explicit_target_paths(item))
    return paths


def added_patch_text(section: str) -> str:
    return "\n".join(
        line[1:]
        for line in section.splitlines()
        if line.startswith("+") and not line.startswith("+++")
    )


def patch_mutations(material: str) -> list[Mutation]:
    """Return one mutation per file hunk in an apply_patch payload."""
    matches = list(PATCH_HEADER_RE.finditer(material))
    mutations: list[Mutation] = []
    for index, match in enumerate(matches):
        if index + 1 < len(matches):
            end = matches[index + 1].start()
        else:
            end = len(material)
        section = material[match.end():end]
        path = match.group(1).strip()
        hunks = list(PATCH_HUNK_RE.finditer(section))
        if not hunks:
            mutations.append(Mutation(path, added_patch_text(section)))
            continue
        for hunk_index, hunk in enumerate(hunks):
            if hunk_index + 1 < len(hunks):
                hunk_end = hunks[hunk_index + 1].start()
            else:
                hunk_end = len(section)
            mutations.append(
                Mutation(path, added_patch_text(section[hunk.end():hunk_end]))
            )
    return mutations


def direct_mutations(tool: str, value: Any) -> list[Mutation]:
    """Decode independently reviewable mutations from a direct write tool."""
    if tool == "apply_patch":
        if isinstance(value, str):
            patch = value
        elif isinstance(value, dict):
            patch = string_field(value, PATCH_KEYS | COMMAND_KEYS)
        else:
            patch = None
        if patch is None:
            return [
                Mutation(path, None) for path in explicit_target_paths(value)
            ]
        return patch_mutations(patch)

    if not isinstance(value, dict):
        return []
    path = string_field(value, PATH_KEYS)
    edits = value.get("edits")
    if isinstance(edits, list):
        mutations: list[Mutation] = []
        for edit in edits:
            if not isinstance(edit, dict):
                continue
            edit_path = string_field(edit, PATH_KEYS) or path
            if edit_path is not None:
                mutations.append(
                    Mutation(edit_path, string_field(edit, PROPOSED_TEXT_KEYS))
                )
        if mutations or path is None:
            return mutations
        return [Mutation(path, None)]
    if path is not None:
        return [Mutation(path, string_field(value, PROPOSED_TEXT_KEYS))]
    return [Mutation(target, None) for target in explicit_target_paths(value)]


def shell_command(value: Any) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        return string_field(value, COMMAND_KEYS) or ""
    return ""


def shell_target_paths(command: str) -> list[str]:
    return [match.group(1) for match in PATH_RE.finditer(command)]


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


def is_ascii_letter(char: str) -> bool:
    """Return whether CHAR has TeX's ordinary control-word letter shape."""
    return "A" <= char <= "Z" or "a" <= char <= "z"


def tex_control_words(material: str) -> list[tuple[str, int]]:
    """Return TeX control words and their ending offsets in source order."""
    words: list[tuple[str, int]] = []
    cursor = 0
    while cursor < len(material):
        if material[cursor] != "\\":
            cursor += 1
            continue

        word_start = cursor + 1
        if word_start >= len(material) or not is_ascii_letter(
            material[word_start]
        ):
            cursor += 2
            continue

        word_end = word_start + 1
        while word_end < len(material) and is_ascii_letter(material[word_end]):
            word_end += 1
        words.append((material[word_start:word_end], word_end))
        cursor = word_end
    return words


def valid_agentedit_calls(material: str) -> list[tuple[str, str]]:
    calls: list[tuple[str, str]] = []
    for control_word, cursor in tex_control_words(material):
        if control_word != "agentedit":
            continue
        arguments: list[str] = []
        for _ in range(4):
            parsed = parse_braced(material, cursor)
            if parsed is None:
                break
            argument, cursor = parsed
            arguments.append(argument)
        if (
            len(arguments) == 4
            and arguments[0].strip()
            and arguments[1].strip()
        ):
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


def validate_mutation(
    mutation: Mutation,
    cwd: Path,
    policy_root: Path,
) -> str | None:
    """Validate one mutation against the policy that governs its target."""
    target = resolved_target(mutation.path, cwd)
    if target.suffix.lower() not in {".tex", ".bib"}:
        return None
    if mutation.proposed_text is None:
        return (
            f"Blocked edit to {mutation.path}: could not identify the proposed "
            "replacement text. Retry with a supported file-edit tool."
        )

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
    display_path = str(target)
    if target.suffix.lower() == ".tex":
        return validate_tex(
            display_path,
            mutation.proposed_text,
            bootstrap_marker,
            bootstrap_files,
            policy_root,
        )
    if target.suffix.lower() == ".bib":
        return validate_bib(display_path, mutation.proposed_text)
    return None


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
        f"{', '.join(missing)}. Retain the commented old entry, active new "
        "entry, "
        "reason, and unverified DBLP metadata."
    )


def evaluate(payload: dict[str, Any]) -> tuple[bool, str | None]:
    cwd = Path(str(payload.get("cwd") or os.getcwd()))
    value = tool_input(payload)
    tool = normalized_tool_name(payload)
    command = shell_command(value) if tool in SHELL_TOOLS else ""
    if not is_source_mutation(tool, command):
        return True, None

    failures: list[str] = []
    if tool in SHELL_TOOLS:
        paths = shell_target_paths(command)
        protected_paths = [
            path for path in paths if target_policy_root(path, cwd) is not None
        ]
        if protected_paths:
            joined_paths = ", ".join(protected_paths)
            failures.append(
                "Blocked shell mutation of protected source: "
                f"{joined_paths}. Retry with a supported file-edit tool so the "
                "guard can inspect the proposed provenance record."
            )
        elif find_policy_root(cwd) is not None and not paths:
            failures.append(
                "Blocked a source-mutating shell command in an AgentEdit "
                "project. Retry with a supported file-edit tool so the guard "
                "can inspect the target and proposed provenance record."
            )
    else:
        for mutation in direct_mutations(tool, value):
            policy_root = target_policy_root(mutation.path, cwd)
            if policy_root is None:
                continue
            failure = validate_mutation(mutation, cwd, policy_root)
            if failure is not None:
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
        error = deny("AgentEdit guard could not parse the hook input.")
        print(json.dumps(error))
        return 0
    if not isinstance(payload, dict):
        print(json.dumps(deny("AgentEdit guard expected a JSON object.")))
        return 0

    allowed, reason = evaluate(payload)
    decision = "{}" if allowed else json.dumps(
        deny(reason or "AgentEdit policy failed.")
    )
    print(decision)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
