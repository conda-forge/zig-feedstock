#!/bin/bash
# Fix absolute build-tree paths in NEEDED entries of libc++ cache libraries
# This script uses patchelf to normalize references to bare sonames

set -euo pipefail

CACHE="/home/memento/PycharmProjects/Staged-Recipes/staged-recipes/recipes/zig-llvm/cache/lib"
BUILD_TREE_PATH="/home/memento/PycharmProjects/Staged-Recipes/staged-recipes/output/bld/rattler-build_zig-llvm_1772229480/work/conda-llvm-build/lib"

# Check that patchelf is available
if ! command -v patchelf &> /dev/null; then
    echo "ERROR: patchelf not found. Install it with: conda install patchelf"
    exit 1
fi

# Check that cache directory exists
if [[ ! -d "$CACHE" ]]; then
    echo "ERROR: Cache directory not found: $CACHE"
    exit 1
fi

echo "=== Fixing absolute NEEDED paths in libc++ cache libraries ==="
echo "Cache directory: $CACHE"
echo ""

# Fix libc++.so.1.0
LIBCXX="$CACHE/libc++.so.1.0"
if [[ ! -f "$LIBCXX" ]]; then
    echo "ERROR: $LIBCXX not found"
    exit 1
fi

echo "Processing: libc++.so.1.0"
echo "BEFORE:"
readelf -d "$LIBCXX" 2>/dev/null | grep NEEDED || echo "  (no NEEDED entries)"
echo ""

# Replace libc++abi.so.1.0 absolute path
echo "  Fixing libc++abi.so.1.0 reference..."
if patchelf --replace-needed \
    "${BUILD_TREE_PATH}/libc++abi.so.1.0" \
    "libc++abi.so.1.0" \
    "$LIBCXX"; then
    echo "    SUCCESS"
else
    echo "    FAILED"
    exit 1
fi

# Replace libunwind.so.1.0 absolute path
echo "  Fixing libunwind.so.1.0 reference..."
if patchelf --replace-needed \
    "${BUILD_TREE_PATH}/libunwind.so.1.0" \
    "libunwind.so.1.0" \
    "$LIBCXX"; then
    echo "    SUCCESS"
else
    echo "    FAILED"
    exit 1
fi

echo "AFTER:"
readelf -d "$LIBCXX" 2>/dev/null | grep NEEDED || echo "  (no NEEDED entries)"
echo ""

# Fix libc++abi.so.1.0
LIBCXXABI="$CACHE/libc++abi.so.1.0"
if [[ ! -f "$LIBCXXABI" ]]; then
    echo "ERROR: $LIBCXXABI not found"
    exit 1
fi

echo "Processing: libc++abi.so.1.0"
echo "BEFORE:"
readelf -d "$LIBCXXABI" 2>/dev/null | grep NEEDED || echo "  (no NEEDED entries)"
echo ""

# Replace libunwind.so.1.0 absolute path
echo "  Fixing libunwind.so.1.0 reference..."
if patchelf --replace-needed \
    "${BUILD_TREE_PATH}/libunwind.so.1.0" \
    "libunwind.so.1.0" \
    "$LIBCXXABI"; then
    echo "    SUCCESS"
else
    echo "    FAILED"
    exit 1
fi

echo "AFTER:"
readelf -d "$LIBCXXABI" 2>/dev/null | grep NEEDED || echo "  (no NEEDED entries)"
echo ""

echo "=== Fix complete ==="
echo ""
echo "Verification complete. All absolute NEEDED paths have been converted to bare sonames."
