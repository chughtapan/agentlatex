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
    r"\b(?:rm|touch|truncate)\b|"
    r"\b(?:Add-Content|Clear-Content|Copy-Item|Move-Item|New-Item|"
    r"Out-File|Remove-Item|Rename-Item|Set-Content)\b|"
    r"\blatexindent\b[^\n]*(?:\s-w\b|--overwrite)|"
    r">\s*[^\s;&|]+\.(?:tex|bib)\b)",
    re.IGNORECASE,
)
PATCH_HEADER_RE = re.compile(
    r"^\*{3} (?:Add|Update|Delete) File:[ \t]*(.+?)[ \t]*\r?$",
    re.MULTILINE | re.IGNORECASE,
)
PATCH_HUNK_RE = re.compile(r"^@@.*$", re.MULTILINE)
PATH_RE = re.compile(r"(?<![\w.-])([\w./#-]+\.(?:tex|bib))\b", re.IGNORECASE)
BOOTSTRAP_MARKER_DEFAULT = "AGENTEDIT-BOOTSTRAP"
VERBATIM_ENVIRONMENTS = {
    "verbatim",
    "verbatim*",
    "Verbatim",
    "Verbatim*",
    "lstlisting",
    "minted",
}
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
OLD_TEXT_KEYS = {"old_string", "old_text", "oldstring", "oldtext"}
SOURCE_SPACE = " \t\r\n"
SAFE_ID = r"[A-Za-z0-9][A-Za-z0-9._:-]*"
BANNER = re.compile(r"[ \t]*%%% AGENTEDIT(?=[ \t:]|\r?\n|\Z)")
CONTROL = re.compile(r"\\([A-Za-z]+)")
FRAME_HEAD = re.compile(r"%%% AGENTEDIT START: (" + SAFE_ID + r") %%%(\r?\n)")
REPAIR = (
    "Retry a smaller batch with complete blocks, including both % separators "
    "and the newline after END. Preserve the ID, original, and right whitespace; "
    "keep only the changed word or fragment in the payloads. Example:\n"
    "%\n%%% AGENTEDIT START: edit-1 %%%\n"
    "\\agentedit{edit-1}\n  {Reason.}\n  {old}\n  {new}%\n"
    "%%% AGENTEDIT END: edit-1 %%%\n"
    "Guide: https://github.com/chughtapan/agentlatex/blob/v0.4.0/docs/readable-edits.md"
)


class FormatError(ValueError):
    """An invalid policy, frame, or unsupported mutation context."""


@dataclasses.dataclass(frozen=True)
class Record:
    """Lossless source extents for a visible macro and its optional frame."""

    start: int
    end: int
    arguments: tuple[str, ...]
    whitespace: str = ""
    framed: bool = False


@dataclasses.dataclass(frozen=True)
class Mutation:
    """A proposed change to one file before the write tool executes."""

    path: str
    proposed_text: str | None
    operation: str = "edit"
    original_text: str | None = None
    ranges: tuple[tuple[int, int], ...] | None = None
    error: str | None = None
    patch_group: int = 0


def find_policy_root(start: Path) -> Path | None:
    """Find the nearest present project policy above START."""
    current = start.resolve()
    for candidate in (current, *current.parents):
        if (candidate / POLICY_FILE).is_file():
            return candidate
    return None


def resolved_target(path: str, cwd: Path) -> Path:
    """Resolve a tool path relative to the host working directory."""
    candidate = Path(path)
    if not candidate.is_absolute():
        candidate = cwd / candidate
    return candidate.resolve()


def target_policy_root(path: str, cwd: Path) -> Path | None:
    """Find the policy governing PATH, even when CWD is another directory."""
    return find_policy_root(resolved_target(path, cwd).parent)


