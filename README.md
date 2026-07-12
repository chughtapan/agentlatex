# AgentLaTeX

[![CI](https://github.com/chughtapan/agentlatex/actions/workflows/ci.yml/badge.svg)](https://github.com/chughtapan/agentlatex/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Want an agent to edit your paper, but worried about what it might change?
AgentLaTeX makes agent edits behave like compiler-enforced tracked changes.
Every revision stays next to the original source and includes a stable ID and
the agent's reason. You read the proposed paper by default, but the build stays
red until a human accepts every outstanding edit.

A small LaTeX package handles rendering and validation. An optional Codex
plugin prevents agents from writing untracked changes.

```tex
\agentedit{intro-claim}
  {State the measured scope instead of making a universal claim.}
  {The system always terminates.}
  {The system terminated in every measured run.}
```

AgentLaTeX includes:

- `agentedit.sty`, a small LaTeX package with strict and review validation.
- `agentedit-guard`, a Codex plugin that blocks unmarked `.tex` and `.bib`
  edits in protected projects.
- Bootstrap instructions for local LaTeX projects and Overleaf.

## Point Your Agent Here

Paste this into an agent working in your LaTeX repository:

```text
Set up AgentLaTeX in this repository. Read
https://github.com/chughtapan/agentlatex/blob/main/BOOTSTRAP.md and follow it
exactly. Do not edit manuscript prose during bootstrap. Configure the renderer
to show each edit reason using this project's existing TODO-note style. Verify
both the strict build and the warning-mode review build before finishing.
```

[Open the complete agent bootstrap contract](BOOTSTRAP.md).

For Codex, install the guard first:

```sh
codex plugin marketplace add chughtapan/agentlatex --ref main
codex plugin add agentedit-guard --marketplace agentlatex
```

Then tell Codex:

```text
Use the agentedit-guard skill to bootstrap AgentLaTeX in this project. Show edit
reasons with the project's existing TODO-note command.
```

## Five-Minute Setup

1. Put [`latex/agentedit.sty`](latex/agentedit.sty) in the paper repository's
   top-level directory.
2. Load it in the document preamble:

   ```tex
   % AGENTEDIT-BOOTSTRAP: AgentLaTeX package setup.
   \usepackage{agentedit}
   ```

3. Add a warning-mode review entry point:

   ```tex
   % agent-review.tex
   % AGENTEDIT-BOOTSTRAP: Warning-mode review entry point.
   \def\AgentWritingReportMode{1}
   \input{main.tex}
   ```

4. Add `.agentedit.json` last to activate the Codex hook:

   ```json
   {
     "version": 1,
     "bootstrap_marker": "AGENTEDIT-BOOTSTRAP",
     "bootstrap_files": [
       "main.tex",
       "agent-review.tex"
     ]
   }
   ```

The package default renders the edited source. Its normal validation mode emits
a package error for every unresolved marker. Defining
`\AgentWritingReportMode` before loading the package changes those errors to
warnings and prints a final marker count, allowing a complete review PDF.

## Show Reasons As TODOs

Rendering is ordinary preamble LaTeX, independent of validation. Redefine the
four-argument hook after loading the package:

```tex
\usepackage{agentedit}

\long\def\AgentEditRender#1#2#3#4{%
  #4\todo{Codex [#1]: #2}%
}
```

The arguments are:

| Argument | Meaning |
| --- | --- |
| `#1` | Stable edit ID |
| `#2` | Reason |
| `#3` | Original source |
| `#4` | Edited source |

Other useful renderers are:

```tex
% Original source only
\renewcommand{\AgentEditRender}[4]{#3}

% Edited source only, which is the package default
\renewcommand{\AgentEditRender}[4]{#4}

% Both versions with project-specific review markup
\renewcommand{\AgentEditRender}[4]{%
  \par\noindent\textbf{Original [#1]:} #3%
  \par\noindent\textbf{Edited [#1]:} #4%
  \par\noindent\textbf{Reason:} #2%
}
```

Changing the renderer never disables strict validation.

## Review Contract

For TeX, agents must use:

```tex
\agentedit{stable-id}
  {Concise reason.}
  {Exact original source.}
  {Proposed source.}
```

Additions use an empty original argument. Deletions use an empty proposed
argument. Only a human reviewer should remove the wrapper or alter the retained
original.

BibTeX cannot evaluate a LaTeX macro, so the guard requires a comment-delimited
record. It also enforces this project's DBLP-only citation policy:

```bibtex
% AGENT-EDIT-BEGIN: source-key
% REASON: Add a DBLP-indexed source for the stated claim.
% OLD: (none)
% NEW:
% UNVERIFIED: DBLP https://dblp.org/rec/<record>
@article{source-key,
  ...
  biburl = {https://dblp.org/rec/<record>.bib}
}
% AGENT-EDIT-END: source-key
```

Only a human removes `UNVERIFIED` after checking both the record and the claim.

## Overleaf

Put `agentedit.sty` at the Overleaf project top level, where Overleaf finds
custom style files by default. Keep the actual paper file selected as the Main
document. For a switchable review build, add this before the package load:

```tex
\InputIfFileExists{agentedit-overleaf.tex}{}{}
\usepackage{agentedit}
```

Copy [`overleaf/agentedit-overleaf.tex.example`](overleaf/agentedit-overleaf.tex.example)
to `agentedit-overleaf.tex`. Leave the definition active for a complete
warning-mode review PDF; comment it to restore strict validation.

Overleaf does not support Git submodules inside a project, so commit the
project-local `agentedit.sty` copy rather than adding AgentLaTeX as a submodule.
See the [complete Overleaf setup](overleaf/README.md), including `latexmkrc` and
GitHub synchronization guidance.

## How Enforcement Works

The Codex plugin activates only below a directory containing `.agentedit.json`.
Its `PreToolUse` hook inspects direct write tools, patches, and common mutating
shell commands. A proposed TeX change must expose a complete four-argument
`\agentedit` call. A proposed BibTeX change must expose the complete provenance
record and DBLP metadata.

`AGENTEDIT-BOOTSTRAP` is a narrow escape marker for the exact files listed in
`.agentedit.json`. It exists because the files that load the provenance package
cannot wrap that package load in the macro being defined. Do not list manuscript
section files as bootstrap files.

The hook is a development guardrail, not a security boundary. Arbitrary local
programs and humans can still modify files. The skill therefore also instructs
agents not to bypass it with alternate write paths.

## Repository Layout

```text
latex/agentedit.sty                 LaTeX package
skills/agentedit-guard/SKILL.md     Codex workflow and bootstrap policy
scripts/guard_agent_edits.py        PreToolUse validator
overleaf/                            Overleaf mode file and setup
examples/                            Warning and strict build examples
tests/                               Guard tests
```

## Development

Run the guard tests:

```sh
python3 -m unittest discover -s tests -v
```

Compile the warning-mode example:

```sh
cd examples
TEXINPUTS=../latex: pdflatex -interaction=nonstopmode example.tex
```

The strict example is expected to return a nonzero status while still producing
a PDF containing the edited source:

```sh
TEXINPUTS=../latex: pdflatex -interaction=nonstopmode strict-example.tex
```

AgentLaTeX is released under the [MIT License](LICENSE).
