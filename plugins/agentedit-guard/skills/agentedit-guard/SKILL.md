---
name: agentedit-guard
description: >-
  Enforce reviewable AI provenance whenever an agent edits LaTeX or BibTeX in a
  project containing .agentedit.json. Retain stable IDs, reasons, original
  source, edited source, and DBLP verification markers.
---

# AgentEdit Guard

Use this workflow for every `.tex` or `.bib` edit in a protected project.

## Bootstrap A New Project

Read `../../BOOTSTRAP.md` from the plugin root for the canonical, self-contained
bootstrap contract, then apply the workflow below to the target repository.

Complete bootstrap before making paper-facing edits:

1. Locate the AgentLaTeX plugin root from this skill. The distributable package
   is `latex/agentedit.sty` at that root.
2. Identify the project's real LaTeX entry point and read its preamble. Do not
   assume that it is named `main.tex`.
3. Copy `latex/agentedit.sty` to the paper project root. Keep it as a regular
   file, not a symlink or Git submodule, so the project remains portable to
   Overleaf.
4. In the entry-point preamble, add an `AGENTEDIT-BOOTSTRAP` comment, define any
   project-specific `\AgentEditRender`, and load `\usepackage{agentedit}`. The
   package default renders the edited source if no renderer is supplied.
5. If the project uses TODO notes, make the renderer append a note containing
   `#2`, the reason, and `#1`, the stable edit ID. Keep `#4`, the edited source,
   as the normal paper rendering.
6. Add a root-level review entry point that defines
   `\AgentWritingReportMode` before inputting the real entry point. If the build
   service cannot select wrapper entry points, add a small mode file that the
   real preamble loads before the package instead.
7. Add the TeX and BibTeX rules from this skill to the nearest `AGENTS.md`.
   Explicitly list the narrow bootstrap files; never exempt section files.
8. Add `.agentedit.json` last, with the same bootstrap file list. This activates
   hook enforcement for subsequent edits.
9. Run a normal build and confirm that an unresolved marker produces a package
   error. Run a report-mode build and confirm that it produces a PDF, warnings,
   each marker's reason, and the final unresolved-marker count.

Use this configuration shape:

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

### Overleaf Bootstrap

Keep `agentedit.sty`, the real Main document, and any `latexmkrc` file at the
Overleaf project top level. Add this immediately before loading the package:

```tex
\InputIfFileExists{agentedit-overleaf.tex}{}{}
\usepackage{agentedit}
```

Use `agentedit-overleaf.tex` only for mode selection:

```tex
% Comment this line to restore strict validation.
\def\AgentWritingReportMode{1}
```

Do not depend on a Git submodule for the style file. When GitHub synchronization
is used, commit the project-local `agentedit.sty` copy to the paper repository.

## Before Editing

1. Read the nearest `AGENTS.md` and `.agentedit.json`.
2. Read enough surrounding source to preserve the document's argument and style.
3. Capture the exact source being replaced before composing the edit.

## TeX Edits

Wrap each substantive change as:

```tex
\agentedit{stable-id}
  {Concise reason for the change.}
  {Exact original source.}
  {Edited source.}
```

Use an empty third argument for an addition and an empty fourth argument for a
deletion. Keep both versions balanced and valid as macro arguments. Do not alter
the original argument during later revisions. Do not remove the wrapper; only a
human reviewer accepts an edit by removing it.

The document controls display through `\AgentEditRender`. Do not change the
renderer merely to conceal unresolved edits. Validation remains active even when
the renderer hides one side.

## BibTeX Edits

BibTeX entries cannot be wrapped in a LaTeX macro. Use this exact structure:

```bibtex
% AGENT-EDIT-BEGIN: stable-id
% REASON: Concise reason for the change.
% OLD:
% <every original line remains commented>
% NEW:
<active edited entry>
% AGENT-EDIT-END: stable-id
```

For an addition, write `% OLD: (none)`. Every agent-added or agent-modified
citation must use metadata from DBLP and include both an unverified record comment
and the persistent DBLP BibTeX URL:

```bibtex
% UNVERIFIED: DBLP https://dblp.org/rec/<record>
biburl = {https://dblp.org/rec/<record>.bib},
```

Only a human may remove the `UNVERIFIED` marker after checking the record and the
claim it supports.

## Bootstrap Exception

The project may designate a narrow `AGENTEDIT-BOOTSTRAP` marker for the files or
lines that load and configure AgentEdit itself. Never use that marker for
paper-facing prose, bibliography data, or ordinary structural edits.

Do not bypass the hook with shell redirection, scripts, formatters, or alternate
write tools. If the hook blocks a legitimate edit, expand the proposed edit so
the complete provenance record is visible to the validator.