def load_policy(root: Path) -> dict[str, Any]:
    """Read an explicit policy, denying malformed present configuration."""
    try:
        payload = json.loads((root / POLICY_FILE).read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise FormatError(
            f"configuration error in {root / POLICY_FILE}: {error}"
        ) from error
    if not isinstance(payload, dict):
        raise FormatError("configuration error: policy must be a JSON object")
    if (
        "tex_edit_format" in payload
        and payload["tex_edit_format"] != "blocks-v1"
    ):
        raise FormatError(
            "configuration error: tex_edit_format must be blocks-v1 or absent"
        )
    if not isinstance(payload.get("bootstrap_files", []), list) or not all(
        isinstance(path, str) for path in payload.get("bootstrap_files", [])
    ):
        raise FormatError(
            "configuration error: bootstrap_files must be an array of paths"
        )
    if not isinstance(payload.get("bootstrap_marker", ""), str):
        raise FormatError(
            "configuration error: bootstrap_marker must be a string"
        )
    return payload


def normalized_tool_name(payload: dict[str, Any]) -> str:
    """Normalize supported host and MCP tool name prefixes."""
    raw = payload.get("tool_name", payload.get("toolName", ""))
    unqualified = str(raw).rsplit(".", 1)[-1]
    return unqualified.rsplit("__", 1)[-1].lower()


def tool_input(payload: dict[str, Any]) -> Any:
    """Extract the native host tool-input envelope."""
    return payload.get("tool_input", payload.get("toolInput", {}))


def is_source_mutation(tool: str, command: str) -> bool:
    """Identify configured write tools or obvious mutating shell commands."""
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
    """Collect declared TeX and BibTeX paths from nested tool input."""
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


def physical_lines(material: str) -> list[str]:
    """Split only physical LF lines, preserving Unicode and final terminators."""
    lines = material.split("\n")
    return [line + "\n" for line in lines[:-1]] + (
        [lines[-1]] if lines[-1] else []
    )


def patch_hunk(
    path: str, hunk: str, group: int, failure: str | None
) -> Mutation:
    """Decode exact old/new line slices and contiguous submitted additions."""
    old, new, ranges = [], [], []
    size = 0
    for line in physical_lines(hunk):
        if line.startswith("*** Move"):
            failure = "patch moves are unsupported; use an exact Edit"
        if line.startswith("\\ No newline") or line.startswith(
            "*** End of File"
        ):
            failure = "EOF patch directives require an exact Edit"
        if line.startswith("***"):
            break
        if line[:1] not in (" ", "-", "+"):
            failure = (
                "unprefixed patch context is unsupported; prefix blank "
                "context with a space or use an exact Edit"
            )
            continue
        content = line[1:]
        if line[0] != "+":
            old.append(content)
        if line[0] != "-":
            if line[0] == "+":
                if ranges and ranges[-1][1] == size:
                    ranges[-1] = (ranges[-1][0], size + len(content))
                else:
                    ranges.append((size, size + len(content)))
            new.append(content)
            size += len(content)
    return Mutation(
        path, "".join(new), "patch", "".join(old), tuple(ranges), failure, group
    )


def patch_mutations(material: str) -> list[Mutation]:
    """Decode LF Add/Update hunks with conservative native placement evidence."""
    matches = list(PATCH_HEADER_RE.finditer(material))
    mutations = []
    for index, match in enumerate(matches):
        end = (
            matches[index + 1].start()
            if index + 1 < len(matches)
            else len(material)
        )
        section = material[match.end() : end].removeprefix("\n")
        path = match.group(1).strip()
        failure = (
            "CRLF patch syntax requires an exact Edit"
            if "\r" in material
            else None
        )
        if match.group().startswith("*** Delete"):
            mutations.append(
                Mutation(
                    path, "", error="file deletion cannot retain provenance"
                )
            )
            continue
        if match.group().startswith("*** Add"):
            lines = physical_lines(section)
            new = "".join(line[1:] for line in lines if line.startswith("+"))
            mutations.append(
                Mutation(path, new, "add", error=failure, patch_group=index)
            )
            continue
        anchors = re.findall(r"^@@[^\n]*\n", section, flags=re.MULTILINE)
        if any(anchor != "@@\n" for anchor in anchors):
            failure = (
                "named @@ anchors require an exact Edit; use plain @@ "
                "with unique exact context"
            )
        hunks = re.split(r"^@@[^\n]*\n", section, flags=re.MULTILINE)
        for hunk in hunks:
            if not hunk.strip():
                continue
            mutation = patch_hunk(path, hunk, index, failure)
            if (
                mutation.original_text
                or mutation.proposed_text
                or mutation.error
            ):
                mutations.append(mutation)
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
                    Mutation(
                        edit_path,
                        string_field(edit, PROPOSED_TEXT_KEYS),
                        "edit",
                        string_field(edit, OLD_TEXT_KEYS),
                        error=(
                            "replace_all is unsupported; use unique exact edits"
                            if edit.get("replace_all") or edit.get("replaceAll")
                            else None
                        ),
                    )
                )
        if mutations or path is None:
            return mutations
        return [Mutation(path, None)]
    if path is not None:
        return [
            Mutation(
                path,
                string_field(value, PROPOSED_TEXT_KEYS),
                "write" if tool in {"write", "write_file"} else "edit",
                string_field(value, OLD_TEXT_KEYS),
                error=(
                    "replace_all is unsupported; use unique exact edits"
                    if value.get("replace_all") or value.get("replaceAll")
                    else None
                ),
            )
        ]
    return [Mutation(target, None) for target in explicit_target_paths(value)]


