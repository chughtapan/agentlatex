"""Lossless framing, real mutation adapters, and fail-closed policy tests."""

import json
import time
import unittest
from pathlib import Path

import test_guard_agent_edits as legacy

GUARD = legacy.GUARD

CORPUS = json.loads(
    (Path(__file__).parent / "fixtures/readable-edits.json").read_text(
        encoding="utf-8"
    )
)


class ReadableEditsTests(unittest.TestCase):
    """Exercise blocks-v1 with actual source context and the public evaluator."""

    def setUp(self):
        legacy.AgentEditGuardTests.setUp(self)
        self.policy = self.root / ".agentedit.json"
        self.policy.write_text(
            '{"tex_edit_format":"blocks-v1"}', encoding="utf-8"
        )

    tearDown = legacy.AgentEditGuardTests.tearDown
    payload = legacy.AgentEditGuardTests.payload

    def write_source(self, source):
        target = self.root / "paper.tex"
        target.write_bytes(source.encode("utf-8"))
        return target

    def edit(self, old, new, **extra):
        return self.payload(
            "Edit",
            dict(
                file_path="paper.tex", old_string=old, new_string=new, **extra
            ),
        )

    def test_corpus_roundtrip(self):
        for fixture in CORPUS["valid"]:
            with self.subTest(fixture["id"]):
                records = GUARD.scan_records(fixture["source"])
                self.assertEqual(len(records), 1)
                record = records[0]
                self.assertTrue(record.framed)
                self.assertEqual(
                    record.arguments[2:],
                    (fixture["original"], fixture["proposed"]),
                )
                self.assertEqual(record.whitespace, fixture["whitespace"])
                self.assertEqual(
                    GUARD.original_projection(fixture["source"], records),
                    fixture["rejected"],
                )
                self.write_source(fixture.get("initial", fixture["rejected"]))
                payload = self.payload(
                    "Write",
                    {"file_path": "paper.tex", "content": fixture["source"]},
                )
                self.assertEqual(GUARD.evaluate(payload), (True, None))
                self.assertEqual(
                    (self.root / "paper.tex").read_bytes(),
                    fixture.get("initial", fixture["rejected"]).encode(),
                )

    def test_corpus_malformed(self):
        for fixture in CORPUS["invalid"]:
            with self.subTest(fixture["id"]):
                with self.assertRaisesRegex(
                    GUARD.FormatError, fixture["error_category"]
                ):
                    GUARD.scan_records(fixture["source"])

    def test_opaque_contexts(self):
        for fixture in CORPUS["opaque"]:
            with self.subTest(fixture["id"]):
                self.assertEqual(GUARD.scan_records(fixture["source"]), [])
                visible = (
                    fixture["source"] + "\n" + CORPUS["valid"][0]["source"]
                )
                self.assertEqual(len(GUARD.scan_records(visible)), 1)

    def test_policy_configuration_errors(self):
        for policy in (
            "null",
            "[]",
            "{",
            '{"tex_edit_format":null}',
            '{"tex_edit_format":2}',
            '{"tex_edit_format":""}',
            '{"tex_edit_format":{}}',
            '{"tex_edit_format":"future"}',
        ):
            with self.subTest(policy):
                self.policy.write_text(policy)
                allowed, reason = GUARD.evaluate(self.edit("old", "new"))
                self.assertFalse(allowed)
                self.assertIn("configuration error", reason)

    def test_exact_edit_aliases_and_revision(self):
        f = CORPUS["valid"][0]
        for old_key, new_key in (
            ("old_string", "new_string"),
            ("oldText", "newText"),
            ("old_text", "new_text"),
            ("oldString", "newString"),
        ):
            self.write_source(f["rejected"])
            payload = self.payload(
                "functions.edit_file",
                {
                    "filePath": "paper.tex",
                    old_key: "always ",
                    new_key: f["frame"],
                },
            )
            self.assertEqual(GUARD.evaluate(payload), (True, None))
        self.write_source(f["source"])
        revised = f["frame"].replace("usually", "often")
        self.assertEqual(
            GUARD.evaluate(self.edit(f["frame"], revised)), (True, None)
        )
        for bad in (
            f["frame"].replace("always", "sometimes"),
            f["frame"].replace("word", "renamed"),
            f["frame"].replace("} %", "}\n%"),
            "always ",
        ):
            self.assertFalse(GUARD.evaluate(self.edit(f["frame"], bad))[0])
        self.assertFalse(GUARD.evaluate(self.edit("usually", "often"))[0])

    def test_missing_and_ambiguous_context(self):
        self.write_source("old old")
        for old in (None, "", "absent", "old"):
            allowed, reason = GUARD.evaluate(
                self.edit(old, CORPUS["valid"][0]["frame"])
            )
            self.assertFalse(allowed)
            self.assertIn("unique exact", reason)

    def test_legacy_coexists_but_whole_write_must_convert(self):
        f = CORPUS["valid"][0]
        legacy = r"\agentedit{legacy}{Reason.}{before}{after}"
        self.write_source(legacy + "\n" + f["rejected"])
        self.assertTrue(GUARD.evaluate(self.edit("always ", f["frame"]))[0])
        self.assertFalse(
            GUARD.evaluate(
                self.payload(
                    "Write",
                    {
                        "path": "paper.tex",
                        "content": legacy + "\n" + f["source"],
                    },
                )
            )[0]
        )
        safe = (
            f["frame"]
            .replace("word", "legacy")
            .replace("always", "before")
            .replace("usually", "after")
            .replace("} %", "}\n%")
        )
        self.assertTrue(GUARD.evaluate(self.edit(legacy + "\n", safe))[0])

    def test_sequential_batch_and_bounded_failures(self):
        f = CORPUS["valid"][0]
        self.write_source(f["rejected"])
        edits = [
            {"old_string": "always ", "new_string": f["frame"]},
            {
                "old_string": f["frame"],
                "new_string": f["frame"].replace("usually", "often"),
            },
        ]
        self.assertTrue(
            GUARD.evaluate(
                self.payload("MultiEdit", {"path": "paper.tex", "edits": edits})
            )[0]
        )
        for count in (1, 10, 100):
            failed = [
                {"old_string": "absent", "new_string": "unmarked"}
            ] * count
            allowed, reason = GUARD.evaluate(
                self.payload(
                    "MultiEdit", {"path": "paper.tex", "edits": failed}
                )
            )
            self.assertFalse(allowed)
            self.assertEqual(reason.count("Blocked edit"), min(count, 10))
            self.assertEqual(reason.count("%%% AGENTEDIT START:"), 1)
            self.assertIn(f"{count} failures", reason)

    def test_patch_create_revise_partial_and_retry(self):
        f = CORPUS["valid"][0]
        before = f["rejected"] + "\n"
        source = f["source"] + "\n"
        self.write_source(before)

        def patch(old, new):
            return self.payload(
                "apply_patch",
                {
                    "input": "*** Begin Patch\n*** Update File: paper.tex\n@@\n"
                    + "".join(
                        "-" + line for line in old.splitlines(keepends=True)
                    )
                    + "".join(
                        "+" + line for line in new.splitlines(keepends=True)
                    )
                    + "*** End Patch\n"
                },
            )

        self.assertEqual(GUARD.evaluate(patch(before, source)), (True, None))
        self.write_source(source)
        self.assertFalse(
            GUARD.evaluate(patch("  {usually} %\n", "  {often} %\n"))[0]
        )
        self.assertTrue(
            GUARD.evaluate(patch(source, source.replace("usually", "often")))[0]
        )
        crlf = source.replace("\n", "\r\n")
        self.write_source(crlf)
        allowed, reason = GUARD.evaluate(
            patch(crlf, crlf.replace("usually", "often"))
        )
        self.assertFalse(allowed)
        self.assertIn("CRLF", reason)

    def test_add_file_and_unmarked_neighbor(self):
        f = next(f for f in CORPUS["valid"] if f["id"] == "empty-eof")
        patch = (
            "*** Begin Patch\n*** Add File: paper.tex\n"
            + "".join(
                "+" + line for line in f["frame"].splitlines(keepends=True)
            )
            + "*** End Patch\n"
        )
        self.assertTrue(
            GUARD.evaluate(self.payload("apply_patch", {"input": patch}))[0]
        )
        self.write_source("plain")
        self.assertFalse(
            GUARD.evaluate(self.edit("plain", f["source"] + "unmarked"))[0]
        )

    def test_payload_comment_namespace_is_data(self):
        f = CORPUS["valid"][0]
        source = f["source"].replace(
            "always", "always%\n%%% AGENTEDIT END: fake %%%\n"
        )
        self.assertEqual(len(GUARD.scan_records(source)), 1)

    def test_linear_backslash_and_malformed_scanning(self):
        durations = []
        for count in (1000, 2000, 4000):
            source = "\\\\" * count + CORPUS["valid"][0]["source"]
            start = time.perf_counter()
            for _ in range(10):
                self.assertEqual(len(GUARD.scan_records(source)), 1)
            durations.append(time.perf_counter() - start)
            with self.assertRaises(GUARD.FormatError):
                GUARD.scan_records(r"\agentedit{x}{why}{" * count)
        self.assertLess(durations[-1], max(0.2, durations[0] * 10))

    def test_patch_deletion_only_and_nonfinal_newline_are_denied(self):
        f = CORPUS["valid"][0]
        source = f["source"].replace("usually", "usually\nextra\n") + "\n"
        self.write_source(source)
        payload = self.payload(
            "apply_patch",
            {
                "input": "*** Begin Patch\n*** Update File: paper.tex\n@@\n-extra\n*** End Patch\n"
            },
        )
        allowed, reason = GUARD.evaluate(payload)
        self.assertFalse(allowed)
        self.assertIn("complete frame", reason)
        self.write_source(f["rejected"] + "\nTail")
        payload["tool_input"]["input"] = (
            "*** Begin Patch\n*** Update File: paper.tex\n@@\n-"
            + f["rejected"]
            + "\n"
            + "".join(
                "+" + line
                for line in (f["source"] + "\n").splitlines(keepends=True)
            )
            + "*** End Patch\n"
        )
        allowed, reason = GUARD.evaluate(payload)
        self.assertFalse(allowed)
        self.assertIn("final newline", reason)

    def test_unreadable_or_invalid_encoding_policy_denies(self):
        from unittest import mock

        self.policy.write_bytes(b"\xff")
        allowed, reason = GUARD.evaluate(self.edit("old", "new"))
        self.assertFalse(allowed)
        self.assertIn("configuration error", reason)
        self.policy.write_text('{"tex_edit_format":"blocks-v1"}')
        with mock.patch.object(
            Path, "read_text", side_effect=PermissionError("unreadable")
        ):
            allowed, reason = GUARD.evaluate(self.edit("old", "new"))
        self.assertFalse(allowed)
        self.assertIn("configuration error", reason)

    def test_patch_native_placement_rejections(self):
        source = "old\nanchor\nold \n"
        frame = "%\n%%% AGENTEDIT START: id %%%\n\\agentedit{id}\n  {Why.}\n  {old}\n  {new}\n%\n%%% AGENTEDIT END: id %%%\n"
        self.write_source(source)
        additions = "".join("+" + line for line in GUARD.physical_lines(frame))
        for context in ("@@ anchor\n-old\n", "@@\n-old\n\n"):
            payload = self.payload(
                "apply_patch",
                {
                    "input": "*** Begin Patch\n*** Update File: paper.tex\n"
                    + context
                    + additions
                    + "*** End Patch\n"
                },
            )
            self.assertFalse(GUARD.evaluate(payload)[0])
        self.write_source("prefix old\n  old\n")
        payload["tool_input"]["input"] = (
            "*** Begin Patch\n*** Update File: paper.tex\n@@\n-old\n"
            + additions
            + "*** End Patch\n"
        )
        self.assertFalse(GUARD.evaluate(payload)[0])

    def test_patch_preserves_non_lf_characters_and_rejects_hidden_macro(self):
        f = CORPUS["valid"][0]
        self.write_source(f["rejected"] + "\n")
        for separator in ("\u2028", "\u2029", "\v", "\f"):
            source = (f["source"] + "\n").replace(
                "usually",
                "new" + separator + r"\agentedit{nested}{reason}{a}{b}",
            )
            patch = (
                "*** Begin Patch\n*** Update File: paper.tex\n@@\n-"
                + f["rejected"]
                + "\n"
                + "".join("+" + line for line in GUARD.physical_lines(source))
                + "*** End Patch\n"
            )
            allowed, reason = GUARD.evaluate(
                self.payload("apply_patch", {"input": patch})
            )
            self.assertFalse(allowed)
            self.assertIn("nested", reason)

    def test_patch_context_cannot_authorize_legacy_or_bootstrap_changes(self):
        for policy, marker in (
            ({}, r"\agentedit{old}{reason}{old}{new}"),
            ({"bootstrap_files": ["paper.tex"]}, "% AGENTEDIT-BOOTSTRAP"),
        ):
            self.policy.write_text(json.dumps(policy))
            patch = (
                "*** Begin Patch\n*** Update File: paper.tex\n@@\n "
                + marker
                + "\n-Original.\n+Unmarked replacement.\n*** End Patch\n"
            )
            self.assertFalse(
                GUARD.evaluate(self.payload("apply_patch", {"input": patch}))[0]
            )

    def test_add_file_cannot_borrow_frame_from_non_tex_file(self):
        patch = "*** Begin Patch\n*** Add File: paper.tex\n+%\n+%%% AGENTEDIT START: id %%%\n+\\agentedit{id}\n*** Add File: notes.txt\n+  {Why.}\n+  {}\n+  {new}%\n+%%% AGENTEDIT END: id %%%\n*** End Patch\n"
        self.assertFalse(
            GUARD.evaluate(self.payload("apply_patch", {"input": patch}))[0]
        )

    def test_multiple_patch_hunks_files_and_separate_batch_targets(self):
        f = CORPUS["valid"][0]
        before = f["rejected"] + "\nOther old.\n"
        self.write_source(before)
        (self.root / "other.tex").write_text(f["rejected"] + "\n")
        first = f["source"] + "\n"
        second = (
            "Other "
            + f["frame"]
            .replace("word", "second")
            .replace("always", "old")
            .replace("usually", "new")
            .replace("} %", "}%")
            + ".\n"
        )
        patch = (
            "*** Begin Patch\n*** Update File: paper.tex\n@@\n-"
            + f["rejected"]
            + "\n"
            + "".join("+" + line for line in GUARD.physical_lines(first))
            + "@@\n-Other old.\n"
            + "".join("+" + line for line in GUARD.physical_lines(second))
            + "*** Update File: other.tex\n@@\n-"
            + f["rejected"]
            + "\n"
            + "".join("+" + line for line in GUARD.physical_lines(first))
            + "*** End Patch\n"
        )
        self.assertEqual(
            GUARD.evaluate(self.payload("apply_patch", {"input": patch})),
            (True, None),
        )
        edits = [
            {"path": path, "oldText": "always ", "newText": f["frame"]}
            for path in ("paper.tex", "other.tex")
        ]
        self.assertTrue(
            GUARD.evaluate(self.payload("MultiEdit", {"edits": edits}))[0]
        )
        edits[1]["newText"] = "unmarked "
        self.assertFalse(
            GUARD.evaluate(self.payload("MultiEdit", {"edits": edits}))[0]
        )

    def test_cli_capabilities_do_not_claim_active_dispatch(self):
        import subprocess

        result = subprocess.run(
            ["python3", str(legacy.SCRIPT), "--capabilities"],
            capture_output=True,
            text=True,
            check=True,
        )
        capabilities = json.loads(result.stdout)
        self.assertEqual(capabilities["tex_edit_format"], "blocks-v1")
        self.assertFalse(capabilities["active_hook_verified"])

    def test_unsafe_legacy_id_requires_human_decision(self):
        before = r"\agentedit{old id}{Reason.}{old}{new}"
        self.write_source(before)
        frame = CORPUS["valid"][0]["frame"].replace("word", "old id")
        allowed, reason = GUARD.evaluate(self.edit(before, frame))
        self.assertFalse(allowed)
        self.assertIn("legacy ID 'old id'", reason)
        self.assertIn("a human must resolve", reason)
