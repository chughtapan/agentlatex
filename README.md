# AgentLaTeX

[![CI](https://github.com/chughtapan/agentlatex/actions/workflows/ci.yml/badge.svg)](https://github.com/chughtapan/agentlatex/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Want an agent to edit your paper, but worried about what it might change?
AgentLaTeX makes agent edits behave like compiler-enforced tracked changes.
Every revision stays next to the original source and includes a stable ID and
the agent's reason. You read the proposed paper by default, but the build stays
red until a human accepts every outstanding edit.

A small LaTeX package handles rendering and validation. An optional guard
plugin prevents Codex and Claude from writing untracked changes.

```tex
\agentedit{intro-claim}
  {State the measured scope instead of making a universal claim.}
  {The system always terminates.}
  {The system terminated in every measured run.}
```

AgentLaTeX includes:

- `agentedit.sty`, a small LaTeX package with strict and review validation.
- `agentedit-guard`, a Codex and Claude plugin that blocks unmarked `.tex` and
  `.bib` edits in protected projects.
- `agentedit-review`, a keyboard-first Emacs command backed by native Ediff.
- Bootstrap instructions for local LaTeX projects and Overleaf.

## One-Prompt Setup

Open the paper's top-level folder in Codex, Claude Code, Claude Desktop Code, or
Cowork. Then paste this prompt:

```text
Install and configure AgentLaTeX in this LaTeX repository. Read
https://raw.githubusercontent.com/chughtapan/agentlatex/main/BOOTSTRAP.md and
follow the complete contract. Detect this agent host, the real document entry
point, the project's existing TODO-note style, and its build commands instead
of asking me for routine setup details. Install AgentEdit Guard for this host
when plugins are supported; if the host requires a human approval in its plugin
UI, ask me only for that approval and then continue. Use the neutral label `AI`
for edit reasons. Do not edit manuscript prose or bibliography data during
setup. Verify the strict build, the warning-mode review build, and guard
availability before finishing, and report any host limitation honestly.
```

[Open the complete agent bootstrap contract](BOOTSTRAP.md).

The agent performs project discovery, copies the portable style file, configures
the renderer and review entry points, records the project policy, enables the
guard, and runs the available checks. Setup is idempotent: in a repository that
already uses AgentLaTeX, the agent verifies and repairs the installation instead
of adding a second copy.

Command-line hosts can install the guard automatically. These are the equivalent
manual commands for Codex:

```sh
codex plugin marketplace add chughtapan/agentlatex --ref v0.3.0
codex plugin add agentedit-guard --marketplace agentlatex
```

And for Claude Code:

```sh
claude plugin marketplace add chughtapan/agentlatex@v0.3.0
claude plugin install agentedit-guard@agentlatex
```

Claude Desktop may require the one human step that an agent cannot perform:
open **Customize** → **Plugins** → **Add marketplace**, add
`https://github.com/chughtapan/agentlatex`, and install AgentEdit Guard. Resume
the same conversation afterward. Hooks run in Cowork and the Desktop Code tab;
ordinary Claude Chat can follow the editing skill but cannot run the guard hook.

### Share With Your Team

Commit the project-local setup files (`agentedit.sty`, `.agentedit.json`, the
review entry points, and `AGENTS.md`) with the paper. Teammates can then open the
repository and paste the same prompt; it will verify the shared setup and handle
their per-host guard installation.

For a small team, share the GitHub marketplace URL above. Claude Team and
Enterprise owners can instead add that marketplace once in
[organization plugin settings](https://support.claude.com/en/articles/13837433-manage-plugins-for-your-organization)
and make AgentEdit Guard available, installed by default, or required.
Plugin approval is per host or centrally managed; the LaTeX review contract
itself stays in the paper repository.

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

4. Add `.agentedit.json` last to activate the installed guard hook:

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

## Review in Emacs

The experimental reviewer supports Emacs 29.4 and newer and loads directly
from a repository checkout:

```elisp
(use-package agentedit-review
  :ensure nil
  :commands (agentedit-review)
  :load-path "/absolute/path/to/agentlatex/emacs")
```

Open a writable, widened TeX buffer and run `M-x agentedit-review`. In an AUCTeX
buffer, the command reviews the complete master document. In a built-in TeX
buffer, it reviews the current file from point. Use `C-u M-x agentedit-review`
to force current-file review from point under AUCTeX.

- `A` accepts the proposed source.
- `R` restores the original source.
- `S` leaves the wrapper unresolved and advances.
- `q` confirms before stopping the pass.

Accept and reject are isolated undo steps. The command never saves the source
buffer, and a stale wrapper is never overwritten. See the
[complete team setup, AUCTeX behavior, configuration, and troubleshooting
guide](emacs/README.md).

## Show Reasons As TODOs

Rendering is ordinary preamble LaTeX, independent of validation. Redefine the
four-argument hook after loading the package:

```tex
\usepackage{agentedit}

\long\def\AgentEditRender#1#2#3#4{%
  #4\todo{AI [#1]: #2}%
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

The plugin activates for a target below a directory containing
`.agentedit.json`. Its `PreToolUse` hook inspects direct write tools, patches,
common filesystem MCP edits, and common mutating shell commands. Each proposed
TeX mutation must expose a complete four-argument `\agentedit` call. Each
proposed BibTeX mutation must expose the complete provenance record and DBLP
metadata.

Host | Skill | Guard hook
--- | --- | ---
Codex | Yes | Yes
Claude Code CLI or Desktop Code | Yes | Yes
Claude Desktop Cowork | Yes | Yes
Claude Chat | Yes | No

The hook runtime must expose Python 3.10 or newer as `python3`. AgentLaTeX does
not pin a Claude release; use a current Claude Code or Desktop build with plugin
hooks. The version 0.3.0 manifests pass Claude Code 2.1.246 validation. Run a
Cowork smoke test after installation because hooks execute in its environment.

`AGENTEDIT-BOOTSTRAP` is a narrow escape marker for the exact files listed in
`.agentedit.json`. It exists because the files that load the provenance package
cannot wrap that package load in the macro being defined. Do not list manuscript
section files as bootstrap files.

The hook is a development guardrail, not a security boundary. Arbitrary local
programs, unsupported MCP write schemas, computer-use actions, and humans can
still modify files. The skill therefore also instructs agents not to bypass it
with alternate write paths.

## Repository Layout

```text
latex/agentedit.sty                                  LaTeX package
.agents/plugins/marketplace.json                     Codex marketplace
.claude-plugin/marketplace.json                       Claude marketplace
plugins/agentedit-guard/                              Shared guard plugin
emacs/                                                Emacs reviewer and guide
overleaf/                                             Overleaf setup
examples/                                             Build examples
tests/                                                Distribution tests
```

## Development

Run the guard tests:

```sh
python3 -m unittest discover -s tests -v
```

Run the built-in-mode Emacs tests with Emacs 29.4 or newer:

```sh
emacs --batch -Q -L emacs \
  -l tests/emacs/agentedit-review-tests.el \
  -f ert-run-tests-batch-and-exit
```

CI runs the suite with Emacs 29.4 and 30.2, both with built-in TeX and with
AUCTeX 14.1.0 and 14.1.2.

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
