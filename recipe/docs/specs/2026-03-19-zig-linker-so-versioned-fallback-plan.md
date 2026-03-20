# Versioned .so.N Fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix zig's linker to fall back to versioned `.so.N` shared libraries before static `.a` archives, resolving undefined symbol errors when linking against glibc 2.17 sysroots.

**Architecture:** Extend the existing patch 0006 (ld script `-l` handler in `src/link.zig`) with a directory scan for `lib<name>.so.*` between the `.so` and `.a` fallback steps. Separately, pass an explicit `-target` triple for doctest builds to fix `copy_file_range` resolution.

**Tech Stack:** Zig 0.15.2 source patches (unified diff), bash build scripts, conda-forge feedstock tooling.

**Spec:** `recipe/docs/specs/2026-03-19-zig-linker-so-versioned-fallback-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `recipe/patches/0006-elf-linker-handle-relative-paths-and-l-flags-in-ld-scripts.patch` | Modify | Extend `-l` handler with `.so.N` directory scan fallback |
| `recipe/building/build_native_for_test.sh` | Modify | Add `-target x86_64-linux-gnu.2.17` to doctest builds |
| `recipe/build.sh` | Inspect | Verify Stage 1/Stage 2 target handling (may need same fix) |

---

### Task 1: Regenerate patch 0006 with `.so.N` fallback

This task modifies the existing patch 0006 to extend the `-l<name>` handler
inside `loadGnuLdScript()` in `src/link.zig`. The current handler tries
`lib<name>.so` then `lib<name>.a`. We insert a directory scan for
`lib<name>.so.*` between those two steps.

**Files:**
- Modify: `recipe/patches/0006-elf-linker-handle-relative-paths-and-l-flags-in-ld-scripts.patch`
- Reference: `src/link.zig` in zig 0.15.2 source (extracted during patch generation)

**Prerequisite patches** (must be applied before 0006 during generation):
- `0001-linux-maxrss-build.zig.patch`
- `0002-linux-glibc-2.17-use-fstat-not-fstat64.patch`
- `0003-linux-llvm-triple-no-glibc-version.patch`
- `0004-elf-linker-add-zstd-decompression-support.patch`
- `0005-debug-tag-bare-TODO-panics.patch`

- [ ] **Step 1: Extract clean zig source and apply prerequisite patches**

Use the `/conda-patch-generator` skill workflow:
1. Extract zig source from tarball to a temp directory
2. Apply patches 0001–0005 in order
3. Verify clean application (no hunks failed)

```bash
# The conda-patch-generator skill handles this automatically.
# Manual equivalent:
cd /tmp && mkdir zig-patch-work && cd zig-patch-work
tar xf $SRC_DIR/zig-0.15.2.tar.gz
cd zig-0.15.2
for p in 0001-linux-maxrss 0002-linux-glibc 0003-linux-llvm 0004-elf-linker-add-zstd 0005-debug-tag; do
    git apply $RECIPE_DIR/patches/${p}*.patch
