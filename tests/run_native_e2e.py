"""Opt-in live Codex -> installed guard -> Ediff -> PDF smoke test.

Requires a trusted, installed copy of the current plugin and Codex login. Uses
real model calls, inherits host configuration, and only edits a temporary paper.
Run: python3 tests/run_native_e2e.py --model MODEL
Artifacts are retained locally; inspect transcripts before sharing them.
"""

import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import time

from evaluate_agent_output import GUARD, SCENARIOS, expected_accepted, scenario


ROOT = Path(__file__).resolve().parents[1]


def run_host(directory, name, prompt, model, trust_hooks):
    """Run a fresh native session and retain the host's own event stream."""
    command = [
        "codex", "exec", "--ephemeral", "-s", "workspace-write",
        "-C", str(directory), "--json", "--model", model,
        "-c", 'model_reasoning_effort="low"',
        "-c", 'features.multi_agent=false',
        prompt,
    ]
    if trust_hooks:
        command.insert(2, "--dangerously-bypass-hook-trust")
    audit_command = "python3 " + shlex.quote(str(directory / "audit.py"))
    audit_command += " " + shlex.quote(str(directory / f"{name}.hooks.jsonl"))
    for event in ("PreToolUse", "PostToolUse"):
        hook = '[{matcher="^apply_patch$",hooks=[{type="command",command='
        hook += json.dumps(audit_command) + '}]}]'
        command[2:2] = ["-c", f"hooks.{event}={hook}"]
    print(f"Running native Codex: {name}", flush=True)
    with (directory / f"{name}.jsonl").open("w") as output:
        with (directory / f"{name}.stderr").open("w") as errors:
            subprocess.run(
                command, stdout=output, stderr=errors,
                stdin=subprocess.DEVNULL, check=True, timeout=300,
            )
    events = [json.loads(line) for line in
              (directory / f"{name}.hooks.jsonl").read_text().splitlines()]
    if not any(e["hook_event_name"] == "PreToolUse" for e in events):
        raise AssertionError(f"{name}: native patch was not attempted")
    if name.startswith("denied-"):
        if any(e["hook_event_name"] == "PostToolUse" for e in events):
            raise AssertionError(f"{name}: native patch executed despite denial")
        if "Blocked edit" not in read(directory / f"{name}.stderr"):
            raise AssertionError(f"{name}: missing AgentEdit denial receipt")


def read(path):
    """Read source as bytes first to retain physical line endings."""
    return path.read_bytes().decode("utf-8")


def compile_view(directory, name, prefix, expected_success):
    """Compile actual paper input and check strict/report mode behavior."""
    (directory / f"{name}.tex").write_text(
        "\\documentclass{article}\n" + prefix
        + "\\usepackage{agentedit}\n\\begin{document}\n"
        + "\\input{pair.tex}\n\\end{document}\n",
        encoding="utf-8",
    )
    result = subprocess.run(
        ["pdflatex", "-interaction=nonstopmode", "-halt-on-error", f"{name}.tex"],
        cwd=directory, capture_output=True, check=False,
    )
    (directory / f"{name}.stdout").write_bytes(result.stdout)
    if (result.returncode == 0) != expected_success:
        raise AssertionError(f"Unexpected {name} build result; see {name}.stdout")
    if expected_success:
        subprocess.run(
            ["pdftotext", f"{name}.pdf", f"{name}.txt"], cwd=directory, check=True
        )
        return " ".join(read(directory / f"{name}.txt").split())
    if b"Unverified agent edit" not in result.stdout:
        raise AssertionError("Strict build failed for an unrelated reason")
    return None


