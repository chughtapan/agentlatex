# AgentLaTeX Bootstrap Contract

This file is written for an agent operating inside an existing LaTeX project.
Complete setup without changing manuscript prose, bibliography entries, figures,
or experimental data.

## Required Outcome

When bootstrap is complete:

1. The project contains a regular, project-local `agentedit.sty` file.
2. The real document entry point loads the package and defines the desired
   renderer.
3. A normal build treats every unresolved edit as a package error while
   rendering the edited source.
4. A review build changes marker errors to warnings and prints a final count.
5. Every reason is visible using the project's TODO-note style when one exists.
6. `.agentedit.json` activates the guard hook only after the setup files work.
7. `AGENTS.md` records the TeX, BibTeX, citation, and acceptance rules.
8. The guard plugin is installed and available when the host supports hooks, or
   the agent reports the exact host limitation and required human action.

## Step 0: Detect The Host And Enable The Guard

Determine the current agent host from the available runtime and tools. Do not
ask the user to identify it when it is already evident. If AgentEdit Guard is
already installed, inspect its capabilities before reusing it. Installation is
not evidence that the loaded guard supports readable blocks or is active.
Use its `agentedit-guard` skill and continue the local checks below.

On command-line hosts, install the current release when it is missing:

```sh
# Codex
codex plugin marketplace add chughtapan/agentlatex --ref v0.4.0
codex plugin add agentedit-guard --marketplace agentlatex

# Claude Code
claude plugin marketplace add chughtapan/agentlatex@v0.4.0
claude plugin install agentedit-guard@agentlatex
```

Run only the pair that matches the current host. Do not replace an existing
newer installation with an older one. If plugin activation requires a session
reload, finish the project-only bootstrap safely, then tell the user the exact
reload action and do not claim that the guard is active in the current session.

Claude Desktop may require the user to open **Customize** → **Plugins** →
**Add marketplace**, add `https://github.com/chughtapan/agentlatex`, and install
AgentEdit Guard. Ask only for that approval, then resume this contract. Ordinary
Claude Chat does not execute plugin hooks; it may configure the repository and
follow the skill, but must report that edits are not hook-enforced.

For readable edits, check the installed script's `--capabilities` output for
`"tex_edit_format": "blocks-v1"`. If Emacs is available, install or update the
reviewer in the user's personal configuration, then verify the **loaded**
`agentedit-review-format-version` equals `"blocks-v1"` after restarting Emacs.
Do not infer loaded capability from a newer file on disk. Without Emacs, use the
source-editor recipe below; no Emacs installation is required.

Verify host dispatch in a disposable protected project: use the host's actual
file-edit tool to create a complete framed proposal, revise it while preserving
ID/original/whitespace, submit a partial revision and observe denial, then retry
with the complete frame. Check that denied writes did not execute. A direct
Python call verifies the parser only; it does not prove that the host dispatches
the hook. Repeat the native smoke after a required host reload. If native dispatch
cannot be verified, report the limitation and leave blocks-v1 activation staged.

Plugin installation changes agent configuration, not the manuscript. Continue
bootstrap without changing paper prose or bibliography data.

## Step 1: Inspect The Project

Read the nearest `AGENTS.md`, the real LaTeX entry point, its preamble, build
scripts, and bibliography configuration. Determine:

- The real entry-point filename. Do not assume `main.tex`.
- Whether the project already defines `\agentedit` or `\AgentEditRender`.
- Which TODO package and author-note macros are already available.
- How local and Overleaf builds select the entry point.
- Whether any current working-tree changes belong to the user.
- Whether AgentLaTeX is already partly or fully configured.
- Whether this is a new standalone project or an existing shared project, and
  which teammates may still have an older reviewer. Do not infer their readiness
  from the current user's successful local upgrade.

Do not overwrite user changes or introduce a second TODO package unnecessarily.
Treat setup as idempotent: preserve a compatible existing installation, repair
missing pieces, and never insert duplicate package loads, renderers, wrappers,
or policy sections.

If `.agentedit.json` already protects a bootstrap file, include its
`AGENTEDIT-BOOTSTRAP` marker in the same proposed write or patch hunk as the
maintenance change. A small edit that sends only the replacement text may be
rejected because the hook intentionally validates the proposal, not unrelated
text already present elsewhere in the file.

## Step 2: Install The Style File

