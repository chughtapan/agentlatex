# AgentLaTeX Emacs reviewer

`agentedit-review` presents each AgentLaTeX marker as an Ediff comparison and
lets you accept, reject, or defer the change without editing its wrapper by
hand. This package is for early team use from a repository checkout.

## Status

The reviewer is experimental and supports Emacs 29.4 and newer. It works with
the built-in TeX modes and with AUCTeX-derived modes. CI uses AUCTeX 14.1.0 as
the oldest tested baseline and 14.1.2 as the current tested release. Runtime
project support checks required capabilities rather than an exact AUCTeX
version.

Report problems through the
[AgentLaTeX issue tracker](https://github.com/chughtapan/agentlatex/issues).
Include your Emacs and AUCTeX versions, the relevant `M-x agentedit-review-report`
outcome, and a minimal redacted `.tex` example when possible.

## Install the reviewer

Clone this repository somewhere stable, then add the checkout to your Emacs
configuration:

```elisp
(use-package agentedit-review
  :ensure nil
  :commands (agentedit-review)
  :load-path "~/agentlatex/emacs")
```

Change `:load-path` if you cloned the repository elsewhere. Restart Emacs or
evaluate the form. No package build or server is required.

## Try a disposable two-edit review

After cloning, this creates a separate sample and opens it in a fresh Emacs
process. The installed `emacs` command must be version 29.4 or newer.

```sh
git clone https://github.com/chughtapan/agentlatex.git "$HOME/agentlatex"
AGENTEDIT_DEMO_DIR=$(mktemp -d)
cat > "$AGENTEDIT_DEMO_DIR/demo.tex" <<'TEX'
\documentclass{article}
\begin{document}
The system \agentedit{frequency}{Qualify frequency.}{always}{usually} terminates \agentedit{speed}{Suggest speed.}{quickly}{promptly}.
\end{document}
TEX
emacs -Q -L "$HOME/agentlatex/emacs" -l "$HOME/agentlatex/emacs/agentedit-review.el" "$AGENTEDIT_DEMO_DIR/demo.tex"
```

In Emacs, run `M-x agentedit-review`. The first comparison shows the sentence.
Press `C-c w` to inspect the full file and press it again to return to the
paragraph. Press `C-c e`, change the active result to `sometimes`, and press
`C-c C-c` to stage it. Press `A` to apply and save; press `R` on the second edit
to retain `quickly`. `M-x agentedit-review-report` shows both outcomes. Inspect
the temporary `.tex` file to see `The system sometimes terminates quickly.`
`C-c e` and `A` act only on the active fragment; other queued text is shown as
original until its own turn. You can delete the temporary directory afterward.

For an automated smoke check from the checkout, run:

```sh
emacs --batch -Q -L emacs -l tests/emacs/agentedit-review-tests.el \
  -f ert-run-tests-batch-and-exit
emacs --batch -Q -L emacs -f batch-byte-compile emacs/agentedit-review.el
```

Byte compilation creates `emacs/agentedit-review.elc`; remove it if you want
to test the source file directly again.

## Review edits

Open a writable TeX source buffer and run:

```text
M-x agentedit-review
```

The command chooses its scope from the active TeX mode:

- In AUCTeX, it reviews the complete master document.
- In a built-in TeX mode, it reviews the current file from point.
- With `C-u`, it reviews the current file from point under either mode family.

Each marker opens in an Ediff pair showing the surrounding LaTeX paragraph.
`C-c w` toggles the whole current file. In either view, the left pane is the
original and the right pane starts with the proposal. Other unresolved records
in view show their **original** text and `[pending ID]` labels. The frame
banners disappear from the projections; the actual source remains wrapped
until you decide. `blocks-v1` and legacy compact macros can coexist. Empty
and whitespace-only fragments have text labels outside their editable content.

The control buffer accepts these keys:

| Key | Action |
| --- | --- |
| `A` | Apply the staged result, then save the owning file by default. |
| `R` | Restore the original, then save the owning file by default. |
| `S` | Leave this record unresolved and continue; confirm first if a custom draft would be discarded. |
| `q` | Confirm stopping, including discarding any custom draft. |
| `C-c e` | Edit only the active fragment of the result pane. |
| `C-c o` / `C-c p` | Seed the editable fragment from the original / proposal. |
| `C-c C-c` | Stage the live draft without changing or saving source. |
| `C-c C-k` | Cancel editing and restore the draft present when editing began. |
| `C-c w` | Toggle paragraph / full current-file context. |
| `C-c l` | Open the persistent per-file report. |

The `C-c` commands also work from either comparison pane. Stage or cancel an
edit before `A`, `R`, `S`, or `C-c w`. Source and context outside the active
result fragment stay protected. Native Ediff navigation, scrolling, help (`E`
and `?`), refinement, and layout (`|`) remain available; native copy and swap
commands cannot change this review's fixed pane roles.

The control header shows the current ID, reason, source path, and line. Its mode
line prioritizes proposal/custom/editing state, save policy, and decision keys.
For the full record history, use `C-c l` or `M-x agentedit-review-report` after
the session. In the report, `g` refreshes live source status and `TAB`/`RET`
follow source or recovered-draft links. The report separates records in this
review from pending records outside its scope. A recovered draft stays in an
Emacs buffer until you close it; save it yourself if you need it across an
Emacs restart.

Readable frames require the current reviewer. After updating the checkout,
restart Emacs; `M-: agentedit-review-format-version` should return `"blocks-v1"`.
The README bootstrap URL stays pinned to the last released tag until this
version receives a tag. Finish or quit a review before undoing a decision, and
restart after a stale-source refusal.

## Review an AUCTeX project

Run `M-x agentedit-review` from the master or any included file. The reviewer
uses `TeX-master`, follows recursive `\input` and `\include` files, and builds
one master-first queue across the source buffers.

If AUCTeX does not know the master, its normal master-file prompt opens. Select
the document entry point, such as `main.tex`. AUCTeX may add its usual
`TeX-master` file-local variable to the current buffer. Canceling the prompt
with `C-g` uses the current file as its own master, matching native AUCTeX
behavior.

To review only the current file under AUCTeX, run:

```text
C-u M-x agentedit-review
```

## Save, undo, and recover

`agentedit-review-auto-save` defaults to `t`. `A` or `R` makes one undoable
source edit and then calls normal `save-buffer` on **that entire owning file**.
Existing unsaved edits elsewhere in the same file are saved too. Other project
files are untouched until their own decision. `S`, `q`, typing, and staging do
not save. `undo` changes the source buffer but does not automatically save it.
For manual saving, set this variable to nil in the invocation buffer **before**
starting. A buffer-local nil setting applies to the entire project pass:

```elisp
(setq-local agentedit-review-auto-save nil)
```

An unnamed source needs a filename before automatic review starts. You can
instead choose manual mode and save it later. Before a decision, the reviewer
checks the complete owning source, pane roles, protected context, frame identity,
and disk freshness. If another edit or disk write makes the review stale, the
pass stops before changing that record. An applied edit remains applied if a
save hook or Ediff teardown fails; check the owning source and report. The
report says **Saved** only after verifying the live text and disk. An
unsuccessful save is marked **Applied; save not confirmed**. Restart the review
after resolving the failure; it never retries or reapplies that decision.

A custom draft interrupted by an error or killed pane is copied to a named
`*AgentEdit recovered …*` buffer before cleanup. `C-c l` links to it. Empty
and whitespace-only changed drafts are preserved too. Inspect the owning
source before using recovered text.

## Configure the reviewer

The scanner ignores TeX comments, `\verb`, `\verb*`, and these environments by
default:

```elisp
("verbatim" "verbatim*" "Verbatim" "Verbatim*" "lstlisting" "minted")
```

Add a project-specific verbatim environment when needed:

```elisp
(add-to-list 'agentedit-review-verbatim-environments "mycode")
```

Run `M-x customize-group RET agentedit-review RET` to inspect the environment
list, the automatic-save policy, and the six faces used for pane labels, whole hunks, and
character-level differences.

## Troubleshoot the reviewer

### Emacs version error

The reviewer requires Emacs 29.4 or newer and checks for the Ediff teardown
capability it uses. Upgrade Emacs rather than bypassing either check.

### AUCTeX project API error

Make sure AUCTeX is installed and loaded for the current buffer. The mode line
should show an AUCTeX mode such as `LaTeX` or `plain-TeX`, not the similarly
named built-in mode.

### Buffer eligibility error

The source must be writable, direct rather than indirect, widened, and have
undo enabled. Use `M-x widen` if the buffer is narrowed. The reviewer does not
change these settings for you.

### Master file error

Choose a readable document entry point at the native AUCTeX prompt. If the
wrong master is already recorded, update `TeX-master` using your normal AUCTeX
workflow and run the reviewer again.

### Save or recovered draft error

Use `M-x agentedit-review-report` to see the owning file, decisions, verified
saves, pending records, and any recovered draft. A failed save may leave the
source changed but the disk unchanged. Resolve the file or hook problem and
save with your normal Emacs workflow before restarting the pass.

### Active review error

Only one review can own a source buffer at a time. Finish or quit the existing
Ediff review before starting another one for the same file or project.

## Test reviewer changes

Run the built-in-mode suite with Emacs 29.4 or newer:

```sh
emacs --batch -Q -L emacs \
  -l tests/emacs/agentedit-review-tests.el \
  -f ert-run-tests-batch-and-exit
```

CI runs the suite with Emacs 29.4 and 30.2, both with built-in TeX and with
AUCTeX 14.1.0 and 14.1.2. See the installation matrix and test commands in
[the CI workflow](../.github/workflows/ci.yml).

## Related documentation

- [Project overview and LaTeX setup](../README.md)
- [Agent bootstrap contract](../BOOTSTRAP.md)
