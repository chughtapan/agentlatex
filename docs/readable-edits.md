# Review readable edits

Readable blocks keep each change as small as a word or a word fragment. The
banners make it easy to find in a source editor; they do not make the whole
paragraph one decision. This format is called `blocks-v1` and requires the
0.4.0 guard and Emacs reviewer, or the manual procedure below.

## Find the original and proposal

Suppose the original sentence is `The system always terminates.`:

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

The four arguments are **ID**, **reason**, **original**, and **proposal**, in
that order. Here the change is only `always` → `usually`. The space after the
proposal's closing brace is the original space before `terminates.`. The two
separator `%` characters suppress the extra source line breaks.

Search for `%%% AGENTEDIT START:` to find edits. Empty `{}` means there is no
text on that side: an insertion has an empty original and a deletion has an
empty proposal. Whitespace inside an argument is real source, even if the pane
looks blank. Never reindent or trim argument interiors just to tidy the frame.

## Decide in a source editor, including Overleaf

For each complete block:

1. Read the reason and compare the third and fourth arguments.
2. Select from the separator `%` just before START through the newline just
   after END. Include both banners, the complete macro, and both separators.
   Preserve the sentence prefix before that first `%`.
3. Replace that selection with the chosen argument's **contents**, followed by
   the whitespace between the fourth closing brace and the right separator `%`.
   Exclude the argument's enclosing braces. Accept chooses the fourth argument;
   reject chooses the third. Keep the following source exactly where it is.
4. Check the resulting sentence and compile. Undo the replacement if it is wrong.
   To defer, leave the entire block untouched.

Accepting the example yields `The system usually terminates.`; rejecting yields
`The system always terminates.`. There should be no banner or separator left.
Removing only `\agentedit` leaves framing behind and is incomplete cleanup.
The strict compiler finds unresolved macros; it does not validate orphan comments.

## Decide in Emacs

Run `M-x agentedit-review`. In a review from point, placing point anywhere inside
a frame includes that edit. AUCTeX reviews the master and its included files;
`C-u M-x agentedit-review` limits either mode family to the current file.

`A` accepts, `R` rejects, `S` defers, and `q` stops. The panes contain just the
original and proposed argument interiors, so a word-sized edit stays word-sized.
The reviewer removes the complete frame, preserves the right whitespace, and
creates one undo step per decision. It does not save the source. Empty and
whitespace-only panes have descriptive headers outside their text.

For full ID, reason, source path, and line, use `C-h e` to read the latest
AgentEdit announcement. From the control buffer, use `C-x b` to visit that source
buffer, then `M-x goto-line` with the announced line to inspect the sentence.
Return with `C-x b` to the Ediff control buffer to decide. Visiting source does
not end the session. If you change an edit or its relevant context while reviewing,
the reviewer stops; inspect the source and restart. Undo during an active pass may
also invalidate a neighboring record, so finish or quit before undoing decisions.

See the [Emacs guide](../emacs/README.md) for installation and troubleshooting.

## Try two independent decisions

Use a disposable copy of [the review sample](../examples/readable-review.tex).
Accept `sample-frequency`, reject `sample-speed`, and leave the paper untouched.
The final sentence must read `The system usually terminates quickly.`. Each
original/proposed pane should contain only one word. Undo twice to restore both
complete blocks. The source-editor procedure and Emacs keys produce the same
result.

To exercise an agent on a disposable plain copy, use this prompt:

```text
In the disposable sample only, change “always” to “usually” and “quickly” to
“promptly” in “The system always terminates quickly.” Use two independent
blocks-v1 edits, each containing only its changed word. Retain each original
and its following whitespace exactly. Do not change the manuscript.
```

## Compatibility and activation

| Project state | Action |
| --- | --- |
| No `tex_edit_format` key | Existing compact macro policy continues. |
| `"tex_edit_format": "blocks-v1"` | Every submitted TeX edit needs complete readable framing. |
| Unknown value or malformed policy | Fix the configuration error; there is no legacy fallback. |
| Compact macro outside a targeted edit | Remains reviewable and need not be converted. |
| Whole-file Write | All visible submitted records must be framed, including old compact calls. |
| Shared project with an older reviewer | Stage local upgrades; activate only after the owner confirms all reviewers are ready. |

The current reviewer accepts both formats. Do not bulk-convert existing records.
A revised legacy record may adopt framing if its ID is safe and its exact original
is retained. An unsafe legacy ID needs a human decision; agents must not silently
rename it. Older reviewers only know the macro extent and cannot clean up a
readable frame. Do not downgrade while frames remain.

