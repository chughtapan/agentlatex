from __future__ import annotations

import json
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
MARKETPLACE = ROOT / ".agents" / "plugins" / "marketplace.json"
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

    def test_emacs_reviewer_is_distributed(self) -> None:
        self.assertTrue((ROOT / "emacs" / "agentedit-review.el").is_file())

    def test_release_versions_match(self) -> None:
        version = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
        citation = (ROOT / "CITATION.cff").read_text(encoding="utf-8")
        manifest = json.loads(
            (PLUGIN / ".codex-plugin" / "plugin.json").read_text(encoding="utf-8")
        )
        public_package = (ROOT / "latex" / "agentedit.sty").read_text(
            encoding="utf-8"
        )
        readme = (ROOT / "README.md").read_text(encoding="utf-8")

        self.assertIn(f"\nversion: {version}\n", citation)
        self.assertEqual(manifest["version"], version)
        self.assertIn(f"v{version} Reviewable AI-assisted edits", public_package)
        self.assertIn(f"--ref v{version}", readme)


if __name__ == "__main__":
    unittest.main()
