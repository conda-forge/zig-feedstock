#!/bin/bash
# Cross-compiler wrapper: injects -target for commands that support it
# cc/c++ use stripped triplet (clang rejects glibc version suffix)
# zig-native commands use full triplet (zig accepts glibc version)
native_zig=""
for _p in "$PREFIX" "$CONDA_PREFIX"; do
  if [ -n "$_p" ] && [ -x "$_p/bin/@NATIVE_ZIG@" ]; then
    native_zig="$_p/bin/@NATIVE_ZIG@"
    break
  fi
done
if [ -z "$native_zig" ]; then
  echo "cross-zig.sh: @NATIVE_ZIG@ not found under PREFIX=$PREFIX or CONDA_PREFIX=$CONDA_PREFIX" >&2
  exit 127
fi
case "$1" in
  cc|c++)
    cmd="$1"; shift
    exec "$native_zig" "$cmd" -target @CC_TRIPLET@ "$@"
    ;;
  build-exe|build-lib|build-obj|test|run|translate-c)
    cmd="$1"; shift
    exec "$native_zig" "$cmd" -target @ZIG_TRIPLET@ "$@"
    ;;
  *)
    exec "$native_zig" "$@"
    ;;
esac
