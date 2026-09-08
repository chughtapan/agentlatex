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

See the [implementation evidence and pending activation checks](docs/readable-edits-verification.md).
