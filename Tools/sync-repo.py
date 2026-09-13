#!/usr/bin/env python3
"""Merge a freshly built .deb into a flat Sileo/Zebra (apt) repository.

    sync-repo.py --repo-dir REPO --deb FILE.deb --origin https://host/repo

- Reads the control fields straight out of the deb (needs dpkg-deb).
- Adds or updates the entry for that package in Packages, dropping older
  entries of the same package and leaving every other package alone.
- Copies the deb into the repo (default ./debs/, or wherever the package's
  existing entry pointed, so an established repo keeps its layout).
- Rewrites Packages, Packages.gz and Packages.bz2, and refreshes the Date
  and MD5Sum/SHA256 stanzas of an existing Release file.

Idempotent: running it twice with the same deb changes nothing.

Release.gpg / InRelease cannot be regenerated here (they need the repo's
private key); if they exist the script warns that they are now stale.
"""

import argparse
import bz2
import gzip
import hashlib
import os
import re
import shutil
import subprocess
import sys
import time


def die(msg):
    print(f"sync-repo.py: {msg}", file=sys.stderr)
    sys.exit(1)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def control_paragraph(deb):
    """The deb's control stanza, verbatim, without a trailing blank line."""
    out = subprocess.run(["dpkg-deb", "-f", deb], capture_output=True, text=True)
    if out.returncode != 0:
        die(f"dpkg-deb -f failed: {out.stderr.strip()}")
    return out.stdout.rstrip("\n")


def parse_packages(path):
    """Existing Packages paragraphs as a list of raw strings."""
    if not os.path.exists(path):
        return []
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    return [p for p in re.split(r"\n\s*\n", text) if p.strip()]


def field(paragraph, name):
    m = re.search(rf"^{name}: (.*)$", paragraph, re.MULTILINE)
    return m.group(1).strip() if m else None


def refresh_release(repo_dir):
    release = os.path.join(repo_dir, "Release")
    if not os.path.exists(release):
        return
    with open(release, "r", encoding="utf-8") as f:
        text = f.read()

    # Date: RFC 2822, UTC.
    now = time.strftime("%a, %d %b %Y %H:%M:%S UTC", time.gmtime())
    if re.search(r"^Date: ", text, re.MULTILINE):
        text = re.sub(r"^Date: .*$", f"Date: {now}", text, flags=re.MULTILINE)
    else:
        text = f"Date: {now}\n" + text

    # Replace existing MD5Sum: and SHA256: stanzas (header plus its indented
    # checksum lines) with ones computed from the Packages files we wrote.
    names = []
    for name in ("Packages", "Packages.gz", "Packages.bz2"):
        p = os.path.join(repo_dir, name)
        if os.path.exists(p):
            names.append((name, os.path.getsize(p), md5(p), sha256(p)))

    def stanza(header, hash_fn):
        lines = [header + ":"]
        for name, size, m5, s256 in names:
            lines.append(f" {hash_fn(name, size, m5, s256)} {size} {name}")
        return "\n".join(lines)

    md5_stanza = stanza("MD5Sum", lambda n, s, m5, s2: m5)
    sha_stanza = stanza("SHA256", lambda n, s, m5, s2: s2)
    text = re.sub(r"^MD5Sum:\n(?: .*\n?)+", md5_stanza + "\n", text, flags=re.MULTILINE)
    text = re.sub(r"^SHA256:\n(?: .*\n?)+", sha_stanza + "\n", text, flags=re.MULTILINE)

    with open(release, "w", encoding="utf-8") as f:
        f.write(text)
    print(f"  Release refreshed (Date, MD5Sum, SHA256)")

    for signed in ("Release.gpg", "InRelease"):
        if os.path.exists(os.path.join(repo_dir, signed)):
            print(f"  WARNING: {signed} is now stale — it needs your GPG key to "
                  f"regenerate. Repos without Release.gpg work fine in Sileo; "
                  f"signed ones need the key added to CI.", file=sys.stderr)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo-dir", required=True, help="the repository root, on disk")
    ap.add_argument("--deb", required=True, help="the .deb to publish")
    ap.add_argument("--origin", required=True,
                    help="repository URL as entered in Sileo, e.g. https://host/repo")
    args = ap.parse_args()

    if not os.path.isfile(args.deb):
        die(f"no such deb: {args.deb}")
    os.makedirs(args.repo_dir, exist_ok=True)

    para = control_paragraph(args.deb)
    name = field(para, "Package")
    if not name:
        die("the deb's control has no Package field")
    version = field(para, "Version") or "?"
    print(f"publishing {name} {version} into {args.repo_dir}")

    # Where the deb lives inside the repo: keep the path convention the
    # package already uses, so an established repo's URLs stay stable.
    packages_path = os.path.join(args.repo_dir, "Packages")
    existing = parse_packages(packages_path)
    old_dir = None
    kept = []
    for p in existing:
        if field(p, "Package") == name:
            fn = field(p, "Filename") or ""
            old_dir = os.path.dirname(fn) or old_dir
            continue  # drop older versions of this package
        kept.append(p)

    deb_name = os.path.basename(args.deb)
    # Canonicalise whatever the old entry said ("./debs", "debs", ".") into
    # a clean relative directory, then keep the repo's convention.
    rel_dir = (old_dir or "debs").lstrip("./").strip("/") or "debs"
    filename = f"./{rel_dir}/{deb_name}"
    dest = os.path.join(args.repo_dir, rel_dir, deb_name)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    shutil.copy2(args.deb, dest)
    print(f"  {dest}  ({os.path.getsize(dest)} bytes)")

    entry = (f"{para}\n"
             f"Filename: {filename}\n"
             f"Size: {os.path.getsize(args.deb)}\n"
             f"SHA256: {sha256(args.deb)}")
    paragraphs = kept + [entry]
    text = "\n\n".join(p.strip() for p in paragraphs) + "\n"
    with open(packages_path, "w", encoding="utf-8") as f:
        f.write(text)
    with gzip.open(packages_path + ".gz", "wb") as f:
        f.write(text.encode())
    with bz2.open(packages_path + ".bz2", "wb") as f:
        f.write(text.encode())
    print(f"  Packages (+.gz, +.bz2): {len(paragraphs)} entries")

    refresh_release(args.repo_dir)
    print(f"done. Sileo should offer {version} next refresh.")


if __name__ == "__main__":
    main()
