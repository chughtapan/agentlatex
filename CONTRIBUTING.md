# Contributing

Keep changes small and include tests for behavior that affects validation or
rendering.

Run the guard suite:

```sh
python3 -m unittest discover -s tests -v
```

For Claude packaging changes, validate both the marketplace and plugin:

```sh
claude plugin validate .
claude plugin validate plugins/agentedit-guard
```

For Emacs reviewer changes, also run the batch ERT suite in the
[Emacs reviewer guide](emacs/README.md#test-reviewer-changes). CI covers Emacs
29.4 and 30.2 with the built-in TeX modes and AUCTeX 14.1.0 and 14.1.2.

Compile the LaTeX example:

```sh
cd examples
TEXINPUTS=../latex: pdflatex -interaction=nonstopmode example.tex
```

Update `CHANGELOG.md` for user-visible changes. Do not weaken provenance checks
without documenting the resulting enforcement gap.

## Readable-format verification

The [format contract](docs/readable-edits.md#format-contract-for-implementers) and
`tests/fixtures/readable-edits.json` are shared by Python, ERT, and the renderer
checks. Expected plain source is independent of the parser. Add behavioral
regressions for ownership, placement, and actual native-tool discrepancies.

To require the TeX metrics and real original/proposed/strict entry points:

```sh
AGENTEDIT_REQUIRE_TEX=1 python3 -m unittest discover -s tests -v
pylint -E plugins/agentedit-guard/scripts/guard_agent_edits.py
```

Install `pdflatex` and `pdftotext` first. The TeX CI job requires these tests;
a Python-only environment reports an explicit dependency skip.

For captured model-output evaluations, use the eight cases returned by
`tests/evaluate_agent_output.py:scenario`: word, fragment, independent pair,
addition, deletion, paragraph separator, citation note, and proposal revision.
Use each scenario's initial source and requested exact payload pairs in a
disposable project. Capture the complete resulting source after each attempt as:

```json
[{"case": "word", "attempt": 1, "source": "complete resulting source"}]
```

Evaluate a capture with:

```sh
python3 tests/evaluate_agent_output.py attempts.json
python3 tests/evaluate_agent_output.py baseline-attempts.json --legacy
```

The first command requires blocks-v1; the second measures older instructions'
precision and retained source without expecting the new syntax. Supply all eight
cases. Include a denied partial-revision attempt and its complete-frame retry.
The report separates format, precise payload extent, frozen provenance,
first-attempt passes, eventual passes, and retry counts. Record host/model and
instruction revision alongside the capture. Deterministic reference-output tests
verify the evaluator; they are not live model-output measurements.

Before release/activation, record native dispatch after host reload (create,
revise, denied partial write, successful full retry), prepared setup-to-first-
decision timing, shared-owner readiness, and a source-editor or Emacs walkthrough.
The target is under five minutes after external prerequisites; do not claim that
without a timed exercise. Verify the transfer cycle does not resurrect resolved
records, and opt out of a disposable paper while preserving unrelated setup.
The reporting user's readability validation is separate from an owner walkthrough.
Track first-attempt format failures, forced payload widening, wrong-side choices,
residual frames, and whitespace loss during the first review and again after a
week of use; any integrity failure requires repair before broader activation.

## Native end-to-end smoke test

Install the current plugin into Codex, reload, and review/trust its hooks. The
test needs Codex login, Emacs, `pdflatex`, and `pdftotext`:

```sh
codex plugin marketplace add .
codex plugin add agentedit-guard@agentlatex
python3 tests/run_native_e2e.py --model gpt-6-astra
```

When updating an already installed plugin, refresh its installed copy before
running. Automation that has vetted every enabled hook can pass `--trust-hooks`
to grant hook trust for each test invocation. This does not bypass hook denials.

The harness makes live model calls and retains a disposable project under the
printed temporary path. It verifies native dispatch with observational pre/post
hooks, checks all eight editing cases with LF-terminated source, deliberately
submits an unmarked edit and a partial revision, retries a complete frame, drives
the actual Ediff A/R bindings, checks default automatic saving and undo,
checks a manual-save pass and custom fragment staging, compiles original/proposed/strict PDFs, and transfers the reviewed source
back to the agent. Failures retain transcripts and source for inspection.

This is an automated test of a prepared project. It does not measure fresh
bootstrap, an owner's review experience, an old-instruction model baseline,
Claude Code dispatch, or the Overleaf browser UI. The live harness is opt-in and
does not run in normal CI. Inspect local transcripts before publishing them.
