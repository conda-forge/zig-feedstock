#!/usr/bin/env bash

# Component dispatcher for the zig_impl_* output.
#
# Deliberately a SEPARATE file from build.sh rather than a rename of it.
# recipe/build.sh keeps its path and identity so that upstream/main changes to
# the zig build keep 3-way merging against it; this dispatcher is purely
# additive, so adding or reordering components never touches a shared file.
#
# Each non-zig component lives at recipe/<component>/build.sh and is run as a
# separate bash process. Components do NOT rely on variable inheritance from
# each other -- build.sh re-derives LLVM_BUILD rather than importing it (see
# recipe/zig-llvm/building/_env.sh).

set -uo pipefail
IFS=$'\n\t'

# Consumed by recipe/zig-llvm/build.sh and by build.sh's llvm-config discovery.
export LLVM_RECIPE_DIR="${RECIPE_DIR}/zig-llvm"

# Override from recipe.yaml's env: block to add, drop or reorder components.
: "${ZIG_BUILD_COMPONENTS:=zig-llvm zig}"

for _component in ${ZIG_BUILD_COMPONENTS}; do
  case "${_component}" in
    zig) _script="${RECIPE_DIR}/build.sh" ;;
    *)   _script="${RECIPE_DIR}/${_component}/build.sh" ;;
  esac
  if [[ ! -f "${_script}" ]]; then
    echo "ERROR: component '${_component}' has no build script at ${_script}" >&2
    exit 1
  fi
  echo "=== component: ${_component} -> ${_script} ==="
  bash "${_script}" || exit 1
done
unset _component _script
