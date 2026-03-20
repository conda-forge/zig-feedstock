# Zig Linker: Versioned .so.N Fallback for glibc < 2.34

**Date**: 2026-03-19
**Status**: Draft
**Scope**: zig-feedstock-2, patches for zig 0.15.2

## Problem

When zig's self-hosted ELF linker on x86_64 processes glibc 2.17 library
dependencies (via `-lc` which triggers implicit `-lpthread`, `-lm`, etc.),
it resolves `libpthread` to the **static archive** (`libpthread.a`) instead
of the **shared library** (`libpthread.so.0`). This causes a flood of
undefined symbols from glibc/ld.so internals (`_dl_*`, `__libc_*`,
`_Unwind_*`) that are only available at runtime via `ld.so`.

A secondary issue: zig's own `os.linux.wrapped.copy_file_range` references
the glibc `copy_file_range` symbol (added in glibc 2.27), which doesn't
exist in glibc 2.17.

### Why this happens

In glibc < 2.34, `libpthread` was a **separate library** from `libc`. The
file `libpthread.so` is a GNU ld script:

```
OUTPUT_FORMAT(elf64-x86-64)
GROUP ( /lib64/libpthread.so.0 /usr/lib64/libpthread_nonshared.a )
```

After conda-forge's `sysroot_fix.sh` rewrites absolute paths to relative:

```
OUTPUT_FORMAT(elf64-x86-64)
GROUP ( ../../lib64/libpthread.so.0 ../lib64/libpthread_nonshared.a )
```

### Error propagation chain

Zig's linker resolution for `-lpthread`:

1. `load_host_libc` iterates `[-lm, -lpthread, -lc, -ldl, -lrt, -lutil]`
2. For `-lpthread`: calls `openLoadDso(crt_dir/libpthread.so, query)`
3. `openLoadDso` opens the file successfully, `loadInput` returns `BadMagic`
4. Falls into `try loadGnuLdScript(base, path, query, file)`
5. `loadGnuLdScript` parses the ld script, resolves relative paths via
   patch 0006. Two failure scenarios:
   - **GROUP format**: `GROUP ( ../../lib64/libpthread.so.0 ... )` — relative
     path resolution via `fs.path.resolvePosix` may fail if the sysroot
     directory layout doesn't match (symlink vs real directory). The inner
     `openLoadDso` for the resolved path returns `FileNotFound`, which
     propagates through `try loadGnuLdScript(...)` back through the outer
     `openLoadDso` to `load_host_libc`.
   - **INPUT format**: `INPUT ( -lpthread )` — patch 0006's `-l` handler
     searches for `libpthread.so` in the script's directory, finds the
     **same ld script** → `openLoadDso` → `BadMagic` → `loadGnuLdScript`
     → **infinite recursion**. If/when recursion fails, falls back to
     `libpthread.a` in the same directory.
6. Back in `load_host_libc`: `openLoadDso` catch block matches
   `error.FileNotFound` → tries `crt_dir/libpthread.a` → static link →
   undefined `_dl_*` symbols.

**Key insight**: The `.a` fallback in `load_host_libc` catches
`error.FileNotFound`, which CAN be triggered by failures inside
`loadGnuLdScript` (inner file-not-found errors propagate via `try`).

### Affected platforms

- x86_64 native builds (conda-forge cos7 sysroot with glibc 2.17)
- NOT ppc64le cross-builds (build host has glibc 2.34)

## Solution

### Patch A: Versioned `.so.N` fallback in library resolution

Add a fallback step between `.so` (ld script) failure and `.a` (static
archive): scan the directory for versioned shared libraries (`lib<name>.so.*`).

**Current chain:**
```
libpthread.so -> [ld script fails] -> libpthread.a (BOOM)
```

**Proposed chain:**
```
libpthread.so -> [ld script fails] -> libpthread.so.0 (real ELF) -> libpthread.a
```

#### Primary fix site: `loadGnuLdScript` `-l` handler (patch 0006 extension)

The `-l<name>` handler in `loadGnuLdScript` (patch 0006) currently searches
for `lib<name>.so` then `lib<name>.a` **only in the script's directory**.
This is where the `.so.N` fallback has the most impact:

