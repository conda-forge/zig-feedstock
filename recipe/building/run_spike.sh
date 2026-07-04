#!/usr/bin/env bash
# Spike runner: zig vs mingw Win64 stack-probe / TLS repro. Linux host + wine64.
#   bash run_spike.sh [depth]          (default depth 100000)
# Env overrides:
#   ZIG=...     zig compiler (upstream `zig`, or the conda x86_64-...-zig-cc wrapper)
#   MINGW=...   mingw gcc (default x86_64-w64-mingw32-gcc)
#   WINE=...    wine runner (default wine64; try `wine` if wine64 is absent)
set -u
SRC=repro.c
DEPTH="${1:-100000}"
ZIG="${ZIG:-zig}"
MINGW="${MINGW:-x86_64-w64-mingw32-gcc}"
WINE="${WINE:-wine64}"

echo "== build: zig (default reserve) =="
"$ZIG" cc -target x86_64-windows-gnu -O2 "$SRC" -o repro_zig.exe || exit 1

echo "== build: zig (/STACK:0x4000000 -> tests item 6; raw lld-link syntax) =="
"$ZIG" cc -target x86_64-windows-gnu -O2 -Wl,/STACK:0x4000000 "$SRC" -o repro_zig_bigstack.exe || exit 1

echo "== build: mingw (no-crash oracle) =="
"$MINGW" -O2 "$SRC" -o repro_gcc.exe || exit 1

echo "== SizeOfStackReserve (item 6 confound) =="
for e in repro_zig.exe repro_zig_bigstack.exe repro_gcc.exe; do
  printf '  %s: ' "$e"
  llvm-readobj --file-headers "$e" 2>/dev/null | grep -i SizeOfStackReserve || echo '(llvm-readobj unavailable)'
done

echo "== __chkstk references (item 4) =="
for e in repro_zig.exe repro_gcc.exe; do
  printf '  %s chkstk hits: ' "$e"
  llvm-objdump -d "$e" 2>/dev/null | grep -ci chkstk || echo '?'
done

echo "== run under $WINE (depth=$DEPTH) =="
for e in repro_zig.exe repro_zig_bigstack.exe repro_gcc.exe; do
  echo "--- $e ---"
  "$WINE" "$e" "$DEPTH"
  echo "  exit=$?"
done

echo "== prolog diff (Step 4): inspect recurse() in zig.s vs gcc.s =="
"$ZIG" cc -target x86_64-windows-gnu -O2 -S "$SRC" -o zig.s
"$MINGW" -O2 -S "$SRC" -o gcc.s
echo "  wrote zig.s / gcc.s -- compare recurse prolog: sub rsp size, __chkstk call, TLS reload count"
