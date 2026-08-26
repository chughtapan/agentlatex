# Contributing

Keep changes small and include tests for behavior that affects validation or
rendering.

Run the guard suite:

```sh
python3 -m unittest discover -s tests -v
```

For Emacs reviewer changes, also run the batch ERT suite in the
[Emacs reviewer guide](emacs/README.md#test-reviewer-changes). CI covers Emacs
29.4 and 30.2 with the built-in TeX modes and AUCTeX 14.1.0 and 14.1.2.

Compile the LaTeX example:

```sh
cd examples
TEXINPUTS=../latex: pdflatex -interaction=nonstopmode example.tex
```

Update `CHANGELOG.md` for user-visible changes. Do not weaken provenance checks
without documenting the resulting enforcement gap.