def shell_command(value: Any) -> str:
    """Extract a shell command without executing it."""
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        return string_field(value, COMMAND_KEYS) or ""
    return ""


def shell_target_paths(command: str) -> list[str]:
    """Locate source paths mentioned by a shell command."""
    return [match.group(1) for match in PATH_RE.finditer(command)]


def parse_braced(text: str, start: int) -> tuple[str, int] | None:
    """Return a raw balanced TeX argument and its exclusive end offset."""
    while start < len(text) and text[start] in SOURCE_SPACE:
        start += 1
    if start >= len(text) or text[start] != "{":
        return None

    depth = 1
    cursor = start + 1
    content_start = cursor
    while cursor < len(text):
        char = text[cursor]
        if char == "\\":
            cursor += 2
            continue
        if char == "%":
            newline = text.find("\n", cursor)
            cursor = len(text) if newline < 0 else newline + 1
            continue
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[content_start:cursor], cursor + 1
        cursor += 1
    return None


def is_ascii_letter(char: str) -> bool:
    """Return whether CHAR has TeX's ordinary control-word letter shape."""
    return "A" <= char <= "Z" or "a" <= char <= "z"


def verb_end(material: str, word_end: int, strict: bool = False) -> int:
    """Return the offset after a TeX verb token, or the end of MATERIAL."""
    cursor = word_end
    if cursor < len(material) and material[cursor] == "*":
        cursor += 1
    if cursor >= len(material) or material[cursor] in SOURCE_SPACE:
        if strict:
            raise FormatError("invalid verb delimiter")
        return len(material)
    delimiter = material[cursor]
    line_end = material.find("\n", cursor + 1)
    if line_end < 0:
        line_end = len(material)
    closing = material.find(delimiter, cursor + 1, line_end)
    if closing < 0 and strict:
        raise FormatError("unterminated verb token")
    return len(material) if closing < 0 else closing + 1


def verbatim_environment_end(
    material: str, name: str, content_start: int, strict: bool = False
) -> int:
    """Return the offset after a line-oriented verbatim environment."""
    terminator = re.compile(
        rf"^[ \t]*\\end\{{{re.escape(name)}\}}[ \t]*(?:%[^\r\n]*)?\r?$",
        re.MULTILINE,
    )
    match = terminator.search(material, content_start)
    if match is None:
        if strict:
            raise FormatError(f"unterminated {name} environment")
        return len(material)
    newline = material.find("\n", match.end())
    return len(material) if newline < 0 else newline + 1


def tex_control_words(
    material: str, strict: bool = False
) -> list[tuple[str, int]]:
    """Return visible TeX control words and ending offsets in source order."""
    words: list[tuple[str, int]] = []
    cursor = 0
    while cursor < len(material):
        if material[cursor] == "%":
            newline = material.find("\n", cursor + 1)
            cursor = len(material) if newline < 0 else newline + 1
            continue
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
        word = material[word_start:word_end]
        if word == "verb":
            cursor = verb_end(material, word_end, strict)
            continue
        if word == "begin":
            parsed = parse_braced(material, word_end)
            if parsed is not None and parsed[0] in VERBATIM_ENVIRONMENTS:
                cursor = verbatim_environment_end(
                    material, parsed[0], parsed[1], strict
                )
                continue
        words.append((word, word_end))
        cursor = word_end
    return words


def valid_agentedit_calls(material: str) -> list[tuple[str, str]]:
    """Find complete visible calls for the legacy presence-based policy."""
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


def parse_call(material: str, start: int) -> tuple[Record, list[int]]:
    """Read four raw arguments and opening positions without normalizing text."""
    cursor = start + len("\\agentedit")
    arguments, openings = [], []
    for _ in range(4):
        while cursor < len(material) and material[cursor] in SOURCE_SPACE:
            cursor += 1
        openings.append(cursor)
        parsed = parse_braced(material, cursor)
        if parsed is None:
            raise FormatError("expected four balanced braced arguments")
        argument, cursor = parsed
        arguments.append(argument)
    if not arguments[0].strip() or not arguments[1].strip():
        raise FormatError("ID and reason must contain visible text")
    if any(
        word == "agentedit"
        for arg in arguments
        for word, _ in tex_control_words(arg, strict=True)
    ):
        raise FormatError("nested agentedit macro")
    return Record(start, cursor, tuple(arguments)), openings


