#!/usr/bin/env python3
"""Reports public declarations whose documentation is missing or thin.

This is a review list, not a gate: it never fails. A short comment is often
the right one — `/// The port the server listens on.` needs nothing more —
so nothing here is rewritten automatically. What the list is for is the
other case: an infrastructure call documented only by paraphrasing its own
name, where a reader still has to open the source to learn what it
guarantees, when it fails, or how long a value may be kept.

Three sections:

  undocumented  public/open declarations with no `///` comment at all
  thin          a comment of one sentence that opens with a paraphrase verb
                ("Returns", "Creates", "Executes", "Gets", "Sets", "Starts",
                "Stops") or with "The configured"/"The current", and says
                nothing past that sentence
  pins          `from: "x.y.z"` pins of this package in the docs that name a
                release other than the latest in CHANGELOG.md; `from:` still
                resolves the newer release, so this matters only when the
                docs show API the pinned release lacks

Members of a type whose declaration is itself undocumented are still listed;
members of extensions are not. Neither can the scan tell a protocol witness
from a new API: `LocalPubSub.publish` shows as undocumented, though DocC
gives it `PubSub.publish`'s comment. Read the undocumented count as an upper
bound, and the list as a place to look.

usage: docs-report.py --package-url <github-url> [--sources Sources]
                      [--docs README.md Docs ...] [--only thin|undocumented|pins]
                      [--limit N]
"""
import argparse
import os
import re
import sys
from collections import Counter

DECL = re.compile(
    r"^\s*(?:@[\w.]+(?:\([^)]*\))?\s+)*"
    r"(?:(?:nonisolated|final|override|static|class|mutating|nonmutating|"
    r"indirect|convenience|required|dynamic|lazy|borrowing|consuming)\s+)*"
    r"(public|open)\s+(?:(?:final|static|class|override|mutating|nonisolated|"
    r"convenience|required|indirect|lazy|dynamic)\s+)*"
    r"(func|var|let|init[?!]?|subscript|struct|class|enum|protocol|actor|"
    r"typealias|case|associatedtype|macro)\b\s*([\w`]*)"
)
PARAPHRASE = re.compile(
    r"^(Returns|Creates|Executes|Gets|Sets|Starts|Stops|Runs|Makes|Builds|"
    r"The configured|The current)\b"
)
PIN = re.compile(r'\.package\(\s*url:\s*"([^"]+)"[^)]*?from:\s*"(\d+\.\d+\.\d+)"', re.S)
RELEASE = re.compile(r"^## \[(\d+\.\d+\.\d+)\]", re.M)


def swift_files(root):
    for base, dirs, files in os.walk(root):
        # Macro implementations are public because the compiler plugin
        # requires it, not because anyone calls them.
        dirs[:] = [d for d in dirs if d not in (".build", "Fixtures")
                   and not d.endswith("MacrosImpl") and d != "hangar-bench"]
        for name in files:
            if name.endswith(".swift") and not name.endswith(".generated.swift"):
                yield os.path.join(base, name)


def doc_block(lines, index):
    """The `///` lines immediately above `index`, skipping attributes."""
    i = index - 1
    while i >= 0 and lines[i].strip().startswith("@"):
        i -= 1
    block = []
    while i >= 0 and lines[i].strip().startswith("///"):
        block.append(lines[i].strip()[3:].strip())
        i -= 1
    return list(reversed(block))


def inside_extension_or_private(lines, index):
    """True when the nearest enclosing type-level scope is an extension.

    A cheap brace-depth walk: good enough for a review list, and wrong only
    by listing a little more or less, never by failing a build.
    """
    depth = 0
    for i in range(index - 1, -1, -1):
        text = lines[i]
        depth += text.count("}") - text.count("{")
        if depth < 0:
            stripped = text.strip()
            if re.match(r"^(?:@[\w.]+\s+)*(?:public\s+|internal\s+|private\s+|fileprivate\s+)?extension\b", stripped):
                return True
            if re.search(r"\b(struct|class|enum|protocol|actor)\b", stripped):
                return False
            depth = 0
    return False


def scan(sources):
    undocumented, thin = [], []
    for path in swift_files(sources):
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().split("\n")
        for index, line in enumerate(lines):
            match = DECL.match(line)
            if not match:
                continue
            kind, name = match.group(2), match.group(3)
            if kind == "case" or inside_extension_or_private(lines, index):
                continue
            block = doc_block(lines, index)
            where = f"{path}:{index + 1}"
            label = f"{kind} {name}".strip()
            if not block:
                undocumented.append((where, label))
                continue
            prose = " ".join(b for b in block if b and not b.startswith("- "))
            sentences = [s for s in re.split(r"(?<=[.!?])\s+", prose) if s]
            if PARAPHRASE.match(prose) and len(sentences) <= 1 and len(prose) < 70:
                thin.append((where, label, prose))
    return undocumented, thin


def pins(docs, package_url, latest):
    found = []
    want = package_url.rstrip("/").removesuffix(".git").lower()
    for doc in docs:
        paths = [doc] if os.path.isfile(doc) else [
            os.path.join(b, f) for b, _, fs in os.walk(doc) for f in fs if f.endswith(".md")
        ]
        for path in paths:
            with open(path, encoding="utf-8") as handle:
                text = handle.read()
            for match in PIN.finditer(text):
                url = match.group(1).rstrip("/").removesuffix(".git").lower()
                if url == want and match.group(2) != latest:
                    line = text.count("\n", 0, match.start()) + 1
                    found.append((f"{path}:{line}", match.group(2)))
    return found


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--package-url", required=True)
    parser.add_argument("--sources", default="Sources")
    parser.add_argument("--docs", nargs="*", default=["README.md", "Docs"])
    parser.add_argument("--only", choices=["thin", "undocumented", "pins"])
    parser.add_argument("--limit", type=int, default=0, help="entries per section; 0 = all")
    args = parser.parse_args()

    undocumented, thin = scan(args.sources)
    with open("CHANGELOG.md", encoding="utf-8") as handle:
        releases = RELEASE.findall(handle.read())
    latest = releases[0] if releases else "0.0.0"
    stale = pins([d for d in args.docs if os.path.exists(d)], args.package_url, latest)

    def show(title, rows, render):
        if args.only and not title.startswith(args.only):
            return
        print(f"## {title}: {len(rows)}")
        for row in rows[: args.limit or None]:
            print(render(row))
        if args.limit and len(rows) > args.limit:
            print(f"… {len(rows) - args.limit} more")
        print()

    show("undocumented public declarations", undocumented, lambda r: f"{r[0]}  {r[1]}")
    show("thin comments to review", thin, lambda r: f"{r[0]}  {r[1]}: “{r[2]}”")
    show(f"pins other than the latest release ({latest})", stale, lambda r: f"{r[0]}  from: \"{r[1]}\"")

    if not args.only:
        # Sources/<Group>/<Module>/… — the module is the third component.
        by_module = Counter(
            (w.split(":")[0].split(os.sep) + ["?"] * 3)[2] for w, _ in undocumented
        )
        print("## undocumented by module")
        for module, count in by_module.most_common():
            print(f"{count:5}  {module}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
