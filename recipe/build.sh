#!/usr/bin/env bash

set -euxo pipefail

if [[ "${BUILD_WITH_CMAKE:-0}" == "0" ]]; then
  builder=zig
else
  builder=cmake
fi

case "${target_platform}" in
  linux-64|osx-64|win-64|linux-ppc64le)
    bash "${RECIPE_DIR}"/build_scripts/native-"${builder}-${target_platform}".sh
    ;;
  linux-aarch64|osx-arm64)
    bash "${RECIPE_DIR}"/build_scripts/cross-"${builder}-${target_platform}".sh
    ;;
  *)
    echo "Unsupported target_platform: ${target_platform}"
    exit 1
    ;;
esac
