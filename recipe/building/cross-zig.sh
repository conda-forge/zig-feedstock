#!/bin/bash
# Cross-compiler wrapper: injects -target for commands that support it
# cc/c++ use stripped triplet (clang rejects glibc version suffix)
# zig-native commands use full triplet (zig accepts glibc version)
_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "$1" in
  cc|c++)
    cmd="$1"; shift
    exec "${_self_dir}/@NATIVE_ZIG@" "$cmd" -target @CC_TRIPLET@ "$@"
    ;;
  build-exe|build-lib|build-obj|test|run|translate-c)
    cmd="$1"; shift
    exec "${_self_dir}/@NATIVE_ZIG@" "$cmd" -target @ZIG_TRIPLET@ "$@"
    ;;
  *)
    exec "${_self_dir}/@NATIVE_ZIG@" "$@"
    ;;
esac