# Ownership: P | % EOL START EOL macro(old,new) W % EOL END EOL | S
# Decision:  P | chosen W                                       | S
# Separators and banners are synthetic; P, payload interiors, W, and S are raw.
def parse_frame(material: str, banner: int, separator: int | None) -> Record:
    """Parse a canonical blocks-v1 envelope at a lexically visible banner."""
    head = FRAME_HEAD.match(material, banner)
    if head is None:
        raise FormatError("malformed or orphan AGENTEDIT banner")
    if separator is None or material[separator:banner] not in ("%\n", "%\r\n"):
        raise FormatError("missing active left % separator")
    macro = head.end()
    if not material.startswith("\\agentedit{", macro):
        raise FormatError(
            "START must be followed immediately by agentedit and its ID"
        )
    record, openings = parse_call(material, macro)
    if record.arguments[0] != head[1]:
        raise FormatError("frame ID does not match macro ID")
    # Only the argument interiors may contain arbitrary whitespace or comments.
    previous = openings[0] + len(record.arguments[0]) + 2
    for opening, argument in zip(openings[1:], record.arguments[1:]):
        if re.fullmatch(r"\r?\n[ \t]*", material[previous:opening]) is None:
            raise FormatError(
                "reason, original, and proposed must each start on a new line"
            )
        previous = opening + len(argument) + 2
    tail = re.compile(
        r"([ \t\r\n]*)%\r?\n%%% AGENTEDIT END: "
        + re.escape(head[1])
        + r" %%%\r?\n"
    ).match(material, record.end)
    if tail is None:
        raise FormatError(
            "missing right % separator, matching END, or END newline"
        )
    end = tail.end()
    if "\r" in tail[1].replace("\r\n", ""):
        raise FormatError("bare CR is not wrapper whitespace; use LF or CRLF")
    if end < len(material) and material[end] in SOURCE_SPACE:
        raise FormatError(
            "right whitespace must be retained before the % separator"
        )
    return Record(separator, end, record.arguments, tail[1], True)


def scan_records(material: str) -> list[Record]:
    """Scan ordinary TeX once, treating comments and verbatim bodies as opaque.

    A reserved banner outside a parsed payload is structural even if damaged.
    This deliberately assumes ordinary TeX catcodes, like the Emacs reviewer.
    """
    records, ids = [], set()
    cursor, separator = 0, None
    while cursor < len(material):
        char = material[cursor]
        if char == "%":
            line_start = material.rfind("\n", 0, cursor) + 1
            if material[line_start:cursor].strip(" \t") == "" and BANNER.match(
                material, line_start
            ):
                try:
                    record = parse_frame(material, line_start, separator)
                except FormatError as error:
                    raise FormatError(
                        f"line {material.count(chr(10), 0, cursor) + 1}: {error}"
                    ) from error
                records.append(record)
                cursor = record.end
                separator = None
                continue
            newline = material.find("\n", cursor)
            separator = (
                cursor
                if material[cursor:newline] in ("%", "%\r") and newline >= 0
                else None
            )
            cursor = len(material) if newline < 0 else newline + 1
            continue
        if char != "\\":
            cursor += 1
            continue
        word = CONTROL.match(material, cursor)
        if word is None:
            cursor += 2
            continue
        end = word.end()
        if word[1] == "verb":
            cursor = verb_end(material, end, strict=True)
        elif (
            word[1] == "begin"
            and (parsed := parse_braced(material, end))
            and parsed[0] in VERBATIM_ENVIRONMENTS
        ):
            cursor = verbatim_environment_end(material, *parsed, strict=True)
        elif word[1] == "agentedit":
            record, _ = parse_call(material, cursor)
            records.append(record)
            cursor = record.end
        else:
            cursor = end
    for record in records:
        identifier = record.arguments[0]
        if identifier in ids:
            raise FormatError(f"duplicate ID {identifier}")
        ids.add(identifier)
    return records


def original_projection(material: str, records: list[Record]) -> str:
    """Return exact original source, retaining each framed record's whitespace."""
    parts, cursor = [], 0
    for record in records:
        parts.extend(
            (
                material[cursor : record.start],
                record.arguments[2],
                record.whitespace,
            )
        )
        cursor = record.end
    parts.append(material[cursor:])
    return "".join(parts)


