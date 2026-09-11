#!/usr/bin/env python3
"""Validate and compose Modeleaf release notes.

Release summaries are small, hand-written Markdown bullet lists. GitHub's
generated notes remain the detailed change list; this module places the summary
in one deterministic section ahead of that generated content.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Optional, Sequence, Tuple, Union


class ReleaseNotesError(ValueError):
    """Raised when a release summary or notes input cannot be used."""


_PLACEHOLDER_RE = re.compile(
    r"^(?:todo|tbd|n/?a|placeholder(?:\s+summary)?|your\s+summary(?:\s+here)?|coming\s+soon)"
    r"(?:[\s:!.,;\-].*)?$",
    re.IGNORECASE,
)
_BULLET_RE = re.compile(r"^([-*+])\s+(\S(?:.*\S)?)\s*$")
_HIGHLIGHTS_RE = re.compile(r"^##\s+highlights\s*$", re.IGNORECASE)
_LEVEL_ONE_OR_TWO_HEADING_RE = re.compile(r"^#{1,2}\s+\S")
_FENCE_RE = re.compile(r"^\s*(`{3,}|~{3,})(.*)$")
PathLike = Union[Path, str]
Fence = Tuple[str, int, str]


def validate_summary(text: str, *, version: Optional[str] = None) -> str:
    """Validate and canonicalize a release summary.

    A summary is one or more non-empty, one-line Markdown unordered bullets.
    Blank lines between bullets are accepted and removed from the canonical
    result. The helper validates structure only; it does not try to guess
    whether prose is English.
    """

    if not isinstance(text, str):
        raise ReleaseNotesError("summary must be text")

    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    if not any(line.strip() for line in lines):
        suffix = f" for version {version}" if version else ""
        raise ReleaseNotesError(f"release summary{suffix} is empty")

    bullets: list[str] = []
    for line_number, line in enumerate(lines, start=1):
        if not line.strip():
            continue
        match = _BULLET_RE.fullmatch(line)
        if match is None:
            raise ReleaseNotesError(
                f"release summary line {line_number} must be a non-empty Markdown bullet"
            )
        content = match.group(2).strip()
        if _PLACEHOLDER_RE.fullmatch(content):
            raise ReleaseNotesError(
                f"release summary line {line_number} is a placeholder; write a user-facing bullet"
            )
        bullets.append(f"- {content}")

    if not bullets:
        suffix = f" for version {version}" if version else ""
        raise ReleaseNotesError(f"release summary{suffix} has no bullets")
    return "\n".join(bullets)


def _read_text(path: PathLike, *, label: str) -> str:
    file_path = Path(path)
    try:
        return file_path.read_text(encoding="utf-8")
    except UnicodeDecodeError as error:
        raise ReleaseNotesError(f"{label} is not valid UTF-8: {file_path}") from error
    except OSError as error:
        raise ReleaseNotesError(f"could not read {label} {file_path}: {error}") from error


def read_summary(path: PathLike, *, version: Optional[str] = None) -> str:
    """Read and validate a UTF-8 summary file."""

    summary_path = Path(path)
    if not summary_path.is_file():
        suffix = f" for version {version}" if version else ""
        raise ReleaseNotesError(f"missing release summary{suffix}: {summary_path}")
    return validate_summary(_read_text(summary_path, label="release summary"), version=version)


def _fence(line: str) -> Optional[Fence]:
    match = _FENCE_RE.fullmatch(line)
    if match is None:
        return None
    marker = match.group(1)
    return marker[0], len(marker), match.group(2)


def _without_highlights(generated: str) -> str:
    """Remove prior Highlights sections while retaining all other notes."""

    normalized = generated.replace("\r\n", "\n").replace("\r", "\n")
    kept: list[str] = []
    in_highlights = False
    open_fence: Optional[Tuple[str, int]] = None

    for line in normalized.split("\n"):
        marker = _fence(line)
        if open_fence is not None:
            fence_char, fence_length = open_fence
            is_closing = (
                marker is not None
                and marker[0] == fence_char
                and marker[1] >= fence_length
                and not marker[2].strip()
            )
            if is_closing:
                open_fence = None
            if not in_highlights:
                kept.append(line)
            continue

        if marker is not None:
            open_fence = (marker[0], marker[1])
            if not in_highlights:
                kept.append(line)
            continue

        stripped = line.strip()
        if _HIGHLIGHTS_RE.fullmatch(stripped):
            in_highlights = True
            continue
        if in_highlights:
            # A level-one or level-two heading outside a matching fence starts
            # the next generated section. Deeper headings remain in Highlights.
            if _LEVEL_ONE_OR_TWO_HEADING_RE.match(stripped):
                in_highlights = False
                kept.append(line)
            continue
        kept.append(line)

    return "\n".join(kept).strip()


def compose_release_notes(summary: str, generated: str) -> str:
    """Return one Highlights section followed by generated GitHub notes."""

    canonical_summary = validate_summary(summary)
    if not isinstance(generated, str):
        raise ReleaseNotesError("generated notes must be text")
    generated_body = _without_highlights(generated)
    sections = ["## Highlights", canonical_summary]
    if generated_body:
        sections.append(generated_body)
    return "\n\n".join(sections) + "\n"


def compose_files(
    summary_path: PathLike,
    generated_path: PathLike,
    output_path: PathLike,
    *,
    version: Optional[str] = None,
) -> None:
    """Compose files and write the deterministic body to ``output_path``."""

    summary = read_summary(summary_path, version=version)
    generated = _read_text(generated_path, label="generated notes")
    body = compose_release_notes(summary, generated)
    try:
        Path(output_path).write_text(body, encoding="utf-8")
    except OSError as error:
        raise ReleaseNotesError(f"could not write composed release notes {output_path}: {error}") from error


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    validate = commands.add_parser("validate", help="validate a release summary file")
    validate.add_argument("--summary", required=True, dest="summary_path", type=Path)
    validate.add_argument("--version", required=True, help="version used in diagnostics")

    compose = commands.add_parser(
        "compose", help="compose a summary with generated GitHub notes"
    )
    compose.add_argument("--summary", required=True, dest="summary_path", type=Path)
    compose.add_argument("--generated", required=True, dest="generated_path", type=Path)
    compose.add_argument("--output", required=True, dest="output_path", type=Path)
    compose.add_argument("--version", required=True, help="version used in diagnostics")
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "validate":
            read_summary(args.summary_path, version=args.version)
            print(f"Validated release summary: {args.summary_path}")
            return 0

        compose_files(
            args.summary_path,
            args.generated_path,
            args.output_path,
            version=args.version,
        )
    except (OSError, UnicodeDecodeError, ReleaseNotesError) as error:
        print(f"release_notes: error: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
