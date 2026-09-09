"""Check the evaluator's independent precision and integrity oracles."""

import unittest

import evaluate_agent_output as evaluation


class AgentOutputEvaluationTests(unittest.TestCase):
    def test_all_reference_scenarios(self):
        for name in set(evaluation.SCENARIOS) | {"pair", "revision"}:
            with self.subTest(name):
                _, reference, _ = evaluation.scenario(name)
                self.assertTrue(
                    evaluation.evaluate_attempt(name, reference)["passed"]
                )

    def test_unchanged_paragraph_widening_is_detected(self):
        before, _, _ = evaluation.scenario("word")
        source = (
            "%\n%%% AGENTEDIT START: word %%%\n\\agentedit{word}\n  {Why.}\n  {"
            + before
            + "}\n  {The system usually terminates.}%\n%%% AGENTEDIT END: word %%%\n"
        )
        result = evaluation.evaluate_attempt("word", source)
        self.assertTrue(result["format"])
        self.assertTrue(result["integrity"])
        self.assertFalse(result["precision"])
        self.assertFalse(result["passed"])

    def test_original_and_revision_id_corruption_are_detected(self):
        _, source, _ = evaluation.scenario("revision")
        for bad in (
            source.replace("always", "sometimes"),
            source.replace("word", "renamed"),
        ):
            self.assertFalse(
                evaluation.evaluate_attempt("revision", bad)["integrity"]
            )

    def test_legacy_baseline_and_partial_retry(self):
        compact = (
            r"The system \agentedit{word}{Why.}{always}{usually} terminates."
        )
        self.assertTrue(
            evaluation.evaluate_attempt("word", compact, legacy=True)["passed"]
        )
        self.assertFalse(evaluation.evaluate_attempt("word", compact)["passed"])
        _, full, _ = evaluation.scenario("word")
        self.assertTrue(evaluation.evaluate_attempt("word", full)["passed"])

    def test_misplaced_insertion_is_detected(self):
        before, _, _ = evaluation.scenario("addition")
        misplaced = evaluation.FIXTURES["addition"]["frame"] + before
        result = evaluation.evaluate_attempt("addition", misplaced)
        self.assertTrue(result["format"])
        self.assertTrue(result["precision"])
        self.assertTrue(result["integrity"])
        self.assertFalse(result["placement"])
        self.assertFalse(result["passed"])
