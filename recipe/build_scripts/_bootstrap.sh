function install_bootstrap_zig() {
    local version="${1:-0.15.2}"
    local build_string="${2:-*_7}"
    local spec="zig==${version} ${build_string}"

    echo "=== Installing bootstrap zig via mamba ==="
    echo "  Spec: ${spec}"

    # Use mamba/conda to install zig into BUILD_PREFIX
    if command -v mamba &> /dev/null; then
        mamba install -p "${BUILD_PREFIX}" -y -c conda-forge "${spec}" || {
            echo "ERROR: Failed to install bootstrap zig" >&2
            return 1
        }
    elif command -v conda &> /dev/null; then
        conda install -p "${BUILD_PREFIX}" -y -c conda-forge "${spec}" || {
            echo "ERROR: Failed to install bootstrap zig" >&2
            return 1
        }
    else
        echo "ERROR: Neither mamba nor conda found" >&2
        return 1
    fi

    # Verify installation
    if [[ -x "${BUILD_PREFIX}/bin/zig" ]]; then
        echo "  ✓ Bootstrap zig installed: $(${BUILD_PREFIX}/bin/zig version)"
        export BOOTSTRAP_ZIG="${BUILD_PREFIX}/bin/zig"
    else
        echo "ERROR: zig not found after installation" >&2
        return 1
    fi

    echo "=== Bootstrap zig ready ==="
}
