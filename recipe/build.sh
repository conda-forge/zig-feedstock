#!/usr/bin/env bash

set -euxo pipefail

if [[ "${BUILD_WITH_CMAKE:-0}" == "0" ]]; then
  builder=zig
else
  builder=cmake
fi

case "${target_platform}" in
  linux-64)
    bash "${RECIPE_DIR}"/build_scripts/native-"${builder}"-linux-64.sh
    ;;
  osx-64)
    bash "${RECIPE_DIR}"/build_scripts/native-"${builder}"-osx-64.sh
    ;;
  linux-aarch64)
    bash "${RECIPE_DIR}"/build_scripts/cross-"${builder}"-linux-aarch64.sh
    ;;
  linux-ppc64le)
    bash "${RECIPE_DIR}"/build_scripts/cross-"${builder}"-linux-ppc64le.sh
    ;;
  osx-arm64)
    bash "${RECIPE_DIR}"/build_scripts/cross-"${builder}"-osx-arm64.sh
    ;;
  *)
    echo "Unsupported target_platform: ${target_platform}"
    exit 1
    ;;
esac