Copy `latex/agentedit.sty` from this repository into the target project's top
level. When operating from the installed guard plugin, resolve the plugin root
from `skills/agentedit-guard/SKILL.md`; the style file is at
`../../latex/agentedit.sty` relative to that skill directory.

For an agent without the installed plugin, retrieve the file from:

```text
https://raw.githubusercontent.com/chughtapan/agentlatex/v0.4.0/latex/agentedit.sty
```

Commit the copied file to the paper repository. Do not use a symlink or Git
submodule because Overleaf projects cannot contain submodules.

## Step 3: Configure The Preamble

Add one narrow bootstrap block before `\begin{document}`. Adapt the TODO command
to the project instead of copying this example blindly:

```tex
% AGENTEDIT-BOOTSTRAP: AgentLaTeX package and project renderer.
\providecommand{\AgentEditRender}[4]{#4\todo{AI [#1]: #2}}
\usepackage{agentedit}
```

Define the default with `\providecommand` **before** the package load. This
preserves a renderer already selected by the original-view entry point. Do not
unconditionally redefine it in the main preamble after the wrapper selects it.
Preserve compatible project customizations; apply the same conditional default
pattern when adapting an existing TODO renderer.
The project default should render `#4`, the edited source, and show `#2`, the
reason. The stable ID is `#1`, and the retained original is `#3`.

Do not weaken validation in the main entry point. Strict validation is the
package default.

## Step 4: Add Review Entry Points

For local builds, create a top-level warning-mode wrapper and replace `main.tex`
with the actual entry-point filename:

```tex
% AGENTEDIT-BOOTSTRAP: Warning-mode review entry point.
\def\AgentWritingReportMode{1}
\input{main.tex}
```

An optional original-view wrapper can define a renderer before loading the real
entry point:

```tex
% AGENTEDIT-BOOTSTRAP: Original-view review entry point.
\def\AgentWritingReportMode{1}
\long\def\AgentEditRender#1#2#3#4{#3\todo{AI [#1]: #2}}
\input{main.tex}
```

If a build service requires the selected Main document itself to contain
`\documentclass`, keep the real paper file selected and use a mode file instead:

```tex
\InputIfFileExists{agentedit-overleaf.tex}{}{}
\usepackage{agentedit}
```

The mode file contains:

```tex
% Comment this line to restore strict validation.
\def\AgentWritingReportMode{1}
```

## Step 5: Record Project Policy

Update `AGENTS.md` with these non-negotiable rules:

- Every substantive `.tex` change uses a complete `blocks-v1` frame after that
  policy is activated; retain the four macro arguments ID/reason/original/proposal.
- Keep the minimal valid changed span, including word fragments. Two changes in
  one paragraph stay independent. Formatting must not widen payloads to paragraphs.
- Freeze original, ID, and right whitespace across proposal revisions. Tool
  context belongs outside payloads. Re-submit complete frames after denial.
- Preserve both synthetic separators, END's final newline, and raw interiors.
  Include a complete affected paragraph separator in the changed span when needed
  for both views; do not add decorative blank lines or comment labels between args.
- Additions have an empty original argument; deletions have an empty edited
  argument.
- Agents never modify the retained original or remove a wrapper.
- Only a human accepts or rejects an edit by removing its complete frame.
- Every agent-added citation comes from DBLP and remains marked `UNVERIFIED`
  until a human checks it.
- Every `.bib` change retains the commented old entry, active new entry, stable
  ID, reason, and DBLP URL in an `AGENT-EDIT-BEGIN` record.
- Agents do not bypass the hook with shell redirection, scripts, formatters, or
  alternate write tools.
- The bootstrap exception applies only to the exact setup files.

Preserve any stronger project-specific writing and citation rules already in
the file.

### Readable TeX example and ownership

Original: `The system always terminates.`

```tex
The system %
%%% AGENTEDIT START: word %%%
\agentedit{word}
  {Review this precise change.}
  {always}
  {usually} %
%%% AGENTEDIT END: word %%%
terminates.
```

IDs use `[A-Za-z0-9][A-Za-z0-9._:-]*`. Both banners must match the macro ID.
START, the macro/ID, reason, original, and proposal each begin on their own lines.
Wrapper indentation uses spaces or tabs. Preserve interiors exactly. Place all
original whitespace immediately following the changed span after the proposal's
closing brace and before the right `%`; the source after END begins with a
non-whitespace character or EOF. Both separator `%` characters and the newline
after END are mandatory, even at beginning/end of file. Do not place a separator
inside an existing comment or after an escaping backslash.