def mutation_source(
    mutation: Mutation, target: Path, snapshots: dict[Path, str]
) -> str:
    """Read exact source once per batch without newline conversion."""
    if target not in snapshots:
        try:
            with target.open(encoding="utf-8", newline="") as source:
                snapshots[target] = source.read()
        except FileNotFoundError:
            if mutation.operation not in {"write", "add"}:
                raise FormatError(
                    "missing source context; create with Write or Add File"
                ) from None
            snapshots[target] = ""
        except (OSError, UnicodeError) as error:
            raise FormatError(
                f"could not read source context: {error}"
            ) from error
    return snapshots[target]


def mutation_extent(
    mutation: Mutation,
    target: Path,
    before: str,
    patch_states: dict[Path, tuple[int, int]],
) -> tuple[int, int]:
    """Establish an exact replacement range supported by the native tool."""
    if mutation.operation == "patch" and before and not before.endswith("\n"):
        raise FormatError(
            "patch tool would add a final newline; retry with an exact Edit "
            "preserving the original EOF"
        )
    if mutation.operation == "patch" and "\r" in before:
        raise FormatError(
            (
                "CRLF patch placement is unsupported; retry with an "
                "exact Edit preserving CRLF"
            )
        )
    if mutation.operation in {"write", "add"}:
        if mutation.operation == "add" and before:
            raise FormatError(
                "Add File target already exists; use an exact Edit"
            )
        start, stop = 0, len(before)
    else:
        old = mutation.original_text
        if not old or before.count(old) != 1:
            raise FormatError(
                (
                    "need a unique exact old_string/oldText or patch "
                    "context; include adjacent source to disambiguate"
                )
            )
        start = before.index(old)
        stop = start + len(old)
    if mutation.operation in {"patch", "add"}:
        group, cursor = patch_states.get(target, (mutation.patch_group, 0))
        if group != mutation.patch_group:
            raise FormatError(
                "repeated patch file headers require an exact Edit"
            )
        if start < cursor or (start > 0 and before[start - 1] != "\n"):
            raise FormatError(
                (
                    "patch context must match whole lines in source order; "
                    "retry with an exact Edit"
                )
            )
    return start, stop


def validate_blocks(
    mutation: Mutation,
    target: Path,
    snapshots: dict[Path, str],
    patch_states: dict[Path, tuple[int, int]],
) -> None:
    """Establish real placement, ownership, and original-source conservation."""
    if mutation.error:
        raise FormatError(mutation.error)
    new = mutation.proposed_text
    if new is None:
        raise FormatError("missing replacement text")
    before = mutation_source(mutation, target, snapshots)
    start, stop = mutation_extent(mutation, target, before, patch_states)
    after = before[:start] + new + before[stop:]
    prior = scan_records(before)
    for record in prior:
        if (
            record.start < stop
            and record.end > start
            and not re.fullmatch(SAFE_ID, record.arguments[0])
        ):
            raise FormatError(
                f"legacy ID {record.arguments[0]!r} cannot be framed: a human "
                "must resolve this record or decide its ID; do not rename it automatically"
            )
    records = scan_records(after)
    ranges = (
        mutation.ranges if mutation.ranges is not None else ((0, len(new)),)
    )
    if not ranges:
        raise FormatError(
            "deletion-only patches must resubmit the complete frame"
        )
    for left, right in ranges:
        touched = [
            r
            for r in records
            if r.start < start + right and r.end > start + left
        ]
        if not touched or any(
            not r.framed or r.start < start + left or r.end > start + right
            for r in touched
        ):
            raise FormatError(
                (
                    "submit a complete frame for every changed range; "
                    "partial or compact records cannot be submitted"
                )
            )
    if original_projection(before, prior) != original_projection(
        after, records
    ):
        raise FormatError(
            (
                "original source changed: preserve exact old text and "
                "surrounding whitespace"
            )
        )
    by_id = {r.arguments[0]: r for r in records}
    for old_record in prior:
        revised = by_id.get(old_record.arguments[0])
        if (
            revised is None
            or revised.arguments[2] != old_record.arguments[2]
            or (
                old_record.framed
                and revised.whitespace != old_record.whitespace
            )
        ):
            raise FormatError(
                (
                    "only humans resolve records; revisions must preserve "
                    "ID, original, and right whitespace"
                )
            )
    snapshots[target] = after
    if mutation.operation in {"patch", "add"}:
        patch_states[target] = (mutation.patch_group, start + len(new))


