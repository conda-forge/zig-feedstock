#!/usr/bin/env python3
"""Detect and apply a new zig nightly snapshot into recipe/recipe.yaml.

Reads the current version/snapshot from recipe.yaml's context block, compares
against ziglang.org/download/index.json's "master" build, and if newer,
rewrites the version/snapshot/sha256 in place. Edits are scoped to the
context: block (for version/snapshot) and to the sha256 line immediately
following the ziglang.org/builds source url (for sha256) -- never a blind
file-wide regex, so the recipe's jinja templating elsewhere is untouched.
"""
import json
import re
import sys
import urllib.request
from pathlib import Path

INDEX_URL = "https://ziglang.org/download/index.json"


def fetch_master():
    with urllib.request.urlopen(INDEX_URL, timeout=30) as resp:
        data = json.load(resp)
    master = data["master"]
    version_full = master["version"]  # e.g. "0.17.0-dev.1476+91a29d707"
    src = master["src"]
    return version_full, src["tarball"], src["shasum"]


def split_version(version_full):
    base, _, snapshot = version_full.partition("-dev.")
    if not snapshot:
        raise ValueError(f"unexpected version format: {version_full!r}")
    return base, snapshot


def patch_context_block(lines, key, new_value):
    in_context = False
    pattern = re.compile(rf'^(\s*{key}:\s*)"[^"]*"(\s*)$')
    for i, line in enumerate(lines):
        if re.match(r"^context:\s*$", line):
            in_context = True
            continue
        if in_context and re.match(r"^\S", line):
            break
        if in_context:
            m = pattern.match(line)
            if m:
                lines[i] = f'{m.group(1)}"{new_value}"{m.group(2)}'
                return True
    return False


def patch_sha256(lines, new_sha256):
    for i, line in enumerate(lines):
        if "ziglang.org/builds/zig-" in line and ".tar.xz" in line:
            m = re.match(r"^(\s*sha256:\s*)[0-9a-f]{64}(\s*)$", lines[i + 1])
            if not m:
                raise ValueError(f"expected sha256 line after source url, got: {lines[i + 1]!r}")
            lines[i + 1] = f"{m.group(1)}{new_sha256}{m.group(2)}"
            return True
    return False


def read_current(lines):
    version = snapshot = None
    in_context = False
    for line in lines:
        if re.match(r"^context:\s*$", line):
            in_context = True
            continue
        if in_context and re.match(r"^\S", line):
            break
        if in_context:
            mv = re.match(r'^\s*version:\s*"([^"]*)"', line)
            if mv:
                version = mv.group(1)
            ms = re.match(r'^\s*snapshot:\s*"([^"]*)"', line)
            if ms:
                snapshot = ms.group(1)
    return version, snapshot


def main():
    if len(sys.argv) != 2:
        print("usage: bump_snapshot.py <path/to/recipe.yaml>", file=sys.stderr)
        return 2
    recipe_path = Path(sys.argv[1])
    text = recipe_path.read_text()
    lines = text.splitlines(keepends=True)

    old_version, old_snapshot = read_current(lines)
    if old_version is None or old_snapshot is None:
        print("error: could not locate version/snapshot in context: block", file=sys.stderr)
        return 2

    version_full, tarball_url, shasum = fetch_master()
    new_version, new_snapshot = split_version(version_full)

    changed = new_snapshot != old_snapshot
    print(f"current: version={old_version} snapshot={old_snapshot}")
    print(f"latest:  version={new_version} snapshot={new_snapshot}")
    print(f"tarball: {tarball_url}")
    print(f"changed: {changed}")

    gh_out = sys.environ.get("GITHUB_OUTPUT")
    if gh_out:
        with open(gh_out, "a") as f:
            f.write(f"changed={'true' if changed else 'false'}\n")
            f.write(f"old_version={old_version}\n")
            f.write(f"old_snapshot={old_snapshot}\n")
            f.write(f"new_version={new_version}\n")
            f.write(f"new_snapshot={new_snapshot}\n")
            f.write(f"tarball_url={tarball_url}\n")
            f.write(f"sha256={shasum}\n")

    if not changed:
        return 0

    if not patch_context_block(lines, "version", new_version):
        print("error: failed to patch version in context block", file=sys.stderr)
        return 1
    if not patch_context_block(lines, "snapshot", new_snapshot):
        print("error: failed to patch snapshot in context block", file=sys.stderr)
        return 1
    if not patch_sha256(lines, shasum):
        print("error: failed to patch sha256 after source url", file=sys.stderr)
        return 1

    recipe_path.write_text("".join(lines))
    print(f"updated {recipe_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
