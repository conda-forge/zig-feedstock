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

Zig's linker resolution chain:

1. `load_host_libc` iterates `[-lm, -lpthread, -lc, -ldl, -lrt, -lutil]`
2. For `-lpthread`: tries `crt_dir/libpthread.so`
3. Opens it, gets `BadMagic` (it's text, not ELF), falls into `loadGnuLdScript()`
4. Parses the ld script, resolves relative paths via patch 0006
5. **Resolution fails** (path layout mismatch, symlink vs real directory, etc.)
6. Error propagates back to `load_host_libc`
7. Fallback: tries `crt_dir/libpthread.a` -> **static link** -> undefined symbols

In glibc >= 2.34 (used by cross-compiled ppc64le build host), pthread is
merged into `libc.so.6` and there is no separate `libpthread`, so no issue.

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

#### Site 1: `load_host_libc` (src/link.zig ~line 1402)

After `openLoadDso` fails for `lib<name>.so`, before trying `lib<name>.a`,
iterate the directory for files matching `lib<name>.so.*` and try loading
each as a DSO:

```zig
// Current: .so fails -> try .a
// Proposed: .so fails -> scan for .so.N -> try .a

openLoadDso(base, so_path, query) catch |so_err| {
    // NEW: try versioned shared libraries
    const found_versioned = blk: {
        const dir_sub = fs.path.dirname(so_path.sub_path) orelse ".";
        var dir = so_path.root_dir.handle.openDir(dir_sub, .{ .iterate = true }) catch break :blk false;
        defer dir.close();
        const prefix = std.fmt.allocPrint(gpa, "lib{s}.so.", .{lib_name}) catch break :blk false;
        defer gpa.free(prefix);
        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (mem.startsWith(u8, entry.name, prefix)) {
                const versioned_sub = std.fmt.allocPrint(gpa, "{s}{s}{s}", .{
                    dir_sub, fs.path.sep_str, entry.name,
                }) catch continue;
                const versioned_path: Path = .{
                    .root_dir = so_path.root_dir,
                    .sub_path = versioned_sub,
                };
                openLoadDso(base, versioned_path, query) catch |ver_err| {
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
        openLoadArchive(base, a_path, query) catch |a_err| { ... };
    }
};
```

#### Site 2: `loadGnuLdScript` `-l` handler (extension to patch 0006)

In the `-l<name>` resolution inside `loadGnuLdScript`, after `lib<name>.so`
fails in the script directory, scan for `lib<name>.so.*` before trying
`lib<name>.a`. Same directory iteration pattern as Site 1.

This also prevents infinite recursion: if `libpthread.so` is an ld script
containing `-lpthread`, searching for `libpthread.so` in the same directory
finds the script itself (BadMagic -> ld script -> recurse). The `.so.N`
fallback breaks the cycle by finding the actual ELF shared object.

### Patch B: Explicit target for doctest builds (build script change)

In the langref/doctest build step, pass `-target x86_64-linux-gnu.2.17` so
zig's std lib uses raw syscall wrappers for functions added after glibc 2.17
(like `copy_file_range`).

This is a change to `recipe/build.sh` or `recipe/building/build_native_for_test.sh`,
NOT a zig source patch. When zig knows the target is glibc 2.17, its std lib
automatically uses `SYS_copy_file_range` (syscall 326) instead of calling
glibc's `copy_file_range()`.

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| Multiple `.so.N` files (e.g., `.so.0`, `.so.0.0.0`) | First match used; all are typically symlinks to same target |
| `.so.N` is symlink to missing target | `openLoadDso` returns error, loop continues to next match |
| No `.so.N` files exist | Falls through to `.a` (current behavior preserved) |
| Non-glibc targets | No `.so.N` files in search path, behavior unchanged |
| glibc >= 2.34 (pthread merged into libc) | No `libpthread.so` at all, irrelevant |

## Performance Impact

Directory iteration adds one `opendir` + `readdir` syscall per library that
fails `.so` resolution. For 6 glibc libraries, this is negligible during build.
In practice, only `libpthread` (and possibly `librt`, `libdl`) need the
fallback on glibc 2.17; `libc` and `libm` are handled by `_libc_tuning.sh`
symlink replacement.

## Files Modified

| File | Change |
|------|--------|
| New patch: `0007-elf-linker-versioned-so-fallback.patch` | Sites 1 and 2 in `src/link.zig` |
| `recipe/build.sh` or `recipe/building/build_native_for_test.sh` | Add `-target x86_64-linux-gnu.2.17` to doctest builds |

## Testing

1. Local build with conda-forge cos7 sysroot (glibc 2.17)
2. Verify `libpthread.so.0` is loaded instead of `libpthread.a`
3. Verify `copy_file_range` resolves to syscall, not glibc symbol
4. CI validation on x86_64 (the affected platform)
5. Regression check: ppc64le cross-build still works (should be unaffected)

## Relationship to Existing Patches

- **Patch 0006** (ld script relative paths + `-l` flags): Extended at Site 2 with `.so.N` fallback
- **`_sysroot_fix.sh`**: Unchanged; still converts absolute paths in ld scripts to relative
- **`_libc_tuning.sh`**: Unchanged; still replaces `libc.so`/`libm.so` scripts with symlinks
- **Patch 0003** (ppc64le GCC redirect): Unaffected; ppc64le uses GCC linker, not zig's self-hosted
