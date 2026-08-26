from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SCRIPT = (
    Path(__file__).parents[1]
    / "plugins"
    / "agentedit-guard"
    / "scripts"
    / "guard_agent_edits.py"
)
SPEC = importlib.util.spec_from_file_location("guard_agent_edits", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
GUARD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GUARD)


class AgentEditGuardTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        (self.root / ".agentedit.json").write_text(
            json.dumps(
                {
                    "version": 1,
                    "bootstrap_marker": "AGENTEDIT-BOOTSTRAP",
                    "bootstrap_files": ["main.tex"],
                }
            ),
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def payload(self, tool: str, tool_input: dict[str, str]) -> dict[str, object]:
        return {"cwd": str(self.root), "tool_name": tool, "tool_input": tool_input}

    def test_allows_non_tex_edit(self) -> None:
        allowed, _ = GUARD.evaluate(
            self.payload("Edit", {"file_path": "README.md", "new_string": "text"})
        )
        self.assertTrue(allowed)

    def test_blocks_unmarked_tex_edit(self) -> None:
        allowed, reason = GUARD.evaluate(
            self.payload("Edit", {"file_path": "paper.tex", "new_string": "new text"})
        )
        self.assertFalse(allowed)
        self.assertIn("complete", reason or "")

    def test_allows_complete_tex_edit(self) -> None:
        source = r"\agentedit{intro}{Clarify scope.}{old text}{new text}"
        allowed, _ = GUARD.evaluate(
            self.payload("Edit", {"file_path": "paper.tex", "new_string": source})
        )
        self.assertTrue(allowed)

    def test_requires_exact_agentedit_control_word(self) -> None:
        cases = {
            "control symbol": (
                r"\\agentedit{id}{Reason.}{old}{new}",
                False,
            ),
            "longer control word": (
                r"\agentediting{id}{Reason.}{old}{new}",
                False,
            ),
            "independent token after control symbol": (
                r"\\ \agentedit{id}{Reason.}{old}{new}",
                True,
            ),
        }
        for label, (source, expected) in cases.items():
            with self.subTest(label=label):
                allowed, _ = GUARD.evaluate(
                    self.payload(
                        "Edit",
                        {"file_path": "paper.tex", "new_string": source},
                    )
                )
                self.assertEqual(allowed, expected)

    def test_blocks_tex_edit_without_reason(self) -> None:
        source = r"\agentedit{intro}{}{old text}{new text}"
        allowed, _ = GUARD.evaluate(
            self.payload("Edit", {"file_path": "paper.tex", "new_string": source})
        )
        self.assertFalse(allowed)

    def test_allows_bootstrap_edit(self) -> None:
        allowed, _ = GUARD.evaluate(
            self.payload(
                "Edit",
                {
                    "file_path": "main.tex",
                    "new_string": "% AGENTEDIT-BOOTSTRAP\n\\usepackage{agentedit}",
                },
            )
        )
        self.assertTrue(allowed)

    def test_allows_absolute_bootstrap_path(self) -> None:
        allowed, _ = GUARD.evaluate(
            self.payload(
                "Edit",
                {
                    "file_path": str(self.root / "main.tex"),
                    "new_string": "% AGENTEDIT-BOOTSTRAP\n\\usepackage{agentedit}",
                },
            )
        )
        self.assertTrue(allowed)

    def test_blocks_bootstrap_marker_in_paper_source(self) -> None:
        allowed, _ = GUARD.evaluate(
            self.payload(
                "Edit",
                {
                    "file_path": "section.tex",
                    "new_string": "% AGENTEDIT-BOOTSTRAP\nunmarked prose",
                },
            )
        )
        self.assertFalse(allowed)

    def test_blocks_incomplete_bib_record(self) -> None:
        allowed, _ = GUARD.evaluate(
            self.payload("Write", {"file_path": "refs.bib", "content": "@article{x}"})
        )
        self.assertFalse(allowed)

    def test_allows_complete_bib_record(self) -> None:
        source = """% AGENT-EDIT-BEGIN: x
% REASON: Add evidence.
% OLD: (none)
% NEW:
% UNVERIFIED: DBLP https://dblp.org/rec/journals/corr/abs-x
@article{x,
  biburl = {https://dblp.org/rec/journals/corr/abs-x.bib}
}
% AGENT-EDIT-END: x
"""
        allowed, _ = GUARD.evaluate(
            self.payload("Write", {"file_path": "refs.bib", "content": source})
        )
        self.assertTrue(allowed)

    def test_allows_compile_command(self) -> None:
        allowed, _ = GUARD.evaluate(
            self.payload("exec_command", {"cmd": "latexmk -pdf main.tex"})
        )
        self.assertTrue(allowed)

    def test_blocks_mutating_shell_command(self) -> None:
        allowed, _ = GUARD.evaluate(
            self.payload("exec_command", {"cmd": "sed -i s/old/new/ paper.tex"})
        )
        self.assertFalse(allowed)


if __name__ == "__main__":
    unittest.main()
