#!/usr/bin/env bash
# Test script for zig wrapper validation (Unix)
# Runs during zig_$cross_target_platform_ package tests

_wrapper_dir="${CONDA_PREFIX}/share/zig/wrappers"
_pass=0
_fail=0

_ok()   { echo "  PASS: $1"; _pass=$((_pass + 1)); }
_err()  { echo "  FAIL: $1"; _fail=$((_fail + 1)); }
_test() { if eval "$2" 2>/dev/null; then _ok "$1"; else _err "$1"; fi; }

echo "=== Wrapper Script Validation ==="

# --- 1. Wrapper existence and executability ---
echo "--- Wrapper existence ---"
for w in zig-cc zig-cxx zig-ar zig-ranlib zig-asm zig-rc zig-cxx-shared zig-force-load-cc _zig-cc-common.sh; do
    _test "${w} exists" "[[ -f '${_wrapper_dir}/${w}' ]]"
done
for w in zig-cc zig-cxx zig-ar zig-ranlib zig-asm zig-rc zig-cxx-shared zig-force-load-cc; do
    _test "${w} is executable" "[[ -x '${_wrapper_dir}/${w}' ]]"
done

# --- 2. Flag filtering: -mcpu=* is filtered ---
echo "--- Flag filtering: _zig-cc-common.sh ---"
_common="${_wrapper_dir}/_zig-cc-common.sh"

_test "-mcpu=* in filter list" "grep -q '\-mcpu=\*' '${_common}'"
_test "-march=* in filter list" "grep -q '\-march=\*' '${_common}'"
_test "-mtune=* in filter list" "grep -q '\-mtune=\*' '${_common}'"

# --- 3. Flag filtering: *_list linker flags are filtered ---
echo "--- Flag filtering: Mach-O *_list flags ---"
_test "-exported_symbols_list filtered" "grep -q 'exported_symbols_list' '${_common}'"
_test "-unexported_symbols_list filtered" "grep -q 'unexported_symbols_list' '${_common}'"
_test "-force_symbols_not_weak_list filtered" "grep -q 'force_symbols_not_weak_list' '${_common}'"
_test "-force_symbols_weak_list filtered" "grep -q 'force_symbols_weak_list' '${_common}'"
_test "-reexported_symbols_list filtered" "grep -q 'reexported_symbols_list' '${_common}'"

# --- 4. Flag filtering: -all_load/-force_load are filtered (in common) ---
echo "--- Flag filtering: force-load flags ---"
_test "-Wl,-all_load filtered in common" "grep -q 'all_load' '${_common}'"
_test "-Wl,-force_load filtered in common" "grep -q 'force_load' '${_common}'"

# --- 5. Force-load wrapper content ---
echo "--- Force-load wrapper ---"
_fl="${_wrapper_dir}/zig-force-load-cc"
_test "force-load-cc sources _zig-cc-common.sh" "grep -q '_zig-cc-common.sh' '${_fl}'"
_test "force-load-cc uses ar x" "grep -q 'ar x' '${_fl}'"
_test "force-load-cc creates tmpdir" "grep -q 'mktemp -d' '${_fl}'"
_test "force-load-cc has cleanup trap" "grep -q 'trap.*EXIT' '${_fl}'"
_test "force-load-cc handles -Wl,-force_load,*" "grep -q 'Wl,-force_load' '${_fl}'"
_test "force-load-cc handles -Wl,-all_load" "grep -q 'Wl,-all_load' '${_fl}'"

# --- 6. Exec line has -mcpu=baseline ---
echo "--- Exec line validation ---"
_test "common has -mcpu=baseline in exec args" "grep -q 'mcpu=baseline' '${_common}'"

# --- 7. Activation variables ---
echo "--- Activation variables ---"
_test "ZIG_FORCE_LOAD_CC is set" "[[ -n '${ZIG_FORCE_LOAD_CC:-}' ]]"
_test "ZIG_FORCE_LOAD_CC points to existing file" "[[ -x '${ZIG_FORCE_LOAD_CC:-/nonexistent}' ]]"
_test "ZIG_CXX_SHARED is set" "[[ -n '${ZIG_CXX_SHARED:-}' ]]"
_test "ZIG_CXX_SHARED points to existing file" "[[ -x '${ZIG_CXX_SHARED:-/nonexistent}' ]]"

# --- Summary ---
echo ""
echo "=== Results: ${_pass} passed, ${_fail} failed ==="
[[ ${_fail} -eq 0 ]] || exit 1