def main():
    """Exercise writes, denial, revision, review, compilation, and transfer."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", required=True)
    parser.add_argument(
        "--trust-hooks", action="store_true",
        help="Trust enabled host hooks for this run only; vet installed hooks first.",
    )
    args = parser.parse_args()
    for executable in ("codex", "emacs", "pdflatex", "pdftotext", "git"):
        if not shutil.which(executable):
            parser.error(f"Missing prerequisite: {executable}")
    directory = Path(tempfile.mkdtemp(prefix="agentlatex-native-e2e-"))
    print(f"Artifacts: {directory}", flush=True)
    started = time.monotonic()
    subprocess.run(["git", "init", "-q", str(directory)], check=True)
    shutil.copy2(ROOT / "latex/agentedit.sty", directory / "agentedit.sty")
    (directory / ".agentedit.json").write_text(
        '{"tex_edit_format":"blocks-v1"}', encoding="utf-8"
    )
    (directory / "audit.py").write_text(
        "import json, sys\n"
        "event = json.load(sys.stdin)\n"
        "event = {k: event[k] for k in "
        "('hook_event_name', 'tool_name', 'tool_input', 'tool_response', 'model') "
        "if k in event}\n"
        "with open(sys.argv[1], 'a') as log:\n"
        "    log.write(json.dumps(event) + '\\n')\n",
        encoding="utf-8",
    )
    (directory / "AGENTS.md").write_text(
        "This is a disposable, prepared AgentLaTeX integration test. Bootstrap "
        "is complete. Use the installed agentedit-guard skill for source edits. "
        "Only change the requested .tex files with native apply_patch. "
        "Do not edit policy, setup, instructions, or style files. Do not delegate.\n",
        encoding="utf-8",
    )
    names = sorted(set(SCENARIOS) | {"pair", "revision"})
    for name in names:
        (directory / f"{name}.tex").write_text(scenario(name)[0] + "\n")
    original = read(directory / "word.tex")
    run_host(directory, "denied-unmarked", (
        "This is a deliberate negative guard test in a disposable paper. "
        "Call native apply_patch exactly once: in word.tex replace the line "
        "'The system always terminates.' with 'The system usually terminates.'. "
        "Submit plain source without AgentEdit markup. Do not retry or use "
        "another write tool. Report the actual tool denial or result."
    ), args.model, args.trust_hooks)
    if read(directory / "word.tex") != original:
        raise AssertionError("Native hook did not prevent the unmarked edit")
    tasks = [dict(file=f"{name}.tex", changes=scenario(name)[2]) for name in names]
    run_host(directory, "generate", (
        "Apply these eight precise source-edit tasks using the installed "
        "AgentEdit guard skill and blocks-v1 format. Each pair is [old, new]; "
        "JSON escapes specify literal source, including whitespace. Keep each "
        "pair as its own record with exactly those payloads. Use a concise "
        "reason. revision.tex already has a proposal: revise it, preserving "
        "its ID and original. Preserve all surrounding source and the final "
        "newline. Native apply_patch must include complete frames, plain @@ "
        "and exact unchanged context. Read files first. Tasks:\n"
        + json.dumps(tasks)
    ), args.model, args.trust_hooks)
    for name in names:
        source = read(directory / f"{name}.tex")
        records = GUARD.scan_records(source)
        before, _, pairs = scenario(name)
        if [record.arguments[2:] for record in records] != pairs:
            raise AssertionError(f"{name}: precise payloads differ")
        if GUARD.original_projection(source, records) != GUARD.original_projection(
            before + "\n", GUARD.scan_records(before + "\n")
        ):
            raise AssertionError(f"{name}: original source differs")
        if not all(record.framed for record in records):
            raise AssertionError(f"{name}: unframed record")
        proposed, cursor = [], 0
        for record in records:
            proposed.extend((source[cursor:record.start], record.arguments[3],
                             record.whitespace))
            cursor = record.end
        proposed.append(source[cursor:])
        if "".join(proposed) != expected_accepted(name) + "\n":
            raise AssertionError(f"{name}: proposed source placement differs")
        (directory / f"{name}.generated").write_text(source)
    pair = directory / "pair.tex"
    before_revision = read(pair)
    run_host(directory, "denied-partial", (
        "Deliberate negative integration test: read pair.tex, then call native "
        "apply_patch once with only the proposed-argument line as the hunk, "
        "changing usually to often. Do not include other frame lines or context. "
        "Do not retry, use another tool, or change any other file. "
        "Report the actual guard result."
    ), args.model, args.trust_hooks)
    if read(pair) != before_revision:
        raise AssertionError("Partial-frame write changed disk bytes")
    run_host(directory, "retry-full", (
        "In pair.tex revise the usually proposal to often. Submit the complete "
        "frame with native apply_patch, preserving ID, original payload always, "
        "retained whitespace, and the separate quickly-to-promptly edit."
    ), args.model, args.trust_hooks)
    records = GUARD.scan_records(read(pair))
    if [r.arguments[2:] for r in records] != [("always", "often"), ("quickly", "promptly")]:
        raise AssertionError("Full revision has incorrect payloads")
    prior = GUARD.scan_records(before_revision)
    if [(r.arguments[0], r.arguments[2], r.whitespace) for r in records] != [
        (r.arguments[0], r.arguments[2], r.whitespace) for r in prior
    ]:
        raise AssertionError("Revision changed frozen provenance")
    shutil.copy2(pair, directory / "pair.before-review")
    report_mode = "\\def\\AgentWritingReportMode{1}\n"
    original_text = compile_view(directory, "original", report_mode
                                 + "\\def\\AgentEditRender#1#2#3#4{#3}\n", True)
    proposed_text = compile_view(directory, "proposed", report_mode, True)
    if "The system always terminates quickly." not in original_text:
        raise AssertionError("Original PDF differs")
    if "The system often terminates promptly." not in proposed_text:
        raise AssertionError("Proposed PDF differs")
    compile_view(directory, "unresolved-strict", "", False)
    expected = "The system often terminates quickly.\n"
    (directory / "pair.expected").write_text(expected)
    with (directory / "emacs.log").open("w") as output:
        subprocess.run(
            ["emacs", "-Q", "--batch", "-L", str(ROOT / "emacs"),
             "-l", str(ROOT / "tests/e2e_review.el")],
            env=dict(os.environ, AGENTEDIT_E2E_DIR=str(directory)),
            stdout=output, stderr=subprocess.STDOUT, check=True, timeout=60,
        )
    if read(pair) != expected:
        raise AssertionError("Saved review differs from independent expectation")
    strict_text = compile_view(directory, "resolved-strict", "", True)
    if expected.strip() not in strict_text:
        raise AssertionError("Resolved strict PDF differs")
    shutil.copy2(pair, directory / "handoff.tex")
    run_host(directory, "handoff", (
        "A human accepted and rejected the previous proposals, saved the source, "
        "and transferred it to handoff.tex. In that file propose only quickly "
        "to promptly as one precise blocks-v1 record. Treat the current plain "
        "source as authoritative; do not recreate resolved records."
    ), args.model, args.trust_hooks)
    records = GUARD.scan_records(read(directory / "handoff.tex"))
    if [r.arguments[2:] for r in records] != [("quickly", "promptly")]:
        raise AssertionError("Transfer resurrected a resolved record")
    if GUARD.original_projection(read(directory / "handoff.tex"), records) != expected:
        raise AssertionError("Transfer changed resolved source")
    result = dict(
        passed=True, model=args.model, scenarios=names,
        host=subprocess.check_output(["codex", "--version"], text=True).strip(),
        seconds=round(time.monotonic() - started, 1),
        checks=["unmarked denial", "eight precise generated edits", "partial denial",
                "complete revision", "original/proposed PDFs", "strict rejection",
                "real Ediff A/R", "no implicit save", "exact undo", "explicit save",
                "resolved strict PDF", "source transfer"],
    )
    events = [json.loads(line) for line in
              (directory / "generate.hooks.jsonl").read_text().splitlines()]
    result["generation_patch_attempts"] = sum(
        e["hook_event_name"] == "PreToolUse" for e in events
    )
    result["generation_patch_completions"] = sum(
        e["hook_event_name"] == "PostToolUse" for e in events
    )
    (directory / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2), flush=True)


if __name__ == "__main__":
    main()
