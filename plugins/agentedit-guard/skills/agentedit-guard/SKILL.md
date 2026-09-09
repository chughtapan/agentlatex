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

Read [the bootstrap contract](../../BOOTSTRAP.md), relative to this skill
directory, then apply the workflow below to the target repository.

Complete bootstrap before making paper-facing edits:

1. Locate the AgentLaTeX plugin root from this skill. The distributable package
   is `latex/agentedit.sty` at that root.
2. Identify the project's real LaTeX entry point and read its preamble. Do not
   assume that it is named `main.tex`.
3. Copy `latex/agentedit.sty` to the paper project root. Keep it as a regular
   file, not a symlink or Git submodule, so the project remains portable to
   Overleaf.
4. In the entry-point preamble, add an `AGENTEDIT-BOOTSTRAP` comment, define the
   project default `\AgentEditRender` with `\providecommand` before loading
   `\usepackage{agentedit}`, and preserve any renderer already selected by an
   original-view wrapper. The package default renders the edited source if no
   renderer is supplied.
5. If the project uses TODO notes, make the renderer append a note containing
   `#2`, the reason, and `#1`, the stable edit ID. Keep `#4`, the edited source,
   as the normal paper rendering.
6. Add a root-level review entry point that defines
   `\AgentWritingReportMode` before inputting the real entry point. If the build
   service cannot select wrapper entry points, add a small mode file that the
   real preamble loads before the package instead.
7. Add the TeX and BibTeX rules from this skill to the nearest `AGENTS.md`.
   Explicitly list the narrow bootstrap files; never exempt section files.
8. Add `.agentedit.json` last, with the same bootstrap file list. Stage `tex_edit_format` until the
   installed guard, active native hook, and loaded reviewer/manual route pass
   capability checks. In an existing shared project, also wait for the owner's
   confirmation that teammates can review frames. An absent format key retains
   legacy validation; it does not mean the hook is active.
9. Run a normal build and confirm that an unresolved marker produces a package
   error. Run a report-mode build and confirm that it produces a PDF, warnings,
   each marker's reason, and the final unresolved-marker count.

After those readiness checks, use this configuration shape:

```json
{
  "version": 1,
  "tex_edit_format": "blocks-v1",
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

Read `tex_edit_format` from the project policy. An absent key keeps the legacy
four-argument macro contract. A present key must equal `blocks-v1`; fix invalid
configuration instead of silently falling back. For blocks-v1 use this format:


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


Keep ID, original, and retained whitespace frozen when revising a proposal.
Only a human may resolve a record. Legacy records outside a targeted edit remain
untouched; do not bulk-convert. A whole-file Write must frame every submitted
record. Converting a legacy record during revision preserves its original and
safe ID; an unsafe ID needs a human decision.

Use a unique exact `old_string`/`oldText` (including unchanged tool context outside
payloads) or an LF patch containing each complete new frame. Update hunks must
match unique exact whole-line context and appear in source order. Sequential
MultiEdit members use the previous member's resulting source. `replace_all`,
ambiguous anchors, named `@@` anchors, unprefixed blank context, repeated file
headers, patch moves, EOF directives, files without a final newline, and CRLF
patches are unsupported: retry with an exact Edit or a whole-file Write preserving
the original line endings.
After denial, resend the complete frame including both separators and END's
newline; do not enlarge the changed payload to supply tool context.
For a patch revision, remove and re-add every frame line with `-`/`+` prefixes,
including unchanged banners and arguments. Space-prefixed context lines do not
submit those parts of the frame. Keep the original/proposed payloads precise.

Standalone optional indentation followed by `%%% AGENTEDIT` and a space, tab,
colon, or line ending reserves the structural namespace. Damaged, indented,
orphaned, nested, crossed, or duplicate frames are errors. For an illustrative
comment use an extra percent, such as `%%%% AGENTEDIT START: sample %%%`.
Comments and verbatim examples are opaque; raw arguments remain unchanged.

The document controls display through `\AgentEditRender`. Do not change the
renderer to conceal unresolved edits. Both original and proposed preview modes
must work; strict validation remains active even if a renderer hides one side.

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
write tools. If the hook blocks a legitimate edit, resubmit the complete frame with sufficient unchanged tool context outside
the payloads. Do not widen the original merely to change presentation.
