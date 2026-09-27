#!/usr/bin/env python3
"""Checks that diagnostic messages quoted in documentation still match the source.

A quote such as

    error: [ALU-CONFIG-5004] Configuration key 'mail.host' is not set in any source

mixes the message's fixed text with values filled in at run time: key names,
module names, addresses, durations. The check splits the quote at those values
and requires each remaining run of three or more plain words to appear in the
source that owns the code's family. A reworded message leaves its old wording
in the docs, and that wording no longer appears anywhere in the source.

It does not prove a quote is complete, only that no part of it is stale.

usage: check-diagnostic-quotes.py --docs <file-or-dir>... --source <PREFIX>=<dir>...
  e.g. --source ALU=Sources --source HGR=../hangar/Sources
A quote whose family has no --source is skipped (its owner checks it).
"""
import argparse
import os
import re
import sys

QUOTE = re.compile(r"\[((?:ALU|HGR|ALD)-[A-Z]+)-(\d{4})\]\s+([^\n`]+)")
# A value filled in at run time: anything quoted, or a token with a digit,
# an internal capital (a type or module name), a path, or a dotted/dashed key.
VALUE = re.compile(
    r"'[^']*'|\"[^\"]*\"|“[^”]*”|‘[^’]*’"
    r"|\([^)]*\)"
    r"|\b[A-Z][A-Z0-9_]{3,}\b"
    r"|\S*\d\S*"
    r"|\b[a-z]*[A-Z][A-Za-z]*[a-z][A-Z]\w*\b"
    r"|\b[A-Z][a-z]+[A-Z]\w*\b"
    r"|\S*[/.]\S*[A-Za-z]\S*"
    r"|\S+-\S+"
)
WORD = re.compile(r"[A-Za-z][A-Za-z']*")


def markdown_files(paths):
    for path in paths:
        if os.path.isfile(path):
            yield path
            continue
        for root, dirs, files in os.walk(path):
            dirs[:] = [d for d in dirs if d not in (".build", "node_modules", ".git", "build")]
            for name in files:
                if name.endswith(".md"):
                    yield os.path.join(root, name)


def normalized_source(directory):
    """All Swift and Markdown text under `directory`, with string-literal line
    continuations joined and whitespace collapsed, so a message split across
    lines reads as it prints."""
    chunks = []
    for root, dirs, files in os.walk(directory):
        dirs[:] = [d for d in dirs if d not in (".build", ".git")]
        for name in files:
            if name.endswith(".swift"):
                with open(os.path.join(root, name), encoding="utf-8", errors="replace") as handle:
                    text = handle.read()
                text = re.sub(r"\\\n\s*", "", text)          # "…or \<newline>    alula" → "…or alula"
                text = re.sub(r"\\\(", " \\(", text)
                chunks.append(re.sub(r"\s+", " ", text))
    return "\n".join(chunks)


def fragments(message):
    """The runs of fixed wording in a quoted message: at least three words
    between values filled in at run time."""
    message = re.sub(r"\s+", " ", message).strip()
    message = re.split(r"\s+(?:see|docs:|See)\s+https?://", message)[0]
    # A message is often built from several source strings joined into
    # sentences, so each sentence and each dash-separated clause stands alone.
    pieces = [part for chunk in re.split(r"(?<=[.;])\s+(?=[A-Z])|\s+—\s+", message) for part in VALUE.split(chunk)]
    result = []
    for piece in pieces:
        piece = piece.strip(" ,;:()—-.…")
        if len(WORD.findall(piece)) >= 3:
            result.append(piece)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--docs", nargs="+", required=True)
    parser.add_argument("--source", action="append", default=[], metavar="PREFIX=DIR")
    args = parser.parse_args()

    sources = {}
    for spec in args.source:
        prefix, _, directory = spec.partition("=")
        sources.setdefault(prefix, []).append(normalized_source(directory))
    haystacks = {prefix: "\n".join(texts) for prefix, texts in sources.items()}

    checked = 0
    failures = []
    for path in sorted(set(markdown_files(args.docs))):
        with open(path, encoding="utf-8", errors="replace") as handle:
            lines = handle.readlines()
        for number, line in enumerate(lines, 1):
            for match in QUOTE.finditer(line):
                family, code, message = match.group(1), match.group(2), match.group(3)
                prefix = family.split("-")[0]
                if prefix not in haystacks:
                    continue
                for fragment in fragments(message):
                    checked += 1
                    if fragment not in haystacks[prefix]:
                        failures.append(f"{path}:{number}: [{family}-{code}] “{fragment}” is not in the source")
    for failure in failures:
        print(f"::error::{failure}")
    print(f"diagnostic quotes: {checked} fragment(s) checked, {len(failures)} stale")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
