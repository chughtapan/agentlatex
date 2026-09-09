"""Compare actual TeX layout and real strict/original/proposed entry points."""

import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = json.loads(
    (ROOT / "tests/fixtures/readable-edits.json").read_text()
)["valid"]


class ReadableRenderingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        missing = [
            name for name in ("pdflatex", "pdftotext") if not shutil.which(name)
        ]
        if missing:
            message = "TeX rendering checks need " + ", ".join(missing)
            if os.environ.get("AGENTEDIT_REQUIRE_TEX") == "1":
                raise RuntimeError(message)
            raise unittest.SkipTest(message)

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.env = dict(os.environ, TEXINPUTS=str(ROOT / "latex") + ":")

    def compile(self, name, text, strict=False):
        (self.root / (name + ".tex")).write_bytes(text.encode())
        process = subprocess.run(
            [
                "pdflatex",
                "-interaction=nonstopmode",
                "-halt-on-error",
                name + ".tex",
            ],
            cwd=self.root,
            env=self.env,
            capture_output=True,
            text=True,
            check=False,
        )
        if strict:
            self.assertNotEqual(process.returncode, 0)
            self.assertIn("AGENT-EDIT-MARKER:", process.stdout)
            return process.stdout, []
        self.assertEqual(process.returncode, 0, process.stdout[-4000:])
        subprocess.run(
            [
                "pdftotext",
                "-bbox",
                str(self.root / (name + ".pdf")),
                str(self.root / (name + ".html")),
            ],
            check=True,
            capture_output=True,
        )
        document = ET.parse(self.root / (name + ".html"))
        words = [
            (
                word.text,
                tuple(
                    round(float(word.attrib[key]), 3)
                    for key in ("xMin", "yMin", "xMax", "yMax")
                ),
            )
            for word in document.iter("{http://www.w3.org/1999/xhtml}word")
        ]
        return process.stdout, words

    def specimen(self, source, side):
        return (
            "\\documentclass{article}\n\\def\\AgentWritingReportMode{1}\n"
            "\\long\\def\\AgentEditRender#1#2#3#4{#" + side + "}\n"
            "\\usepackage{agentedit}\n\\pagestyle{empty}\n\\begin{document}\n"
            "\\setbox0=\\vbox{\\hsize=250pt\n" + source + "\n\\par}\n"
            "\\typeout{BOX: \\the\\wd0;\\the\\ht0;\\the\\dp0}\n"
            "\\box0\n\\end{document}\n"
        )

    def test_shared_layout_matrix(self):
        # Unicode byte retention is tested in Python/ERT; this pdfLaTeX fixture
        # matrix uses the engine's supported text and math alphabet.
        for fixture in FIXTURES:
            if fixture["id"] == "unicode" or not fixture.get("render", True):
                continue
            for side, expected in (("3", "rejected"), ("4", "accepted")):
                with self.subTest(fixture=fixture["id"], side=side):
                    compact = (
                        fixture["prefix"]
                        + "\\agentedit{"
                        + fixture["id"]
                        + "}{Reason.}{"
                        + fixture["original"]
                        + "}{"
                        + fixture["proposed"]
                        + "}"
                        + fixture["whitespace"]
                        + fixture["suffix"]
                    )
                    outputs = []
                    for index, source in enumerate(
                        (fixture["source"], compact, fixture[expected])
                    ):
                        log, words = self.compile(
                            "case" + str(index), self.specimen(source, side)
                        )
                        dimensions = re.search(r"BOX: ([^\n]+)", log).group(1)
                        outputs.append((dimensions, words))
                    self.assertEqual(
                        outputs[0],
                        outputs[1],
                        "frame differs from compact macro",
                    )
                    self.assertEqual(
                        outputs[0],
                        outputs[2],
                        "frame differs from plain source",
                    )

    def test_adjacent_frames_preserve_both_views(self):
        first = FIXTURES[0]["frame"]
        second = first.replace("word", "second")
        framed = "A " + first + second + "B"
        for side, chosen in (("3", "always"), ("4", "usually")):
            _, actual = self.compile("adjacent", self.specimen(framed, side))
            _, expected = self.compile(
                "plain",
                self.specimen("A " + chosen + " " + chosen + " B", side),
            )
            self.assertEqual(actual, expected)

    def test_actual_bootstrap_entrypoints_preserve_original_renderer(self):
        bootstrap = (ROOT / "BOOTSTRAP.md").read_text()
        blocks = re.findall(r"```tex\n(.*?)```", bootstrap, re.DOTALL)
        preamble = next(
            block for block in blocks if "package and project renderer" in block
        )
        original = next(
            block
            for block in blocks
            if "Original-view review entry point" in block
        )
        proposed = next(
            block
            for block in blocks
            if "Warning-mode review entry point" in block
        )
        f = FIXTURES[0]
        source = (
            f["frame"].replace("always", "OLD").replace("usually", "NEW")
            + "tail"
        )
        main = (
            "\\documentclass{article}\n\\newcommand{\\todo}[1]{[TODO: #1]}\n"
            + preamble
            + "\n\\begin{document}\n"
            + source
            + "\n\\end{document}\n"
        )
        (self.root / "main.tex").write_text(main)
        _, words = self.compile("original", original)
        text = " ".join(word[0] for word in words)
        self.assertIn("OLD", text)
        self.assertNotIn("NEW", text)
        self.assertIn("TODO:", text)
        _, words = self.compile("proposed", proposed)
        text = " ".join(word[0] for word in words)
        self.assertIn("NEW", text)
        self.assertNotIn("OLD", text)
        self.assertIn("TODO:", text)
        self.compile("main", main, strict=True)

    def test_naive_paragraph_split_is_not_a_valid_rendering_strategy(self):
        naive = "A\n\\agentedit{bad}{Why.}{}{word}\nB"
        _, split = self.compile("split", self.specimen(naive, "3"))
        _, clean = self.compile("clean", self.specimen("A\n\nB", "3"))
        self.assertNotEqual(split, clean)