done
```

- [ ] **Step 2: Apply current patch 0006 to establish baseline**

```bash
git apply $RECIPE_DIR/patches/0006-elf-linker-handle-relative-paths-and-l-flags-in-ld-scripts.patch
```

Verify: The two `@panic("TODO")` sites in `loadGnuLdScript` are replaced
with the current `-l` handler and relative path resolver.

- [ ] **Step 2b: Locate the exact `-l` handler line**

```bash
# Find the -l handler inside loadGnuLdScript after patch 0006 is applied:
grep -n 'if (mem.startsWith(u8, arg.path, "-l"))' src/link.zig
```

This should return one match inside `loadGnuLdScript()`. Note the line
number — use it to navigate in your editor. The function is recognizable
by the `script_dir`, `sep`, `so_sub` variables.

- [ ] **Step 3: Modify the `-l` handler in `src/link.zig`**

At the line found in Step 2b, the current handler looks like this:

```zig
if (mem.startsWith(u8, arg.path, "-l")) {
    const lib_name = arg.path[2..];
    const script_dir = fs.path.dirname(path.sub_path) orelse "";
    const sep: []const u8 = if (script_dir.len > 0) fs.path.sep_str else "";
    const so_sub = try std.fmt.allocPrint(gpa, "{s}{s}lib{s}.so", .{ script_dir, sep, lib_name });
    const so_path: Path = .{ .root_dir = path.root_dir, .sub_path = so_sub };
    openLoadDso(base, so_path, query) catch |err| switch (err) {
        error.FileNotFound => {
            // .so not found, try static archive
            gpa.free(so_sub);
            const a_sub = try std.fmt.allocPrint(gpa, "{s}{s}lib{s}.a", .{ script_dir, sep, lib_name });
            const a_path: Path = .{ .root_dir = path.root_dir, .sub_path = a_sub };
            openLoadArchive(base, a_path, query) catch |archive_err| switch (archive_err) {
                error.FileNotFound => {
                    gpa.free(a_sub);
                    diags.addParseError(path, "GNU ld script references library not found: {s}", .{arg.path});
                },
                else => return archive_err,
            };
        },
        else => return err,
    };
}
```

Replace the `error.FileNotFound` arm with the extended version that scans
for versioned `.so.N` files before falling back to `.a`:

```zig
if (mem.startsWith(u8, arg.path, "-l")) {
    const lib_name = arg.path[2..];
    const script_dir = fs.path.dirname(path.sub_path) orelse "";
    const sep: []const u8 = if (script_dir.len > 0) fs.path.sep_str else "";
    const so_sub = try std.fmt.allocPrint(gpa, "{s}{s}lib{s}.so", .{ script_dir, sep, lib_name });
    const so_path: Path = .{ .root_dir = path.root_dir, .sub_path = so_sub };
    openLoadDso(base, so_path, query) catch |err| switch (err) {
        error.FileNotFound => {
            gpa.free(so_sub);
            // Try versioned shared library (lib<name>.so.N) before static archive.
            // This handles glibc < 2.34 sysroots where libpthread.so is an ld script
            // that may recurse or fail, but libpthread.so.0 is a real ELF shared lib.
            const found_versioned = blk: {
                const dir_sub: []const u8 = if (script_dir.len > 0) script_dir else ".";
                var dir = path.root_dir.handle.openDir(dir_sub, .{ .iterate = true }) catch break :blk false;
                defer dir.close();
                const prefix = std.fmt.allocPrint(gpa, "lib{s}.so.", .{lib_name}) catch break :blk false;
                defer gpa.free(prefix);
                var iter = dir.iterate();
                while (iter.next() catch null) |entry| {
                    if (mem.startsWith(u8, entry.name, prefix)) {
                        // Ownership of versioned_sub transfers to Input.Dso.path on
                        // success. Only free on failure (the continue path).
                        const versioned_sub = std.fmt.allocPrint(gpa, "{s}{s}{s}", .{
                            script_dir, sep, entry.name,
                        }) catch continue;
                        const versioned_path: Path = .{
                            .root_dir = path.root_dir,
                            .sub_path = versioned_sub,
                        };
                        openLoadDso(base, versioned_path, query) catch {
                            gpa.free(versioned_sub);
                            continue;
                        };
                        break :blk true;
                    }
                }
                break :blk false;
            };
            if (!found_versioned) {
                // Last resort: static archive
                const a_sub = try std.fmt.allocPrint(gpa, "{s}{s}lib{s}.a", .{ script_dir, sep, lib_name });
                const a_path: Path = .{ .root_dir = path.root_dir, .sub_path = a_sub };
                openLoadArchive(base, a_path, query) catch |archive_err| switch (archive_err) {
                    error.FileNotFound => {
                        gpa.free(a_sub);
                        diags.addParseError(path, "GNU ld script references library not found: {s}", .{arg.path});
                    },
                    else => return archive_err,
                };
            }
        },
        else => return err,
    };
}
```

- [ ] **Step 4: Generate the updated patch**

```bash
# From the patched zig source directory:
git diff src/link.zig > /path/to/recipe/patches/0006-elf-linker-handle-relative-paths-and-l-flags-in-ld-scripts.patch
```

Or use the `/conda-patch-generator` skill to generate a properly formatted
git-format-patch with the correct header.

- [ ] **Step 5: Update the patch commit message**

Ensure the patch header reflects the new content:

```
Subject: [PATCH] link(ELF): handle relative paths, -l flags, and versioned
 .so.N fallback in GNU ld scripts

Implement the two TODO panics in loadGnuLdScript that crash when
processing GNU ld scripts containing:

1. Relative paths (e.g. "../lib64/libc_nonshared.a") - resolved
   relative to the directory containing the ld script.

2. -l flags (e.g. "-lpthread") - resolved by searching for
   lib<name>.so, then lib<name>.so.N (versioned), then lib<name>.a
   in the ld script's directory.