For manual review, the human selects from the left separator `%` through the
newline after END, and replaces it with the chosen argument's contents followed
by the whitespace before the right separator. Accept yields
`The system usually terminates.`; reject yields `The system always terminates.`.
Defer leaves the whole frame untouched. Only removing the macro leaves orphan
framing. Strict compilation detects macros, not orphan comments.

For a fragment of `international`, wrap only `nation` → `region`, between `inter`
and `al`, with no right whitespace. For inserting a line into `A` followed by a
blank line then `B`, replace the full two-newline separator with newline + new
line text + newline. An empty insertion splitting those two newlines changes the
original-view paragraph structure. Never include unchanged paragraph prose just
for layout. If a span cannot preserve valid arguments and both views, report it.

## Step 6: Enable The Guard

Add `.agentedit.json` after the package, renderer, and review entry points are in
place. List actual paths, not assumed names:

```json
{
  "version": 1,
  "tex_edit_format": "blocks-v1",
  "bootstrap_marker": "AGENTEDIT-BOOTSTRAP",
  "bootstrap_files": [
    "main.tex",
    "agent-review.tex",
    "agent-original-review.tex"
  ]
}
```

Never add section files or bibliography files to `bootstrap_files`.

For a new standalone project, activate `blocks-v1` only after local reader/manual
and native guard checks pass. For an existing shared project, finish the safe
local upgrade, but leave the `tex_edit_format` key absent until the owner confirms
that teammates have compatible reviewers or will follow the manual recipe.
Record activation as staged, with the exact readiness check still needed. Never
assume elapsed time or a local upgrade confirms teammate readiness.

An absent key keeps legacy validation. Do not use null or an empty string as a
staging value: present unsupported values and invalid JSON are configuration
errors. Existing compact records remain readable and need no bulk migration.
Do not downgrade with pending frames. An interrupted/repeated setup must preserve
manuscript content, custom renderers, and the previous policy until checks pass.

## Step 7: Verify Both Modes

Use a disposable smoke document or an existing unresolved marker. Do not add
test prose to the manuscript.

Verify the normal build:

- Returns a nonzero status for an unresolved marker.
- Logs `AGENT-EDIT-MARKER` with the stable ID and reason.
- Renders the edited source when compilation continues past the error.

Verify the review build:

- Produces a complete PDF.
- Emits warnings rather than marker errors.
- Displays the edited source and the reason TODO.
- Logs `AGENT-EDIT-REPORT` with the unresolved count.

Verify the actual original-view wrapper renders distinct OLD text, while the
proposed wrapper renders distinct NEW text, with the selected TODO style. Do not
substitute an isolated renderer test for these real entry points.

Exercise one disposable word edit: accept/reject must restore the exact expected
sentence, skip must keep the full block, and one undo must restore a decision.
For an editor/agent transfer, return reviewed source to the agent working copy
before requesting another edit; check concurrent editor changes before replacing
files so resolved records are not resurrected.

Delete disposable smoke files and their build artifacts after verification.

## Step 8: Report The Bootstrap

Tell the user:

- Which files were added or changed.
- Which renderer and TODO-note command were selected.
- The strict-build result and review-build result.
- The installed guard, active hook, and loaded reviewer capabilities separately.
- Whether blocks-v1 is active or staged, and which local/teammate/reload check
  remains; no-Emacs users use the manual decision recipe.
- The original/proposed entry-point and exact-source smoke results.
- Any project-specific limitation, especially an Overleaf Main-document issue.

Use the neutral label `AI` in newly created reason notes. Do not name the notes
after the current agent host because another agent may edit the same paper.

Do not claim the paper is clean merely because a warning-mode PDF exists.

## Removing setup from one paper

Keep a recoverable version. A human first resolves every pending edit with the
current reviewer or manual recipe, and checks for leftover macros and banners.
Then remove only this paper's AgentLaTeX package load/renderer, wrappers/mode
file, policy file, and owned AGENTS section; preserve unrelated TODO/build
configuration. Compile the ordinary paper without AgentLaTeX. Do not uninstall
personal integrations that other papers still use.