The guard supports whole-file Write, unique exact Edit aliases, sequential
MultiEdit, and LF Add/Update File patches. Every changed range must submit a
complete frame. For revisions, include the existing left separator through END's
newline and preserve the ID, original, and retained whitespace. Use unchanged
context outside the payloads to disambiguate an exact match. Missing/ambiguous
anchors, named `@@` anchors, unprefixed blank context, repeated file headers, `replace_all`, patch moves, EOF directives, files without a final newline, and patches against CRLF
files require an exact Edit or a whole-file Write. Retrying must never widen the
original payload to a paragraph merely to provide tool context.

LF and CRLF sources retain their original decoded text. Exact Edit/Write must
preserve CRLF; Emacs preserves the visited file's coding system. Mixed line
endings are not a supported file round-trip: normalize deliberately outside an
active review with a human decision, or use a tool that preserves the exact bytes.

## Format contract for implementers

With ordinary TeX catcodes, let original source be `P + old + W + S`, where `W`
is the maximal run of spaces, tabs, LF, or CRLF immediately after the replaced
span, and `S` begins with a non-whitespace character or is empty. Serialize:

```text
P + "%" + EOL + START + EOL
  + "\agentedit{id}" + EOL
  + "  {reason}" + EOL + "  {old}" + EOL + "  {new}"
  + W + "%" + EOL + END + EOL + S
```

`START` is exactly `%%% AGENTEDIT START: id %%%`, and END substitutes `END` for
`START`. IDs match `[A-Za-z0-9][A-Za-z0-9._:-]*`. Both synthetic separators and
the final END newline are mandatory even at beginning/end of file. Argument
openings after the ID begin on new lines; their indentation uses only spaces or
tabs. No comment labels or other text may occur between arguments. Preserve raw
interiors, including their newlines and comment-only lines. Whitespace used for
presentation is outside those interiors.

Standalone lines beginning with optional spaces/tabs and `%%% AGENTEDIT`
followed by a space, tab, colon, or end of line reserve the structural namespace.
Indented, truncated, orphaned, mismatched, duplicate, crossed, or nested frames
are errors. Extra-percent examples such as `%%%% AGENTEDIT START: example %%%`
are ordinary comments. Comments, `\verb`, and configured verbatim environments
are opaque; banner text inside an already parsed argument remains payload data.
The parsers do not interpret arbitrary catcode changes or promise that a macro
can be inserted in every LaTeX command position.

A decision owns the source from the left separator to after END's newline and
replaces it with `chosen + W`. A review also remembers the left physical-line
prefix and the first suffix character/EOF. It rechecks lexical visibility before
replacement. Known earlier decisions may update affected queued context only
from that known splice; arbitrary source changes are never silently adopted.

For a fragment change in `international`, use `nation` → `region` inside a frame
between `inter` and `al`, with no retained whitespace. For deleting a word and
its adjacent separating space, that removed space belongs inside the changed
payload. For inserting a line into `A\n\nB`, retain the complete paragraph
separator as the original (`\n\n`) and use `\nword\n` as the proposal. An empty
original inserted between the two newlines changes the original-view paragraph
structure. Include affected separator/comment-only lines, never unchanged
paragraph prose just for presentation. If the requested span cannot preserve
both valid macro arguments and rendering, report the limitation.

## Stop using AgentLaTeX in one paper

First save or commit a recoverable version. As a human, resolve or defer a decision
about every pending macro; complete removal requires resolving all of them with
the current reviewer or the procedure above. Search both `\agentedit` and the
reserved banner namespace and inspect any leftovers. Then remove only this
paper's AgentLaTeX package load/default renderer, review wrappers or mode file,
policy file, and AgentLaTeX section in `AGENTS.md`. Preserve unrelated TODO and
build configuration. Compile the ordinary paper without AgentLaTeX. Personal
plugins and Emacs setup may still serve other papers and need not be removed.

## Recover an interrupted or older review

If an older reviewer already removed only the macro, restore the pre-decision
source with undo or version history. Then review again with the compatible
reader or complete manual procedure. Do not guess at ownership or use a regex to
strip leftover separators: it can remove real whitespace or comments.

A fragment before punctuation follows the same rule. Starting from
`A colour, then always.`, wrap only `our` → `or` after `col`, with no retained
whitespace before the comma. Keep a second independent `always` → `usually`
frame later in that sentence. Rejecting the first selection restores
`A colour, then ` followed by the **unchanged second frame** and the final period.
It does not resolve or merge the second decision.

When reporting a problem, include the AgentLaTeX version, active host and reviewer
versions, whether the format policy was staged or active, and a minimal redacted
source snippet with exact whitespace. Include the guard's member/location error
and whether a human decision applied before the failure. A synthetic example is
enough; do not send a private manuscript or credentials.
