from __future__ import annotations

import json
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
MARKETPLACE = ROOT / ".agents" / "plugins" / "marketplace.json"
CLAUDE_MARKETPLACE = ROOT / ".claude-plugin" / "marketplace.json"
PLUGIN = ROOT / "plugins" / "agentedit-guard"


class DistributionLayoutTests(unittest.TestCase):
    def test_marketplace_points_to_packaged_plugin(self) -> None:
        payload = json.loads(MARKETPLACE.read_text(encoding="utf-8"))
        self.assertEqual(payload["name"], "agentlatex")
        self.assertEqual(len(payload["plugins"]), 1)
        entry = payload["plugins"][0]
        self.assertEqual(entry["name"], "agentedit-guard")
        self.assertEqual(entry["source"]["path"], "./plugins/agentedit-guard")
        self.assertTrue((PLUGIN / ".codex-plugin" / "plugin.json").is_file())

    def test_claude_marketplace_points_to_packaged_plugin(self) -> None:
        payload = json.loads(CLAUDE_MARKETPLACE.read_text(encoding="utf-8"))
        self.assertEqual(payload["name"], "agentlatex")
        self.assertEqual(len(payload["plugins"]), 1)
        entry = payload["plugins"][0]
        self.assertEqual(entry["name"], "agentedit-guard")
        self.assertEqual(entry["source"], "./plugins/agentedit-guard")
        self.assertTrue((PLUGIN / ".claude-plugin" / "plugin.json").is_file())

    def test_plugin_bundles_current_latex_package(self) -> None:
        public_package = (ROOT / "latex" / "agentedit.sty").read_bytes()
        bundled_package = (PLUGIN / "latex" / "agentedit.sty").read_bytes()
        self.assertEqual(public_package, bundled_package)

    def test_plugin_bundles_current_bootstrap_contract(self) -> None:
        public_contract = (ROOT / "BOOTSTRAP.md").read_bytes()
        bundled_contract = (PLUGIN / "BOOTSTRAP.md").read_bytes()
        self.assertEqual(public_contract, bundled_contract)

    def test_plugin_hook_and_skill_are_present(self) -> None:
        hooks = json.loads((PLUGIN / "hooks.json").read_text(encoding="utf-8"))
        self.assertIn("PreToolUse", hooks["hooks"])
        self.assertTrue(
            (PLUGIN / "skills" / "agentedit-guard" / "SKILL.md").is_file()
        )

    def test_claude_hook_uses_plugin_root_in_exec_form(self) -> None:
        hooks = json.loads(
            (PLUGIN / "hooks" / "hooks.json").read_text(encoding="utf-8")
        )
        pre_tool_use = hooks["hooks"]["PreToolUse"]
        self.assertEqual(len(pre_tool_use), 1)
        matcher = pre_tool_use[0]["matcher"]
        self.assertIn("Write", matcher)
        self.assertIn("PowerShell", matcher)
        self.assertIn("mcp__", matcher)
        command = pre_tool_use[0]["hooks"][0]
        self.assertEqual(command["command"], "python3")
        self.assertEqual(
            command["args"],
            ["${CLAUDE_PLUGIN_ROOT}/scripts/guard_agent_edits.py"],
        )

    def test_emacs_reviewer_is_distributed(self) -> None:
        self.assertTrue((ROOT / "emacs" / "agentedit-review.el").is_file())

    def test_release_versions_match(self) -> None:
        version = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
        citation = (ROOT / "CITATION.cff").read_text(encoding="utf-8")
        codex_manifest = json.loads(
            (PLUGIN / ".codex-plugin" / "plugin.json").read_text(
                encoding="utf-8"
            )
        )
        claude_manifest = json.loads(
            (PLUGIN / ".claude-plugin" / "plugin.json").read_text(
                encoding="utf-8"
            )
        )
        public_package = (ROOT / "latex" / "agentedit.sty").read_text(
            encoding="utf-8"
        )
        bootstrap = (ROOT / "BOOTSTRAP.md").read_text(encoding="utf-8")
        readme = (ROOT / "README.md").read_text(encoding="utf-8")

        self.assertIn(f"\nversion: {version}\n", citation)
        self.assertEqual(codex_manifest["version"], version)
        self.assertEqual(claude_manifest["version"], version)
        self.assertIn(
            f"v{version} Reviewable AI-assisted edits", public_package
        )
        self.assertIn(f"--ref v{version}", readme)
        self.assertIn(f"@v{version}", readme)
        self.assertIn(f"/v{version}/BOOTSTRAP.md", readme)
        self.assertIn(f"/v{version}/latex/agentedit.sty", bootstrap)


if __name__ == "__main__":
    unittest.main()
