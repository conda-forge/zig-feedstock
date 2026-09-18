# Post-install layout: renames the zig binary to <CONDA_TRIPLET>-zig, relocates
# artifacts under Library/ on non-unix, generates mingw import libs, and lowercases
# the bundled LICENSE.TXT files.
# Requires: PREFIX, CONDA_TRIPLET, SRC_DIR, RECIPE_DIR.

dbg echo "Post-install implementation package: ${PKG_NAME}"
mv "${PREFIX}"/bin/zig "${PREFIX}"/bin/"${CONDA_TRIPLET}"-zig

# Non-unix conda convention: artifacts go under Library/
if is_not_unix; then
  dbg echo "Relocating to Library/ for non-unix conda convention"
  mkdir -p "${PREFIX}/Library/bin" "${PREFIX}/Library/lib" "${PREFIX}/Library/doc"
  mv "${PREFIX}"/bin/"${CONDA_TRIPLET}"-zig "${PREFIX}"/Library/bin/"${CONDA_TRIPLET}"-zig
  mv "${PREFIX}"/lib/zig "${PREFIX}"/Library/lib/zig
  [[ -d "${PREFIX}/doc" ]] && mv "${PREFIX}"/doc/* "${PREFIX}"/Library/doc/
fi

source "${RECIPE_DIR}/building/_mingw.sh"
generate_mingw_import_libs

# rattler-build lints mixed .txt/.TXT in info/licenses; two-step mv also works
# on the case-insensitive filesystems of the osx and win lanes.
for _lic_dir in libcxx libcxxabi libunwind; do
  _lic="${SRC_DIR}/zig-source/lib/${_lic_dir}/LICENSE.TXT"
  [[ -f "${_lic}" ]] || continue
  mv "${_lic}" "${_lic}.tmp" && mv "${_lic}.tmp" "${_lic%.TXT}.txt" \
    || echo "WARNING: could not lowercase ${_lic}" >&2
done
unset _lic_dir _lic
