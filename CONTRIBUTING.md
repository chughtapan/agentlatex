# Contributing

Keep changes small and include tests for behavior that affects validation or
rendering.

Run the guard suite:

```sh
python3 -m unittest discover -s tests -v
```

Compile the LaTeX example:

```sh
cd examples
TEXINPUTS=../latex: pdflatex -interaction=nonstopmode example.tex
```

Update `CHANGELOG.md` for user-visible changes. Do not weaken provenance checks
without documenting the resulting enforcement gap.
