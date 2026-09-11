#!/usr/bin/env python3
"""Unit tests for deterministic release-note composition."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from release_notes import ReleaseNotesError, compose_release_notes, validate_summary


class ReleaseNotesTests(unittest.TestCase):
    def test_empty_summary_is_rejected(self) -> None:
        with self.assertRaisesRegex(ReleaseNotesError, "empty"):
            validate_summary("\n  \n")

    def test_malformed_summary_is_rejected(self) -> None:
        with self.assertRaisesRegex(ReleaseNotesError, "line 1"):
            validate_summary("This is release prose, not a bullet")

    def test_composition_is_idempotent(self) -> None:
        summary = "- Faster page navigation\n- Clearer update instructions"
        generated = "## What's Changed\n\n* Improve keyboard routing\n\n## New Contributors\n\n* @reader"

        first = compose_release_notes(summary, generated)
        self.assertEqual(compose_release_notes(summary, first), first)
        self.assertEqual(first.count("## Highlights"), 1)
        self.assertTrue(first.startswith("## Highlights\n\n"))

    def test_generated_notes_are_preserved_on_rerun(self) -> None:
        summary = "- Add a focused release summary"
        generated = (
            "## Highlights\n\n- An earlier summary\n\n"
            "## What's Changed\n\n* Preserve this generated detail\n\n"
            "## New Contributors\n\n* @contributor"
        )

        composed = compose_release_notes(summary, generated)
        self.assertEqual(composed.count("## Highlights"), 1)
        self.assertIn("## What's Changed\n\n* Preserve this generated detail", composed)
        self.assertIn("## New Contributors\n\n* @contributor", composed)
        self.assertIn("- Add a focused release summary", composed)
        self.assertNotIn("- An earlier summary", composed)

    def test_headings_inside_fences_do_not_end_highlights(self) -> None:
        summary = "- Keep the generated release context"
        generated = (
            "## Highlights\n\n- Earlier summary\n\n"
            "````\n## What's Changed\n````\n\n"
            "# Release context\n\n* Preserve this detail"
        )

        composed = compose_release_notes(summary, generated)
        self.assertIn("# Release context\n\n* Preserve this detail", composed)
        self.assertNotIn("## What's Changed\n````", composed)


if __name__ == "__main__":
    unittest.main()
