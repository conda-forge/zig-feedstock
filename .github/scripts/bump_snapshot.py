#!/usr/bin/env python3
"""Detect and apply a new zig version into recipe/recipe.yaml.

Two channels:
  --channel master  (default) - nightly/dev snapshot tracking (index.json's
                      "master" key, version like "0.17.0-dev.NNNN+hash").
                      Patches context.version, context.snapshot, and the
                      sha256 following the ziglang.org/builds/... source url.
  --channel release - stable release tracking (index.json's highest
                      non-"master" top-level version key). Patches
                      context.version and the sha256 following the
                      ziglang.org/download/<version>/... source url. There
                      is no snapshot field for this channel.

Both channels also patch a secondary "bootstrap" source block if present
(recipe.yaml's `- if: bootstrap_via_upstream` source entry, one url+sha256
per build_platform for zig's own prebuilt binaries at the same
version/snapshot) -- kept in sync unconditionally, independent of whether
bootstrap_via_upstream is currently true or false, so the hashes are
already correct whenever a maintainer flips that flag for a given PR.

Edits are scoped to the context: block (for version/snapshot), to the
sha256 line immediately following the FIRST matching primary source url,
and to the sha256 line immediately following each matched bootstrap
platform url -- never a blind file-wide regex, so the recipe's jinja
templating elsewhere is untouched.
"""
import json
import os
import re
import sys
import urllib.request
from pathlib import Path

INDEX_URL = "https://ziglang.org/download/index.json"

# conda-forge build_platform -> ziglang.org/download/index.json platform key
BOOTSTRAP_PLATFORM_MAP = {
    "osx-arm64": "aarch64-macos",
    "osx-64": "x86_64-macos",
    "win-64": "x86_64-windows",
    "linux-64": "x86_64-linux",
    "linux-aarch64": "aarch64-linux",
    "linux-ppc64le": "powerpc64le-linux",
}


def fetch_index():
    with urllib.request.urlopen(INDEX_URL, timeout=30) as resp:
        return json.load(resp)


def target_master(data):
    master = data["master"]
    version_full = master["version"]  # e.g. "0.17.0-dev.1476+91a29d707"
    base, _, snapshot = version_full.partition("-dev.")
    if not snapshot:
        raise ValueError(f"unexpected master version format: {version_full!r}")
    return base, snapshot, master


def _version_key(v):
    return tuple(int(p) for p in v.split("."))


def target_release(data):
    releases = {k: v for k, v in data.items() if k != "master"}
    latest = max(releases, key=_version_key)
    return releases[latest]["version"], None, releases[latest]


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


def patch_sha256(lines, url_substrings, new_sha256):
    for i, line in enumerate(lines):
        if all(s in line for s in url_substrings):
            m = re.match(r"^(\s*sha256:\s*)[0-9a-f]{64}(\s*)$", lines[i + 1])
            if not m:
                raise ValueError(f"expected sha256 line after source url, got: {lines[i + 1]!r}")
            lines[i + 1] = f"{m.group(1)}{new_sha256}{m.group(2)}"
            return True
    return False


def patch_bootstrap_sha256s(lines, entry):
    """Patch each bootstrap platform's sha256 if its url block is present.
    Tolerant of missing blocks (some recipes may not have all platforms, or
    any bootstrap block at all) -- returns the list of platforms actually
    patched, does not raise on absence.
    """
    patched = []
    for conda_platform, zig_platform in BOOTSTRAP_PLATFORM_MAP.items():
        platform_entry = entry.get(zig_platform)
        if not platform_entry:
            continue
        marker = f"zig-{zig_platform}-"
        for i, line in enumerate(lines):
            if marker in line and "url:" in line:
                m = re.match(r"^(\s*sha256:\s*)[0-9a-f]{64}(\s*)$", lines[i + 1])
                if not m:
                    raise ValueError(
                        f"expected sha256 line after {conda_platform} ({zig_platform}) "
                        f"bootstrap url, got: {lines[i + 1]!r}"
                    )
                lines[i + 1] = f"{m.group(1)}{platform_entry['shasum']}{m.group(2)}"
                patched.append(conda_platform)
                break
    return patched


def read_current(lines, channel):
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
            if channel == "master":
                ms = re.match(r'^\s*snapshot:\s*"([^"]*)"', line)
                if ms:
                    snapshot = ms.group(1)
    return version, snapshot


def main():
    if len(sys.argv) < 2:
        print("usage: bump_snapshot.py <path/to/recipe.yaml> [--channel master|release]", file=sys.stderr)
        return 2
    recipe_path = Path(sys.argv[1])
    channel = "master"
    if "--channel" in sys.argv:
        channel = sys.argv[sys.argv.index("--channel") + 1]
    if channel not in ("master", "release"):
        print(f"error: unknown channel {channel!r}", file=sys.stderr)
        return 2

    text = recipe_path.read_text()
    lines = text.splitlines(keepends=True)

    old_version, old_snapshot = read_current(lines, channel)
    if old_version is None:
        print("error: could not locate version in context: block", file=sys.stderr)
        return 2
    if channel == "master" and old_snapshot is None:
        print("error: could not locate snapshot in context: block for master channel", file=sys.stderr)
        return 2

    data = fetch_index()
    if channel == "master":
        new_version, new_snapshot, entry = target_master(data)
        old_id, new_id = old_snapshot, new_snapshot
        url_substrings = ["ziglang.org/builds/zig-", ".tar.xz"]
    else:
        new_version, new_snapshot, entry = target_release(data)
        old_id, new_id = old_version, new_version
        url_substrings = ["ziglang.org/download/", "/zig-"]

    tarball_url = entry["src"]["tarball"]
    shasum = entry["src"]["shasum"]

    changed = new_id != old_id
    print(f"channel: {channel}")
    print(f"current: version={old_version} snapshot={old_snapshot}")
    print(f"latest:  version={new_version} snapshot={new_snapshot}")
    print(f"tarball: {tarball_url}")
    print(f"changed: {changed}")

    gh_out = os.environ.get("GITHUB_OUTPUT")

    if not changed:
        if gh_out:
            with open(gh_out, "a") as f:
                f.write("changed=false\n")
        return 0

    if not patch_context_block(lines, "version", new_version):
        print("error: failed to patch version in context block", file=sys.stderr)
        return 1
    if channel == "master":
        if not patch_context_block(lines, "snapshot", new_snapshot):
            print("error: failed to patch snapshot in context block", file=sys.stderr)
            return 1
    if not patch_sha256(lines, url_substrings, shasum):
        print("error: failed to patch sha256 after source url", file=sys.stderr)
        return 1

    bootstrap_patched = patch_bootstrap_sha256s(lines, entry)
    print(f"bootstrap platforms patched: {', '.join(bootstrap_patched) if bootstrap_patched else '(none found)'}")

    recipe_path.write_text("".join(lines))
    print(f"updated {recipe_path}")

    if gh_out:
        with open(gh_out, "a") as f:
            f.write("changed=true\n")
            f.write(f"old_version={old_version}\n")
            f.write(f"old_snapshot={old_snapshot or ''}\n")
            f.write(f"new_version={new_version}\n")
            f.write(f"new_snapshot={new_snapshot or ''}\n")
            f.write(f"old_id={old_id}\n")
            f.write(f"new_id={new_id}\n")
            f.write(f"tarball_url={tarball_url}\n")
            f.write(f"sha256={shasum}\n")
            f.write(f"bootstrap_patched={','.join(bootstrap_patched)}\n")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
