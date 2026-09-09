# Readable-edit verification

This records implementation evidence for the proposed 0.4.0 release. It does not
activate a paper's policy or claim that a released plugin is installed.

## Local evidence, 2026-09-08

- 71 Python tests pass with TeX dependencies required. The suite includes the
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

## Native end-to-end evidence, 2026-09-08

The [captured smoke-test receipt](evidence/codex-native-e2e-2026-09-08.json)
records Codex CLI 0.153.4 with `gpt-6-astra`, the tested file hashes, native
pre/post events, generated source, review results, and PDF text. The complete
prepared-project run passed in 186.7 seconds. This is automated elapsed time,
not an owner's setup-to-first-decision measurement.

- Installed the packaged plugin, restarted native sessions, and observed real
  `apply_patch` dispatch. An unmarked write and a partial proposal revision each
  produced one pre-hook event, no post-hook event, a native AgentEdit denial,
  and unchanged disk bytes. A complete-frame retry succeeded.
- Generated all eight cases as nine precise records in one successful patch
  request, with no format retry in the final run. The cases use LF-terminated
  files for Codex's patch adapter. Exact payloads, accepted-source placement,
  original reconstruction, and frozen revision provenance all passed.
- Drove real Ediff A/R bindings against the generated pair. Accept/reject
  preserved unsaved disk bytes, two undo steps restored the complete source,
  and repeated review followed by explicit save produced the expected sentence.
- Original and proposed PDFs contained the expected text. Strict compilation
  rejected unresolved edits and passed after review. Transferring the saved
  source back to Codex produced only the newly requested record.

The first installed-plugin smoke exposed a Codex packaging defect: the manifest
did not select its intended hook file, whose command also used a path relative
to the paper directory. Explicit manifest routing and `PLUGIN_ROOT` command
resolution fixed native interception. A command-execution regression now covers
paper and installed-plugin paths containing spaces. Codex documents these
[plugin hook loading rules](https://learn.chatgpt.com/docs/hooks#plugin-hooks).

An earlier generated batch was denied once because a revised frame used
unchanged patch context instead of replacement lines. Its complete-frame retry
succeeded without widening payloads. The skill, repair message, and format guide
now explain `-`/`+` frame replacement explicitly. These are individual smoke
observations, not comparative model-quality rates.

Run the [opt-in native harness](../CONTRIBUTING.md#native-end-to-end-smoke-test)
to reproduce this path. Full local transcripts are retained separately; the
checked-in receipt contains only the synthetic paper's relevant evidence.

## Release and activation evidence still needed

- Claude Code native hook dispatch after reload: create, revise, observe an
  unchanged file after a denied partial write, and retry successfully. The local
  Claude CLI is installed but logged out; its live test requires authentication.
- Disposable fresh/shared/interrupted/repeated setup, old-reader recovery,
  source-editor handoff, and complete opt-out while retaining unrelated setup.
- A live comparison with older instructions, including first-attempt format
  rates and retry counts. The new-instruction smoke above does not establish
  comparative results or reliability across hosts/models.
- An owner review walkthrough and measured prepared setup-to-first-decision time.
- The reporting user's readability validation and actual Overleaf review exercise.

Keep the PR in draft and shared activation staged until the relevant external
checks are completed. Do not mark these items passed based only on local tests.
