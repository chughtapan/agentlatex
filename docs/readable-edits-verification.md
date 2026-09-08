# Readable-edit verification

This records implementation evidence for the proposed 0.4.0 release. It does not
activate a paper's policy or claim that a released plugin is installed.

## Local evidence, 2026-09-08

- 70 Python tests pass with TeX dependencies required. The suite includes the
  eight-scenario evaluator's precision, provenance, and placement regressions.
- 80 ERT tests pass with Emacs 30.1 and AUCTeX 14.1.2. Built-in TeX mode passes
  74 tests and explicitly skips the six AUCTeX-specific tests. Both interpreted
  and byte-compiled reviewer paths were exercised; byte compilation has no warnings.
- Shared corpus: 49 valid source fixtures, 24 malformed cases with diagnostic
  categories, and three opaque examples. Exact source, Unicode, LF/CRLF, empty
  sides, whitespace, word fragments, and independent adjacent edits are covered.
- 120 fixture renderings compare framed, compact, and plain source in original
  and proposed views using PDF word positions and TeX box dimensions. Additional
  checks cover adjacent frames, paragraph splitting, and the actual bootstrap
  original/proposed/strict entry points with a TODO renderer.
- Real `apply_patch` two-hunk creation and complete-frame revision preserved
  expected file bytes and exact original projections. Native-tool discrepancy
  reproductions for named anchors, unprefixed blank context, Unicode separators,
  and missing final newlines now deny. These are adapter checks, not proof that
  an installed host dispatches the hook.
- Marketplace/plugin validation, bundled-asset parity, Python error lint,
  version consistency, and whitespace checks pass.
- Independent completion and adversarial reviews found issues that were repaired
  with regressions. No known in-repository implementation items remain deferred.

[CI run 34284771941](https://github.com/chughtapan/agentlatex/actions/runs/34284771941)
passed all eight jobs for implementation commit `f508de9`, including the required
LaTeX checks and Emacs 29.4/30.2 with built-in modes and AUCTeX 14.1.0/14.1.2.
The pull request's current check results remain the source of truth after later
changes.

## Release and activation evidence still needed

- Native hook dispatch after reload for each supported host: create, revise,
  observe an unchanged file after a denied partial write, and retry successfully.
- Disposable fresh/shared/interrupted/repeated setup, old-reader recovery,
  source-editor handoff, and complete opt-out while retaining unrelated setup.
- Live host/model outputs compared with older instructions, including actual
  first-attempt format rates and retry counts. The deterministic evaluator is
  ready; reference-output tests are not live-model measurements.
- An owner review walkthrough and measured prepared setup-to-first-decision time.
- The reporting user's readability validation and actual Overleaf review exercise.

Keep the PR in draft and shared activation staged until the relevant external
checks are completed. Do not mark these items passed based only on local tests.
