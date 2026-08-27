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
already installed, use its `agentedit-guard` skill and continue to Step 1.

On command-line hosts, install the current release when it is missing:

```sh
# Codex
codex plugin marketplace add chughtapan/agentlatex --ref v0.3.0
codex plugin add agentedit-guard --marketplace agentlatex

# Claude Code
claude plugin marketplace add chughtapan/agentlatex@v0.3.0
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
https://raw.githubusercontent.com/chughtapan/agentlatex/main/latex/agentedit.sty
```

Commit the copied file to the paper repository. Do not use a symlink or Git
submodule because Overleaf projects cannot contain submodules.

## Step 3: Configure The Preamble

Add one narrow bootstrap block before `\begin{document}`. Adapt the TODO command
to the project instead of copying this example blindly:

```tex
% AGENTEDIT-BOOTSTRAP: AgentLaTeX package and project renderer.
\usepackage{agentedit}

\long\def\AgentEditRender#1#2#3#4{%
  #4\todo{AI [#1]: #2}%
}
```

If the renderer is defined before the package load, use `\def`; the package will
preserve it. If it is defined after the package load, `\renewcommand` also works.
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

- Every substantive `.tex` change uses
  `\agentedit{stable-id}{reason}{original}{edited}`.
- Additions have an empty original argument; deletions have an empty edited
  argument.
- Agents never modify the retained original or remove a wrapper.
- Only a human accepts an edit by removing its wrapper.
- Every agent-added citation comes from DBLP and remains marked `UNVERIFIED`
  until a human checks it.
- Every `.bib` change retains the commented old entry, active new entry, stable
  ID, reason, and DBLP URL in an `AGENT-EDIT-BEGIN` record.
- Agents do not bypass the hook with shell redirection, scripts, formatters, or
  alternate write tools.
- The bootstrap exception applies only to the exact setup files.

Preserve any stronger project-specific writing and citation rules already in
the file.

## Step 6: Enable The Guard

Add `.agentedit.json` after the package, renderer, and review entry points are in
place. List actual paths, not assumed names:

```json
{
  "version": 1,
  "bootstrap_marker": "AGENTEDIT-BOOTSTRAP",
  "bootstrap_files": [
    "main.tex",
    "agent-review.tex",
    "agent-original-review.tex"
  ]
}
```

Never add section files or bibliography files to `bootstrap_files`.

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

Delete disposable smoke files and their build artifacts after verification.

## Step 8: Report The Bootstrap

Tell the user:

- Which files were added or changed.
- Which renderer and TODO-note command were selected.
- The strict-build result and review-build result.
- Whether the guard plugin is installed and active.
- Any project-specific limitation, especially an Overleaf Main-document issue.

Use the neutral label `AI` in newly created reason notes. Do not name the notes
after the current agent host because another agent may edit the same paper.

Do not claim the paper is clean merely because a warning-mode PDF exists.
