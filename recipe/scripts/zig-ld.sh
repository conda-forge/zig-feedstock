#!/usr/bin/env bash
# Zig linker wrapper — exposes bundled LLD with target selection
# Picks the right LLD variant based on OS (ld.lld for ELF, ld64.lld for Mach-O)
case "$(uname -s)" in
    Darwin) _lld="ld64.lld" ;;
    *)      _lld="ld.lld" ;;
esac
exec "@ZIG_BIN@" "${_lld}" "$@"
