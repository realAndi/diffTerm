#!/usr/bin/env python3
"""Diff two esctest result files into a Markdown table.

The point of this is to replace "our feature list is longer" with a number,
including where the number goes against us — a comparison that only reports
wins is marketing, not a measurement, and this project is called diffTerm.
"""

import argparse
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUTDIR = os.path.join(ROOT, "build", "conformance")

# Ordered worst to best, so a category label can be picked by comparing.
RANK = {"no-result": 0, "fail": 1, "known-bug": 2, "skip": 3, "pass": 4}


def load(label):
    path = os.path.join(OUTDIR, "%s.tsv" % label)
    if not os.path.exists(path):
        sys.exit("No results for '%s'. Run `make conformance LABEL=%s` in that terminal."
                 % (label, label))
    results = {}
    with open(path) as handle:
        for line in handle:
            if "\t" not in line:
                continue
            name, status = line.rstrip("\n").split("\t", 1)
            results[name] = status
    return results


def summarise(results):
    counts = {}
    for status in results.values():
        counts[status] = counts.get(status, 0) + 1
    return counts


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--a", default="diffterm")
    parser.add_argument("--b", default="newterm")
    args = parser.parse_args()

    a, b = load(args.a), load(args.b)
    names = sorted(set(a) | set(b))

    a_only, b_only, both_fail, agree = [], [], [], 0
    for name in names:
        sa, sb = a.get(name, "no-result"), b.get(name, "no-result")
        if sa == sb:
            agree += 1
            if RANK[sa] <= RANK["fail"]:
                both_fail.append(name)
            continue
        if RANK[sa] > RANK[sb]:
            a_only.append((name, sa, sb))
        else:
            b_only.append((name, sa, sb))

    ca, cb = summarise(a), summarise(b)

    def row(label, counts, total):
        passed = counts.get("pass", 0)
        return "| %s | %d | %d | %d | %d | %.1f%% |" % (
            label, passed, counts.get("fail", 0) + counts.get("no-result", 0),
            counts.get("known-bug", 0), counts.get("skip", 0),
            100.0 * passed / total if total else 0.0)

    print("# esctest conformance\n")
    print("Same suite, same arguments, run inside each terminal. %d tests compared.\n"
          % len(names))
    print("| terminal | pass | fail | known bug | skipped | pass rate |")
    print("|---|---|---|---|---|---|")
    print(row(args.a, ca, len(names)))
    print(row(args.b, cb, len(names)))

    def section(title, rows):
        print("\n## %s (%d)\n" % (title, len(rows)))
        if not rows:
            print("_None._")
            return
        print("| test | %s | %s |" % (args.a, args.b))
        print("|---|---|---|")
        for name, sa, sb in rows:
            print("| `%s` | %s | %s |" % (name, sa, sb))

    section("Where %s does better" % args.a, a_only)
    section("Where %s does better" % args.b, b_only)

    print("\n## Failing in both (%d)\n" % len(both_fail))
    if both_fail:
        print(", ".join("`%s`" % n for n in both_fail))
    else:
        print("_None._")

    print("\n%d tests agreed." % agree)


if __name__ == "__main__":
    main()
