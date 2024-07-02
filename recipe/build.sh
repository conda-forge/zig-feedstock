#!/usr/bin/env bash

set -euxo pipefail

case "${target_platform}" in
  linux-64)
    bash "${RECIPE_DIR}"/build_scripts/build-native-zig-linux-64.sh
    ;;
  osx-64)
    bash "${RECIPE_DIR}"/build_scripts/build-native-zig-osx-64.sh
    ;;
  linux-aarch64)
    bash "${RECIPE_DIR}"/build_scripts/build-cross-zig-linux-aarch64.sh
    ;;
  osx-arm64)
    export npm_config_arch="arm64"
    ;;
  *)
    echo "Unsupported target_platform: ${target_platform}"
    exit 1
    ;;
esac
