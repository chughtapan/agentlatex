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

## Review edits

Open a writable TeX source buffer and run:

```text
M-x agentedit-review
```

The command chooses its scope from the active TeX mode:

- In AUCTeX, it reviews the complete master document.
- In a built-in TeX mode, it reviews the current file from point.
- With `C-u`, it reviews the current file from point under either mode family.

Each marker opens in a normal Ediff session. The original text appears in the
red `− ORIGINAL` pane and the proposed text appears in the green `+ PROPOSED`
pane. Changed characters receive stronger highlighting.

Use these keys in the Ediff control buffer:

| Key | Result |
| --- | --- |
| `A` | Accept the proposed text. |
| `R` | Restore the original text. |
| `S` | Leave the marker unresolved and continue. |
| `q` | Confirm that you want to stop the review. |

Normal Ediff navigation, help, scrolling, and the `|` layout toggle remain
available.

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

## Save or undo decisions

Accept and reject each create one source-buffer undo step. The reviewer never
saves a source file, so inspect the result and save it with your normal Emacs
workflow. `S` and `q` leave unresolved wrappers unchanged.

Before every replacement, the reviewer checks that the source is still live,
writable, widened, undo-enabled, and byte-for-byte identical to the marker that
opened in Ediff. If another edit makes the review stale, the session stops
without overwriting that edit.

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
list and the six faces used for original/proposed pane labels, whole hunks, and
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
