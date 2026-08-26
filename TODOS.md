# TODOS

## Editor Integrations

### Add a cross-editor AgentEdit review adapter

**What:** Define a small editor-neutral review protocol and implement a VS Code adapter after the Emacs workflow proves useful.

**Why:** This would extend the original visual-review idea beyond Emacs without forcing v0 to carry multi-editor architecture.

**Context:** The approved v0 deliberately uses native Emacs Ediff and repository-local loading for quick personal use. Revisit this only after repeated real-paper use shows that the accept/reject/skip semantics are stable and valuable. Start by extracting the smallest protocol from the shipped Emacs behavior, then evaluate VS Code's diff APIs; avoid designing a generic protocol in advance. The gain is portability, while the cost is extension packaging and a second compatibility surface.

**Effort:** L
**Priority:** P3
**Depends on:** Shipped Emacs workflow and evidence of repeated use

## Completed

No completed items yet.