The versioned .so.N fallback handles glibc < 2.34 sysroots where
libpthread.so is a GNU ld script (not an ELF shared library).
When the .so ld script fails to resolve (e.g. recursive -lpthread
reference), the fallback finds the real ELF shared object
(libpthread.so.0) before falling back to the static archive (.a).
```

- [ ] **Step 6: Verify the patch applies cleanly**

```bash
# From fresh zig 0.15.2 source with patches 0001-0005 applied:
git apply --check recipe/patches/0006-elf-linker-handle-relative-paths-and-l-flags-in-ld-scripts.patch
```

Expected: No errors.

- [ ] **Step 7: Commit**

```bash
git add recipe/patches/0006-elf-linker-handle-relative-paths-and-l-flags-in-ld-scripts.patch
git commit -m "feat(patch): add versioned .so.N fallback to ld script -l handler"
```

---

### Task 2: Add explicit target for doctest builds

This task fixes the `copy_file_range` undefined symbol by ensuring zig's
std lib targets glibc 2.17 explicitly during doctest compilation.

**Files:**
- Modify: `recipe/building/build_native_for_test.sh:112-124` (ZIG_BUILD_ARGS)
- Inspect: `recipe/build.sh` (check if main build has same issue)

**Note**: `build_native_for_test.sh` is ONLY used for `linux-64` (x86_64)
native test builds. It is not invoked for ppc64le or other architectures.

- [ ] **Step 1: Understand the current target setting**

In `recipe/building/build_native_for_test.sh`, line 120:
```bash
    -Dtarget=native
```

This tells the zig build system to auto-detect the host. On cos7 (glibc 2.17),
zig should detect 2.17, but the doctest sub-compilations may not inherit
this detection correctly.

- [ ] **Step 2: Change `-Dtarget=native` to explicit triple**

In `recipe/building/build_native_for_test.sh`, modify the `ZIG_BUILD_ARGS`
array. Replace line 120:

```bash
# Before:
    -Dtarget=native
# After:
    # Explicit target ensures zig std lib uses raw syscalls for functions
    # not in glibc 2.17 (e.g., copy_file_range). This script is only used
    # for linux-64 (x86_64) native test builds.
    -Dtarget=x86_64-linux-gnu.2.17
```

- [ ] **Step 3: Verify the main build script**

The main build (`recipe/build.sh`) uses `-Dtarget=${ZIG_TRIPLET}` where
`ZIG_TRIPLET` is set from the recipe (e.g., `x86_64-linux-gnu.2.17`).
Verify it already includes the glibc version:

```bash
grep -n 'Dtarget\|ZIG_TRIPLET' recipe/build.sh
```

If `ZIG_TRIPLET` already includes `.2.17`, no change needed for the main
build. The main build also uses `-Dno-langref` (skips doctests) for Stage 1,
so doctests only run in Stage 2 — verify Stage 2 also uses the correct
target triple.

- [ ] **Step 4: Commit**

```bash
git add recipe/building/build_native_for_test.sh
git commit -m "fix: use explicit -target x86_64-linux-gnu.2.17 for doctest builds

Ensures zig's std lib uses raw syscalls for functions added after
glibc 2.17 (e.g., copy_file_range) instead of calling missing
glibc symbols."
```

---

### Task 3: Local validation

**Files:**
- No new files; uses existing test infrastructure

- [ ] **Step 1: Verify patch applies in rattler-build**

Run a local rattler-build to confirm the updated patch 0006 applies cleanly
during the actual conda build process:

```bash
rattler-build build --recipe recipe/recipe.yaml --target-platform linux-64 2>&1 | head -100
```

Watch for: `Applying patch 0006...` with no hunk failures.
It's OK if the full build fails later — we're checking patch application.

- [ ] **Step 2: Test in conda environment (optional)**

**Optional**: Skip if you don't have a local conda environment with a cos7
sysroot. Proceed to Step 3 (CI validation) instead.

If you have the `zig-ppc64le-test` or similar conda environment with the
cos7 sysroot:

```bash
# Clear zig cache
rm -rf ~/.cache/zig/

# Test that zig can link with -lc without libpthread.a errors
conda run -n <test-env> zig build-exe hello.zig -lc -fallow-so-scripts
```

Where `hello.zig` is:
```zig
const std = @import("std");
pub fn main() void {
    std.debug.print("hello\n", .{});
}
```

- [ ] **Step 3: Push to CI and monitor**

```bash
git push origin mnt/v0.15.2_12-fine-tune
```

Monitor the x86_64 (linux-64) build on Azure DevOps. Use the
`/conda-ci-status` skill to check platform status.

Expected outcomes:
- x86_64: `libpthread.so.0` loaded instead of `libpthread.a`, no undefined symbols
- ppc64le: Unaffected (uses GCC linker redirect)
- `copy_file_range`: Resolves to syscall, not glibc symbol

- [ ] **Step 4: Update memory**

After CI results, update `MEMORY.md` with:
- Whether `.so.N` fallback resolved the libpthread issue
- Whether explicit `-target` fixed copy_file_range
- Any new edge cases discovered