def validate_tex(
    path: str,
    material: str,
    bootstrap_marker: str,
    bootstrap_files: set[str],
    policy_root: Path,
) -> str | None:
    """Validate legacy TeX additions and narrow bootstrap exceptions."""
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
    snapshots: dict[Path, str] | None = None,
    patch_states: dict[Path, tuple[int, int]] | None = None,
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

    try:
        policy = load_policy(policy_root)
    except FormatError as error:
        return f"Blocked edit to {target}: {error}"
    bootstrap_marker = str(
        policy.get("bootstrap_marker", BOOTSTRAP_MARKER_DEFAULT)
    )
    configured_bootstrap_files = policy.get("bootstrap_files", [])
    bootstrap_files = {
        Path(str(path)).as_posix().removeprefix("./")
        for path in configured_bootstrap_files
        if isinstance(path, str)
    }
    # Legacy validation and bootstrap exceptions see additions only. Unchanged
    # patch context is placement evidence, never authorization for new prose.
    material = mutation.proposed_text
    if mutation.ranges is not None:
        material = "".join(
            material[left:right] for left, right in mutation.ranges
        )
    display_path = str(target)
    if target.suffix.lower() == ".tex":
        bootstrap = (
            target.relative_to(policy_root).as_posix() in bootstrap_files
            and bootstrap_marker
            and bootstrap_marker in material
        )
        if policy.get("tex_edit_format") == "blocks-v1" and not bootstrap:
            try:
                validate_blocks(
                    mutation,
                    target,
                    snapshots if snapshots is not None else {},
                    patch_states if patch_states is not None else {},
                )
            except FormatError as error:
                return f"Blocked edit to {target}: {error}"
            return None
        return validate_tex(
            display_path,
            material,
            bootstrap_marker,
            bootstrap_files,
            policy_root,
        )
    if target.suffix.lower() == ".bib":
        return validate_bib(display_path, material)
    return None


def validate_bib(path: str, material: str) -> str | None:
    """Require the existing BibTeX provenance fields in submitted text."""
    required_patterns = {
        "AGENT-EDIT-BEGIN": r"%\s*AGENT-EDIT-BEGIN:\s*\S+",
        "REASON": r"%\s*REASON:\s*\S+",
        "OLD": r"%\s*OLD:(?:\s*\(none\)|\s*$)",
        "NEW": r"%\s*NEW:",
        "AGENT-EDIT-END": r"%\s*AGENT-EDIT-END:\s*\S+",
        "UNVERIFIED DBLP record": (
            r"%\s*UNVERIFIED:\s*DBLP\s+https://dblp\.org/rec/\S+"
        ),
        "DBLP biburl": (r"biburl\s*=\s*\{https://dblp\.org/rec/[^}\s]+\.bib\}"),
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
    """Return a whole-request hook decision without modifying project files."""
    cwd = Path(str(payload.get("cwd") or os.getcwd()))
    value = tool_input(payload)
    tool = normalized_tool_name(payload)
    command = shell_command(value) if tool in SHELL_TOOLS else ""
    if not is_source_mutation(tool, command):
        return True, None

    failures: list[str] = []
    snapshots: dict[Path, str] = {}
    patch_states: dict[Path, tuple[int, int]] = {}
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
        for member, mutation in enumerate(direct_mutations(tool, value), 1):
            policy_root = target_policy_root(mutation.path, cwd)
            if policy_root is None:
                continue
            failure = validate_mutation(
                mutation, cwd, policy_root, snapshots, patch_states
            )
            if failure is not None:
                failures.append(f"Member {member}: {failure}")

    if failures:
        return False, "\n".join(failures[:10]) + (
            f"\n{len(failures)} failures; {max(0, len(failures) - 10)} omitted.\n"
            + REPAIR
        )
    return True, None


def deny(reason: str) -> dict[str, Any]:
    """Build the native PreToolUse denial envelope."""
    return {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }


def main() -> int:
    """Print native hook decisions, or read-only installed capabilities."""
    if sys.argv[1:] == ["--capabilities"]:
        print(
            json.dumps(
                {
                    "tex_edit_format": "blocks-v1",
                    "legacy": True,
                    "operations": [
                        "write",
                        "exact-edit",
                        "sequential-multiedit",
                        "lf-patch",
                    ],
                    "active_hook_verified": False,
                }
            )
        )
        return 0
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
    decision = (
        "{}"
        if allowed
        else json.dumps(deny(reason or "AgentEdit policy failed."))
    )
    print(decision)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
