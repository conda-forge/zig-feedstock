# Sourced by all ten installed unix wrappers to ensure ZIG_GLOBAL_CACHE_DIR is set.

# --- Ensure zig can resolve its cache directory ---
# zig's global cache resolves as: ZIG_GLOBAL_CACHE_DIR (explicit) >
# std.fs.getAppDataDir("zig")/zig-cache, where getAppDataDir on Linux checks
# XDG_DATA_HOME then HOME/.local/share.  If neither is set, zig panics with
# AppDataDirUnavailable.  Always set ZIG_GLOBAL_CACHE_DIR if unset, mirroring
# zig's own resolution so the variable is always populated before exec.
if [[ -z "${ZIG_GLOBAL_CACHE_DIR:-}" ]]; then
    if [[ -n "${XDG_DATA_HOME:-}" ]]; then
        export ZIG_GLOBAL_CACHE_DIR="${XDG_DATA_HOME}/zig/zig-cache"
    elif [[ -n "${HOME:-}" ]]; then
        export ZIG_GLOBAL_CACHE_DIR="${HOME}/.local/share/zig/zig-cache"
    else
        export ZIG_GLOBAL_CACHE_DIR="${TMPDIR:-/tmp}/zig-cache-$(id -u 2>/dev/null || echo 0)"
    fi
fi
