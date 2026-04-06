#!/usr/bin/env bash
# Zig bundled LLD wrapper — exposes LLVM's LLD (NOT zig's self-hosted linker)
# Picks the right LLD variant based on OS (ld.lld for ELF, ld64.lld for Mach-O)
case "$(uname -s)" in
    Darwin) _lld="ld64.lld" ;;
    *)      _lld="ld.lld" ;;
esac
exec "@ZIG_BIN@" "${_lld}" "$@"
