#!/usr/bin/env python3
"""Patch bootstrap zig's posix.zig to use direct syscalls for fstat/fstatat.

When zig cross-compiles with --libc (sysroot), glibc's fstat/fstat64 symbols
may not be resolvable through the libc.so stub for glibc < 2.33 on 64-bit
architectures. The libc_nonshared.a bridge (__fxstat) also may not be linked.

This script reorders the fstat()/fstatatZ() functions to declare var stat
first, then injects a direct Linux syscall path before the libc symbol path,
matching the source patch 0002-linux-glibc-2.17-use-fstat-not-fstat64.patch.
"""

import re
import sys


FSTAT_SYSCALL_BLOCK = '''\
    // On Linux, use direct syscalls for fstat to avoid glibc stub issues.
    // For glibc < 2.33 on 64-bit arches, fstat/fstat64 are not in libc.so
    // stubs, and libc_nonshared.a may not be linked when using --libc sysroot.
    if (native_os == .linux) {
        const rc = blk: {
            if (@hasField(linux.SYS, "fstat64")) {
                break :blk linux.syscall2(.fstat64, @as(usize, @bitCast(@as(isize, fd))), @intFromPtr(&stat));
            } else {
                break :blk linux.syscall2(.fstat, @as(usize, @bitCast(@as(isize, fd))), @intFromPtr(&stat));
            }
        };
        switch (errno(rc)) {
            .SUCCESS => return stat,
            .INVAL => unreachable,
            .BADF => unreachable,
            .NOMEM => return error.SystemResources,
            .ACCES => return error.AccessDenied,
            else => |err| return unexpectedErrno(err),
        }
    }

'''

FSTATAT_SYSCALL_BLOCK = '''\
    // Same syscall bypass as fstat -- see comment above.
    if (native_os == .linux) {
        const rc = blk: {
            if (@hasField(linux.SYS, "fstatat64")) {
                break :blk linux.syscall4(.fstatat64, @as(usize, @bitCast(@as(isize, dirfd))), @intFromPtr(pathname), @intFromPtr(&stat), flags);
            } else if (@hasField(linux.SYS, "newfstatat")) {
                break :blk linux.syscall4(.newfstatat, @as(usize, @bitCast(@as(isize, dirfd))), @intFromPtr(pathname), @intFromPtr(&stat), flags);
            } else {
                break :blk linux.syscall4(.fstatat, @as(usize, @bitCast(@as(isize, dirfd))), @intFromPtr(pathname), @intFromPtr(&stat), flags);
            }
        };
        switch (errno(rc)) {
            .SUCCESS => return stat,
            .INVAL => unreachable,
            .BADF => unreachable,
            .NOMEM => return error.SystemResources,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .NAMETOOLONG => return error.NameTooLong,
            .LOOP => return error.SymLinkLoop,
            .NOENT => return error.FileNotFound,
            .NOTDIR => return error.FileNotFound,
            else => |err| return unexpectedErrno(err),
        }
    }

'''


def patch_file(filepath):
    with open(filepath, 'r') as f:
        content = f.read()

    patched = False

    # Patch fstat: inject syscall block AFTER "var stat = mem.zeroes(Stat);"
    # but BEFORE "const fstat_sym = ..." (and its switch).
    # In the original source the order is:
    #     const fstat_sym = if (lfs64_abi) system.fstat64 else system.fstat;
    #     var stat = mem.zeroes(Stat);
    #     switch (errno(fstat_sym(fd, &stat))) {
    # We reorder to: var stat → syscall block → const fstat_sym → switch
    fstat_old = (
        '    const fstat_sym = if (lfs64_abi) system.fstat64 else system.fstat;\n'
        '    var stat = mem.zeroes(Stat);\n'
        '    switch (errno(fstat_sym(fd, &stat))) {\n'
    )
    fstat_new = (
        '    var stat = mem.zeroes(Stat);\n'
        '\n'
        + FSTAT_SYSCALL_BLOCK
        + '    const fstat_sym = if (lfs64_abi) system.fstat64 else system.fstat;\n'
        '    switch (errno(fstat_sym(fd, &stat))) {\n'
    )
    if fstat_old in content and 'syscall2(.fstat' not in content:
        content = content.replace(fstat_old, fstat_new)
        patched = True
        print(f"  Injected fstat syscall bypass")

    # Patch fstatatZ: same reorder for fstatat
    fstatat_old = (
        '    const fstatat_sym = if (lfs64_abi) system.fstatat64 else system.fstatat;\n'
        '    var stat = mem.zeroes(Stat);\n'
        '    switch (errno(fstatat_sym(dirfd, pathname, &stat, flags))) {\n'
    )
    fstatat_new = (
        '    var stat = mem.zeroes(Stat);\n'
        '\n'
        + FSTATAT_SYSCALL_BLOCK
        + '    const fstatat_sym = if (lfs64_abi) system.fstatat64 else system.fstatat;\n'
        '    switch (errno(fstatat_sym(dirfd, pathname, &stat, flags))) {\n'
    )
    if fstatat_old in content and 'syscall4(.fstatat' not in content:
        content = content.replace(fstatat_old, fstatat_new)
        patched = True
        print(f"  Injected fstatat syscall bypass")

    if patched:
        with open(filepath, 'w') as f:
            f.write(content)
        print(f"  Patched: {filepath}")
    else:
        print(f"  Already patched or marker not found: {filepath}")

    return patched


if __name__ == '__main__':
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <path/to/posix.zig>", file=sys.stderr)
        sys.exit(1)
    patch_file(sys.argv[1])
