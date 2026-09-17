# AgentLaTeX

[![CI](https://github.com/chughtapan/agentlatex/actions/workflows/ci.yml/badge.svg)](https://github.com/chughtapan/agentlatex/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Want an agent to edit your paper, but worried about what it might change?
AgentLaTeX makes agent edits behave like compiler-enforced tracked changes.
Every revision stays next to the original source and includes a stable ID and
the agent's reason. You read the proposed paper by default, but the build stays
red until a human accepts every outstanding edit.

## Set up a paper

Open the paper's top-level folder in Codex, Claude Code, the Claude Desktop Code
tab, or Cowork. Paste this prompt:

```text
Set up AgentLaTeX in this LaTeX repository. Follow
https://raw.githubusercontent.com/chughtapan/agentlatex/v0.4.0/BOOTSTRAP.md
exactly. If Emacs is available, install the reviewer in my personal Emacs
configuration. Do not change manuscript content during setup. Finish every
step you can, verify the installation, and tell me only what needs human action.
```

That's it. The agent detects the document entry point and existing TODO style,
installs the guard for the current host, adds the shared project files, and
checks strict and review builds. If a plugin UI needs approval, approve that
single request and tell the agent to continue.

The same prompt works when a repository already uses AgentLaTeX. It verifies
the shared setup and installs the current teammate's local integrations. In an
existing shared paper, readable framing activates only after the owner confirms
that teammates have compatible reviewers or will use the manual recipe. Local
installation can finish while that shared activation remains staged.

## Review edits

**In Overleaf or another source editor:** search for `%%% AGENTEDIT START:`.
Each block shows a stable ID, reason, exact original, and proposal on separate
lines. Follow the [source-editor decision recipe](docs/readable-edits.md#decide-in-a-source-editor-including-overleaf)
to accept, reject, or defer an edit while preserving the surrounding source.

**In Emacs:** open a project `.tex` file and run `M-x agentedit-review`. Use `A`
to accept, `R` to restore the original, or `S` to decide later. Each word or
fragment stays an independent comparison within its LaTeX paragraph. Use
`C-c w` for the whole current file, `C-c e` to edit the result, and `C-c C-c`
to stage a custom draft. AUCTeX follows the complete master paper. `A` and
`R` remove the complete frame as one undo step and save the owning source by
default, including any earlier unsaved edits in that file. Set
`agentedit-review-auto-save` to nil before starting for manual saving; the
invocation buffer's setting applies to the full review pass. `C-c l` opens a
persistent report of each file's decisions and save status.
See the [Emacs guide](emacs/README.md).

Try both routes on the [disposable two-edit sample](examples/readable-review.tex).
The [readable-edit guide](docs/readable-edits.md) explains the format and gives
exact expected results for a first review.

To preview PDFs, compile `agent-review.tex` for proposed text or
`agent-original-review.tex` for original text. The ordinary paper entry point
stays strict and rejects unresolved macros.

## See what a precise edit contains

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

The change is only `always` → `usually`. The banners make it easier to find;
unchanged paragraph text stays outside the decision. Only a human resolves the
edit. Old compact macros remain reviewable without bulk conversion.

## Share the setup

Commit the files created in the paper repository: `agentedit.sty`,
`.agentedit.json`, `AGENTS.md`, and the review entry points. Keep personal
plugin and Emacs configuration outside the paper repository.

Teammates pull those shared files and paste the same setup prompt. AgentLaTeX
repairs missing project pieces and handles each teammate's local installation.

Guard integrations are provided for Codex, Claude Code, Claude Desktop Code,
and Cowork. Setup verifies the active host after any required reload; installed
files alone do not prove that a hook is running.
Ordinary Claude Chat can follow the editing contract but cannot enforce it with
a hook.

## Read more

- [Agent bootstrap contract](BOOTSTRAP.md)
- [Guard editing contract](plugins/agentedit-guard/skills/agentedit-guard/SKILL.md)
- [Emacs and AUCTeX reviewer guide](emacs/README.md)
- [Overleaf guide](overleaf/README.md)
- [Contributor guide](CONTRIBUTING.md)
- [Release history](CHANGELOG.md)

AgentLaTeX is experimental. Report problems through the
[AgentLaTeX issue tracker](https://github.com/chughtapan/agentlatex/issues).
