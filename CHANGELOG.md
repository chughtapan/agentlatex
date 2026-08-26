# Changelog

## 0.3.0 - 2026-08-26

### Added

- Install AgentEdit Guard from the same repository in Claude Code and Claude
  Desktop Cowork, with native Claude plugin and marketplace manifests.
- Guard common Claude filesystem MCP edits and PowerShell mutations.

### Changed

- Validate only proposed replacement text, so an existing marker cannot
  authorize its own removal.
- Validate every batch edit and patch target independently, including targets
  governed by a policy outside the agent's current working directory.
- Document the host support matrix and the boundary between Cowork hooks and
  ordinary Claude Chat.

## 0.2.0 - 2026-08-26

### Added

- Review AgentLaTeX markers in Emacs through one context-aware
  `agentedit-review` command, with Ediff accept, reject, and skip controls.
- Review complete AUCTeX master documents while preserving native
  `TeX-master` prompting and file-local behavior; use `C-u` for the current file.
- See whole-hunk and character-level differences in native horizontal or
  vertical Ediff layouts, with unsaved and independently undoable decisions.
- Configure ignored verbatim environments and follow a lightweight team setup
  and troubleshooting guide.

### Changed

- Support Emacs 29.4 and newer with built-in TeX modes; test capability-based
  AUCTeX integration against versions 14.1.0 and 14.1.2.
- Recognize only the exact `\agentedit` TeX control word in the guard and
  reviewer, including TeX-aware comment and verbatim handling.

## 0.1.1 - 2026-07-11

- Package the Codex marketplace under its canonical `.agents/plugins` layout.
- Bundle the LaTeX package and bootstrap contract with the installed plugin.
- Check distribution copies for drift in CI.

## 0.1.0 - 2026-07-11

- Add the `\agentedit{id}{reason}{original}{edited}` LaTeX package.
- Add strict validation and warning-mode review reports.
- Add a preamble-configurable renderer.
- Add the AgentEdit Guard Codex plugin and project bootstrap workflow.
- Add a self-contained agent bootstrap contract and copyable onboarding prompt.
- Add Overleaf setup guidance and a review-mode switch.
