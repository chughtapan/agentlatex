"""Score captured agent attempts against finite, exact-source editing tasks.

Usage: python3 tests/evaluate_agent_output.py attempts.json [--legacy]
Input: [{"case": "word", "attempt": 1, "source": "complete resulting source"}]
The legacy switch measures old instructions' precision without requiring frames.
This evaluator never starts a model or writes to a manuscript.
"""

import json
import sys
import tempfile
from pathlib import Path

from test_guard_agent_edits import GUARD

CORPUS = json.loads(
    (Path(__file__).parent / "fixtures/readable-edits.json").read_text()
)
FIXTURES = {fixture["id"]: fixture for fixture in CORPUS["valid"]}
SCENARIOS = {
    "word": "word",
    "fragment": "fragment",
    "addition": "addition",
    "deletion": "delete-word",
    "paragraph": "insert-paragraph",
    "citation": "citation",
}


def scenario(name):
    """Return initial source, reference output, and exact minimal payload pairs."""
    if name == "pair":
        first = FIXTURES["word"]
        second = (
            first["frame"]
            .replace("word", "second")
            .replace("always", "quickly")
            .replace("usually", "promptly")
            .replace("} %", "}%")
        )
        source = "The system " + first["frame"] + "terminates " + second + "."
        return (
            "The system always terminates quickly.",
            source,
            [("always", "usually"), ("quickly", "promptly")],
        )
    if name == "revision":
        fixture = FIXTURES["word"]
        return (
            fixture["source"],
            fixture["source"].replace("usually", "often"),
            [("always", "often")],
        )
    fixture = FIXTURES[SCENARIOS[name]]
    return (
        fixture["rejected"],
        fixture["source"],
        [(fixture["original"], fixture["proposed"])],
    )


def expected_accepted(name):
    """Return the independently specified plain result, including placement."""
    if name == "pair":
        return "The system usually terminates promptly."
    if name == "revision":
        return "The system often terminates."
    return FIXTURES[SCENARIOS[name]]["accepted"]


def evaluate_attempt(name, source, legacy=False):
    """Check minimal payload extent, frozen provenance, and formatting separately."""
    before, _, expected = scenario(name)
    try:
        records = GUARD.scan_records(source)
        prior = GUARD.scan_records(before)
    except GUARD.FormatError as error:
        return {"passed": False, "format": False, "error": str(error)}
    precision = [record.arguments[2:] for record in records] == expected
    parts, cursor = [], 0
    for record in records:
        parts.extend(
            (
                source[cursor : record.start],
                record.arguments[3],
                record.whitespace,
            )
        )
        cursor = record.end
    parts.append(source[cursor:])
    placement = "".join(parts) == expected_accepted(name)
    integrity = GUARD.original_projection(
        source, records
    ) == GUARD.original_projection(before, prior)
    for old in prior:
        revised = next(
            (r for r in records if r.arguments[0] == old.arguments[0]), None
        )
        integrity = (
            integrity
            and revised is not None
            and revised.arguments[2] == old.arguments[2]
            and revised.whitespace == old.whitespace
        )
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        (root / ".agentedit.json").write_text(
            "{}" if legacy else '{"tex_edit_format":"blocks-v1"}'
        )
        (root / "paper.tex").write_bytes(before.encode())
        allowed, reason = GUARD.evaluate(
            {
                "cwd": directory,
                "tool_name": "Write",
                "tool_input": {"file_path": "paper.tex", "content": source},
            }
        )
    return {
        "passed": bool(allowed and precision and integrity and placement),
        "format": allowed,
        "precision": precision,
        "placement": placement,
        "integrity": bool(integrity),
        "error": reason,
    }


def main():
    """Report first-attempt and eventual rates without inventing live receipts."""
    attempts = json.loads(Path(sys.argv[1]).read_text())
    legacy = "--legacy" in sys.argv[2:]
    names = set(SCENARIOS) | {"pair", "revision"}
    results = []
    for attempt in attempts:
        results.append(
            dict(
                case=attempt["case"],
                attempt=attempt["attempt"],
                **evaluate_attempt(attempt["case"], attempt["source"], legacy)
            )
        )
    grouped = {
        name: sorted(
            [r for r in results if r["case"] == name],
            key=lambda r: r["attempt"],
        )
        for name in names
    }
    report = {
        "results": results,
        "missing": sorted(name for name, rows in grouped.items() if not rows),
        "first_attempt_passes": sum(
            bool(rows and rows[0]["passed"]) for rows in grouped.values()
        ),
        "eventual_passes": sum(
            bool(rows and rows[-1]["passed"]) for rows in grouped.values()
        ),
        "scenarios": len(names),
        "retries": sum(max(0, len(rows) - 1) for rows in grouped.values()),
    }
    report["first_attempt_format_passes"] = sum(
        bool(rows and rows[0]["format"]) for rows in grouped.values()
    )
    report["integrity_failures"] = sum(
        row.get("integrity") is False for row in results
    )
    report["precision_failures"] = sum(
        row.get("precision") is False for row in results
    )
    report["placement_failures"] = sum(
        row.get("placement") is False for row in results
    )
    print(json.dumps(report, indent=2))
    return (
        0
        if (
            report["eventual_passes"] == len(names)
            and not any(
                report[key]
                for key in (
                    "integrity_failures",
                    "precision_failures",
                    "placement_failures",
                )
            )
        )
        else 1
    )


if __name__ == "__main__":
    raise SystemExit(main())
