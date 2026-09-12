#!/usr/bin/env python3
"""Run esctest inside whichever terminal is showing this, and record the result.

esctest works by writing escape sequences to its own tty and reading the
terminal's replies back, so it measures the terminal you run it in — not the
one the machine happens to prefer. That is what makes a fair comparison
possible at all: the same suite, the same arguments, run once in diffTerm and
once in NewTerm, then diffed.

    # in diffTerm
    make conformance LABEL=diffterm
    # in NewTerm
    make conformance LABEL=newterm
    # anywhere
    make conformance-report

Results land in build/conformance/<label>.tsv as `name<TAB>status`, which is
what report.py compares.
"""

import argparse
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ESCTEST = os.path.join(ROOT, "build", "esctest", "esctest")
OUTDIR = os.path.join(ROOT, "build", "conformance")

# esctest logs one "Run test: NAME" line, then one line saying how it went.
RUN_RE = re.compile(r"^Run test: (\S+)")
STATUS = [
    (re.compile(r"^Passed\."), "pass"),
    (re.compile(r"^Fails as expected: "), "known-bug"),
    (re.compile(r"^Skipped because terminal lacks requisite capability"), "skip"),
    (re.compile(r"^\*\*\* TEST (\S+) FAILED:"), "fail"),
]


def parse(logpath):
    """Turns the log into {test name: status}."""
    results = {}
    current = None
    with open(logpath, "r", errors="replace") as handle:
        for raw in handle:
            line = raw.strip()
            match = RUN_RE.match(line)
            if match:
                current = match.group(1)
                # A test that never reports is a hang or a crash, and saying so
                # is more useful than dropping it.
                results.setdefault(current, "no-result")
                continue
            for pattern, status in STATUS:
                if pattern.match(line):
                    name = current
                    if status == "fail":
                        name = pattern.match(line).group(1)
                    if name:
                        results[name] = status
                    break
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--label", required=True,
                        help="Name for this terminal, e.g. diffterm or newterm")
    parser.add_argument("--timeout", default="1.5",
                        help="Seconds to wait for a reply. Raise it on a slow device.")
    parser.add_argument("--max-vt-level", default="5")
    args = parser.parse_args()

    if not os.path.isdir(ESCTEST):
        sys.exit("esctest is not present — run `make conformance-fetch` first (needs network).")
    if not sys.stdout.isatty():
        sys.exit("This has to run in the terminal being measured, not through a pipe.")

    os.makedirs(OUTDIR, exist_ok=True)
    logfile = os.path.join(OUTDIR, "%s.log" % args.label)

    command = [
        sys.executable, "esctest.py",
        "--expected-terminal=xterm",
        "--max-vt-level=%s" % args.max_vt_level,
        "--timeout=%s" % args.timeout,
        "--logfile=%s" % logfile,
        # Keep going after a failure: a comparison needs every result, not the
        # first disagreement.
        "--force",
        "--no-print-logs",
    ]
    print("running esctest in this terminal (%s)…" % args.label)
    subprocess.call(command, cwd=ESCTEST)

    results = parse(logfile)
    if not results:
        sys.exit("No results parsed from %s — did the suite run?" % logfile)

    out = os.path.join(OUTDIR, "%s.tsv" % args.label)
    with open(out, "w") as handle:
        for name in sorted(results):
            handle.write("%s\t%s\n" % (name, results[name]))

    counts = {}
    for status in results.values():
        counts[status] = counts.get(status, 0) + 1
    print("\n%s: %d tests — %s" % (
        args.label, len(results),
        ", ".join("%d %s" % (n, s) for s, n in sorted(counts.items()))))
    print("wrote %s" % out)


if __name__ == "__main__":
    main()
