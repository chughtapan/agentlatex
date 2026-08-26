from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any


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
sys.modules[SPEC.name] = GUARD
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

    def payload(
        self,
        tool: str,
        tool_input: dict[str, Any],
    ) -> dict[str, object]:
        return {
            "cwd": str(self.root),
            "tool_name": tool,
            "tool_input": tool_input,
        }

    def test_allows_non_tex_edit(self) -> None:
        allowed, _ = GUARD.evaluate(
            self.payload(
                "Edit", {"file_path": "README.md", "new_string": "text"}
            )
        )
        self.assertTrue(allowed)

    def test_allows_non_tex_edit_without_proposed_text(self) -> None:
        allowed, _ = GUARD.evaluate(
            self.payload("Edit", {"file_path": "README.md"})
        )
        self.assertTrue(allowed)

    def test_blocks_unmarked_tex_edit(self) -> None:
        allowed, reason = GUARD.evaluate(
            self.payload(
                "Edit",
                {"file_path": "paper.tex", "new_string": "new text"},
            )
        )
        self.assertFalse(allowed)
        self.assertIn("complete", reason or "")

    def test_allows_complete_tex_edit(self) -> None:
        source = r"\agentedit{intro}{Clarify scope.}{old text}{new text}"
        allowed, _ = GUARD.evaluate(
            self.payload(
                "Edit", {"file_path": "paper.tex", "new_string": source}
            )
        )
        self.assertTrue(allowed)

    def test_blocks_when_old_text_contains_the_only_marker(self) -> None:
        marked = r"\agentedit{intro}{Clarify.}{old text}{new text}"
        allowed, _ = GUARD.evaluate(
            self.payload(
                "Edit",
                {
                    "file_path": "paper.tex",
                    "old_string": marked,
                    "new_string": "new text",
                },
            )
        )
        self.assertFalse(allowed)

    def test_supports_camel_case_codex_payload(self) -> None:
        payload = {
            "cwd": str(self.root),
            "toolName": "functions.Edit",
            "toolInput": {
                "filePath": "paper.tex",
                "oldString": r"\agentedit{id}{Reason.}{old}{new}",
                "newString": "new",
            },
        }
        allowed, _ = GUARD.evaluate(payload)
        self.assertFalse(allowed)

    def test_checks_each_edit_in_a_batch(self) -> None:
        marked = r"\agentedit{intro}{Clarify.}{old text}{new text}"
        allowed, reason = GUARD.evaluate(
            self.payload(
                "MultiEdit",
                {
                    "file_path": "paper.tex",
                    "edits": [
                        {"old_string": "old text", "new_string": marked},
                        {"old_string": "other", "new_string": "unmarked"},
                    ],
                },
            )
        )
        self.assertFalse(allowed)
        self.assertIn("complete", reason or "")

    def test_allows_batch_when_every_edit_is_marked(self) -> None:
        edits = [
            {
                "old_string": "old one",
                "new_string": r"\agentedit{one}{Clarify.}{old one}{new one}",
            },
            {
                "old_string": "old two",
                "new_string": r"\agentedit{two}{Tighten.}{old two}{new two}",
            },
        ]
        allowed, _ = GUARD.evaluate(
            self.payload(
                "MultiEdit", {"file_path": "paper.tex", "edits": edits}
            )
        )
        self.assertTrue(allowed)

    def test_blocks_missing_proposed_text(self) -> None:
        allowed, reason = GUARD.evaluate(
            self.payload(
                "Edit", {"file_path": "paper.tex", "old_string": "old"}
            )
        )
        self.assertFalse(allowed)
        self.assertIn("could not identify", reason or "")

    def test_blocks_malformed_batch_for_protected_target(self) -> None:
        allowed, reason = GUARD.evaluate(
            self.payload(
                "MultiEdit", {"file_path": "paper.tex", "edits": [None]}
            )
        )
        self.assertFalse(allowed)
        self.assertIn("could not identify", reason or "")

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
            self.payload(
                "Edit", {"file_path": "paper.tex", "new_string": source}
            )
        )
        self.assertFalse(allowed)

    def test_allows_bootstrap_edit(self) -> None:
        allowed, _ = GUARD.evaluate(
            self.payload(
                "Edit",
                {
                    "file_path": "main.tex",
                    "new_string": (
                        "% AGENTEDIT-BOOTSTRAP\n\\usepackage{agentedit}"
                    ),
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
                    "new_string": (
                        "% AGENTEDIT-BOOTSTRAP\n\\usepackage{agentedit}"
                    ),
                },
            )
        )
        self.assertTrue(allowed)

    def test_finds_policy_from_absolute_target_outside_cwd(self) -> None:
        payload = self.payload(
            "Write",
            {"file_path": str(self.root / "paper.tex"), "content": "unmarked"},
        )
        payload["cwd"] = str(self.root.parent)
        allowed, _ = GUARD.evaluate(payload)
        self.assertFalse(allowed)

    def test_does_not_apply_cwd_policy_to_external_target(self) -> None:
        with tempfile.TemporaryDirectory() as external_directory:
            allowed, _ = GUARD.evaluate(
                self.payload(
                    "Write",
                    {
                        "file_path": str(
                            Path(external_directory) / "paper.tex"
                        ),
                        "content": "unmarked",
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
            self.payload(
                "Write",
                {"file_path": "refs.bib", "content": "@article{x}"},
            )
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

    def test_blocks_mutating_powershell_command(self) -> None:
        allowed, _ = GUARD.evaluate(
            self.payload(
                "PowerShell",
                {"command": "Set-Content paper.tex replacement"},
            )
        )
        self.assertFalse(allowed)

    def test_apply_patch_ignores_deleted_marker(self) -> None:
        patch = r"""*** Begin Patch
*** Update File: paper.tex
@@
-\agentedit{intro}{Clarify.}{old text}{new text}
+new text
*** End Patch
"""
        allowed, _ = GUARD.evaluate(
            self.payload("apply_patch", {"patch": patch})
        )
        self.assertFalse(allowed)

    def test_apply_patch_allows_added_marker(self) -> None:
        patch = r"""*** Begin Patch
*** Update File: paper.tex
@@
-old text
+\agentedit{intro}{Clarify.}{old text}{new text}
*** End Patch
"""
        allowed, _ = GUARD.evaluate(
            self.payload("apply_patch", {"patch": patch})
        )
        self.assertTrue(allowed)

    def test_apply_patch_checks_each_hunk_in_one_file(self) -> None:
        patch = r"""*** Begin Patch
*** Update File: paper.tex
@@ first
-old text
+\agentedit{intro}{Clarify.}{old text}{new text}
@@ second
-other text
+unmarked text
*** End Patch
"""
        allowed, reason = GUARD.evaluate(
            self.payload("apply_patch", {"patch": patch})
        )
        self.assertFalse(allowed)
        self.assertIn("complete", reason or "")

    def test_supports_mcp_edit_file_shape(self) -> None:
        allowed, _ = GUARD.evaluate(
            self.payload(
                "mcp__filesystem__edit_file",
                {
                    "path": "paper.tex",
                    "edits": [
                        {
                            "oldText": "old text",
                            "newText": r"\agentedit{intro}{Clarify.}"
                            r"{old text}{new text}",
                        }
                    ],
                },
            )
        )
        self.assertTrue(allowed)

    def test_cli_emits_claude_pretooluse_denial(self) -> None:
        result = subprocess.run(
            ["python3", str(SCRIPT)],
            input=json.dumps(
                self.payload(
                    "Edit",
                    {"file_path": "paper.tex", "new_string": "unmarked"},
                )
            ),
            capture_output=True,
            check=True,
            text=True,
        )
        output = json.loads(result.stdout)
        decision = output["hookSpecificOutput"]
        self.assertEqual(decision["hookEventName"], "PreToolUse")
        self.assertEqual(decision["permissionDecision"], "deny")
        self.assertIn("Blocked edit", decision["permissionDecisionReason"])


if __name__ == "__main__":
    unittest.main()
