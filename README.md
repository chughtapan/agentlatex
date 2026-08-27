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
https://raw.githubusercontent.com/chughtapan/agentlatex/v0.3.0/BOOTSTRAP.md
exactly. If Emacs is available, install the reviewer in my personal Emacs
configuration. Do not change manuscript content during setup. Finish every
step you can, verify the installation, and tell me only what needs human action.
```

That's it. The agent detects the document entry point and existing TODO style,
installs the guard for the current host, adds the shared project files, and
checks strict and review builds. If a plugin UI needs approval, approve that
single request and tell the agent to continue.

The same prompt works when a repository already uses AgentLaTeX. It verifies
the shared setup and installs only the current teammate's local integrations.

## Review edits

In Emacs, open any project `.tex` file and run:

```text
M-x agentedit-review
```

With AUCTeX, the command follows `TeX-master` and reviews the complete paper.
Use `A` to accept, `R` to restore the original, or `S` to decide later.
The reviewer changes the buffer but does not save it.

Without Emacs, compile `agent-review.tex` to read proposed text or
`agent-original-review.tex` to read retained original text. The normal paper
entry point stays strict and rejects unresolved edits.

## See what an edit contains

```tex
\agentedit{intro-claim}
  {State the measured scope instead of making a universal claim.}
  {The system always terminates.}
  {The system terminated in every measured run.}
```

The four arguments are a stable ID, the reason, the exact original source, and
the proposed source. Only a human reviewer removes the wrapper or changes the
retained original.

## Share the setup

Commit the files created in the paper repository: `agentedit.sty`,
`.agentedit.json`, `AGENTS.md`, and the review entry points. Keep personal
plugin and Emacs configuration outside the paper repository.

Teammates pull those shared files and paste the same setup prompt. AgentLaTeX
repairs missing project pieces and handles each teammate's local installation.

Guard hooks run in Codex, Claude Code, Claude Desktop Code, and Cowork.
Ordinary Claude Chat can follow the editing contract but cannot enforce it with
a hook.

## Read more

- [Agent bootstrap contract](BOOTSTRAP.md)
- [Emacs and AUCTeX reviewer guide](emacs/README.md)
- [Overleaf guide](overleaf/README.md)
- [Contributor guide](CONTRIBUTING.md)
- [Release history](CHANGELOG.md)

AgentLaTeX is experimental. Report problems through the
[AgentLaTeX issue tracker](https://github.com/chughtapan/agentlatex/issues).
