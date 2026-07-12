# Overleaf Setup

Overleaf can use AgentEdit without installing a system package.

## Project Files

1. Copy `../latex/agentedit.sty` to the Overleaf project's top level.
2. Copy `agentedit-overleaf.tex.example` to the same location and rename it
   `agentedit-overleaf.tex`.
3. Keep the actual paper entry point, normally `main.tex`, at the top level and
   select it under Settings, Compiler, Main document.
4. Add the following immediately before the package load in that entry point:

   ```tex
   \InputIfFileExists{agentedit-overleaf.tex}{}{}
   \usepackage{agentedit}
   ```

The example mode file defines `\AgentWritingReportMode`, so unresolved edits
produce warnings and a complete PDF. Comment that definition when checking that
the paper has no unresolved edits. Strict mode produces a package error for each
remaining marker.

## Project Renderer

The renderer is normal preamble LaTeX. This example keeps the edited source and
uses an existing `\todo` command to display the reason:

```tex
\long\def\AgentEditRender#1#2#3#4{%
  #4\todo{Codex [#1]: #2}%
}
```

Define the renderer before `\usepackage{agentedit}`. Adapt the TODO command and
styling to the paper's packages.

## Package Subdirectory

Overleaf finds a custom `.sty` at the project top level automatically. If the
project instead stores it as `vendor/agentedit.sty`, create a top-level
`latexmkrc` containing:

```perl
$ENV{'TEXINPUTS'}='./vendor//:' . $ENV{'TEXINPUTS'};
```

The Main document and `latexmkrc` should remain at the project top level.

## GitHub Synchronization

Overleaf's GitHub synchronization must be initiated by importing a GitHub
repository into a new Overleaf project, or by creating a new GitHub repository
from an Overleaf project. It cannot link an existing Overleaf project to an
existing GitHub repository. Synchronization is manual rather than automatic.

Overleaf does not support Git submodules inside a project. Commit
`agentedit.sty`, `.agentedit.json`, the mode file, and the paper's AgentEdit
policy directly to the paper repository.

Official references:

- [Adding LaTeX dependencies](https://docs.overleaf.com/managing-projects-and-files/adding-latex-dependencies)
- [Selecting the Main document](https://docs.overleaf.com/getting-started/recompiling-your-project/the-main-document)
- [GitHub synchronization](https://docs.overleaf.com/integrations-and-add-ons/git-integration-and-github-synchronization/github-synchronization)