```zig
// CURRENT (patch 0006):
//   -lpthread → libpthread.so (finds same ld script → recursion) → libpthread.a
//
// PROPOSED:
//   -lpthread → libpthread.so (recursion/fail) → libpthread.so.N (real ELF) → libpthread.a

if (mem.startsWith(u8, arg.path, "-l")) {
    const lib_name = arg.path[2..];
    const script_dir = fs.path.dirname(path.sub_path) orelse "";
    const sep: []const u8 = if (script_dir.len > 0) fs.path.sep_str else "";

    // 1. Try lib<name>.so (current behavior)
    const so_sub = try std.fmt.allocPrint(gpa, "{s}{s}lib{s}.so", .{ script_dir, sep, lib_name });
    const so_path: Path = .{ .root_dir = path.root_dir, .sub_path = so_sub };
    openLoadDso(base, so_path, query) catch |err| switch (err) {
        error.FileNotFound => {
            gpa.free(so_sub);

            // 2. NEW: Try versioned lib<name>.so.N
            const found_versioned = blk: {
                const dir_sub = if (script_dir.len > 0) script_dir else ".";
                var dir = path.root_dir.handle.openDir(dir_sub, .{ .iterate = true }) catch break :blk false;
                defer dir.close();
                // Prefix includes trailing dot to match "libpthread.so." not "libpthread.so"
                const prefix = std.fmt.allocPrint(gpa, "lib{s}.so.", .{lib_name}) catch break :blk false;
                defer gpa.free(prefix);
                var iter = dir.iterate();
                while (iter.next() catch null) |entry| {
                    if (mem.startsWith(u8, entry.name, prefix)) {
                        // allocPrint for the path string; ownership transfers to the
                        // linker's Input.Dso.path on success — do NOT free on success.
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
                        break :blk true;  // versioned_sub ownership transferred to linker
                    }
                }
                break :blk false;
            };

            if (!found_versioned) {
                // 3. Last resort: static archive (current fallback)
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

**Memory ownership**: When `openLoadDso` succeeds, the `versioned_sub`
string is stored in `Input.Dso.path.sub_path` and lives for the duration
of the link. It must NOT be freed on the success path. On failure,
`gpa.free(versioned_sub)` is called before `continue`.

**Recursion prevention**: When `-lpthread` resolves to `libpthread.so`
(the same ld script), `openLoadDso` → `BadMagic` → `loadGnuLdScript` →
finds `-lpthread` again → recurses. With the `.so.N` fallback, after the
`.so` attempt fails (recursion error or FileNotFound), the directory scan
finds `libpthread.so.0` (a real ELF shared object), breaking the cycle.

#### Secondary fix site: `load_host_libc` (defense-in-depth)

Same `.so.N` directory scan pattern between `.so` and `.a` in
`load_host_libc`. This catches cases where the ld script GROUP entries
fail to resolve (inner `FileNotFound` propagates back).

**Variable note**: In `load_host_libc`, the path variable is `dso_path`
(not `so_path`), and `root_dir` is `Cache.Directory.cwd()` with
`sub_path` being an absolute path string. The directory iteration uses
`fs.cwd().openDir(dirname, .{.iterate = true})` since the paths are
absolute in this context (unlike `loadGnuLdScript` where paths are
relative to `root_dir`).

This site is lower priority — the primary fix at `loadGnuLdScript`
should resolve most cases. Implement only if testing shows the primary
fix is insufficient.

### Patch B: Explicit target for doctest builds (build script change)

In the langref/doctest build step, pass `-target x86_64-linux-gnu.2.17` so
zig's std lib uses raw syscall wrappers for functions added after glibc 2.17
(like `copy_file_range`). This is a zig-specific triple format (not
gcc-style) where `.2.17` specifies the minimum glibc version.

This is a change to `recipe/build.sh` or `recipe/building/build_native_for_test.sh`,
NOT a zig source patch. When zig knows the target is glibc 2.17, its std lib
automatically uses `SYS_copy_file_range` (syscall 326) instead of calling
glibc's `copy_file_range()`.

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| Multiple `.so.N` files (e.g., `.so.0`, `.so.0.0.0`) | First directory iteration match used; all are typically symlinks to same target |
| `.so.N` is symlink to missing target | `openLoadDso` returns error, loop continues to next match |
| No `.so.N` files exist | Falls through to `.a` (current behavior preserved) |
| Non-glibc targets | No `.so.N` files in search path, behavior unchanged |
| glibc >= 2.34 (pthread merged into libc) | No separate `libpthread.so`, irrelevant |
| `-lpthread` in ld script finds same `.so` script | `.so` attempt recurses/fails, `.so.N` scan breaks the cycle |

## Performance Impact

Directory iteration adds one `opendir` + `readdir` syscall per library that
fails `.so` resolution. For 6 glibc libraries, this is negligible during build.
In practice, only `libpthread` (and possibly `librt`, `libdl`) need the
fallback on glibc 2.17; `libc` and `libm` are handled by `_libc_tuning.sh`
symlink replacement.

## Files Modified

| File | Change |
|------|--------|
| Updated patch: `0006-elf-linker-handle-relative-paths-and-l-flags-in-ld-scripts.patch` | Add `.so.N` fallback to `-l` handler in `loadGnuLdScript` |
| Optional new patch: `0007-elf-linker-versioned-so-fallback-load-host-libc.patch` | Defense-in-depth `.so.N` fallback in `load_host_libc` (if needed) |
| `recipe/build.sh` or `recipe/building/build_native_for_test.sh` | Add `-target x86_64-linux-gnu.2.17` to doctest builds |

## Testing

1. Local build with conda-forge cos7 sysroot (glibc 2.17)
2. Verify `libpthread.so.0` is loaded instead of `libpthread.a`
3. Verify `copy_file_range` resolves to syscall, not glibc symbol
4. CI validation on x86_64 (the affected platform)
5. Regression check: ppc64le cross-build still works (should be unaffected)

## Relationship to Existing Patches

- **Patch 0006** (ld script relative paths + `-l` flags): Extended with `.so.N` fallback in `-l` handler
- **`_sysroot_fix.sh`**: Unchanged; still converts absolute paths in ld scripts to relative
- **`_libc_tuning.sh`**: Unchanged; still replaces `libc.so`/`libm.so` scripts with symlinks
- **Patch 0003** (ppc64le GCC redirect): Unaffected; ppc64le uses GCC linker, not zig's self-hosted
