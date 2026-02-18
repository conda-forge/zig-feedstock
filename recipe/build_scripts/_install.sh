# Installation functions for zig compiler packages
#
# This file contains functions to handle installation of zig compilers in various build modes:
# - Native compilers: Direct installation of zig binary and stdlib
# - Cross-compilers: Installation with triplet-prefixed wrappers for cross-compilation
# - Implementation packages: Minimal installation (binary + stdlib, no wrappers/activation)
#
# The dispatcher function install_zig_compiler() routes to the appropriate installation
# strategy based on BUILD_MODE (native, cross-compiler, cross-target) and PKG_VARIANT.

# === Build Mode Detection ===
# Determines build mode based on TG_, target_platform, and cross-compilation flag
#
# Build modes:
#   native:         TG_ == target_platform == build_platform
#   cross-compiler: TG_ != target_platform (building cross-compiler)
#   cross-target:   TG_ == target_platform but CONDA_BUILD_CROSS_COMPILATION=1
#
# Returns: Sets BUILD_MODE, IS_CROSS_* variables
# Note: ZIG_TARGET is provided by recipe.yaml - no mapping needed here
detect_build_mode() {
    local tg="${TG_:-${target_platform}}"

    # Build mode detection
    if [[ "${tg}" != "${target_platform}" ]]; then
        BUILD_MODE="cross-compiler"
        IS_CROSS_COMPILER=1
        IS_CROSS_TARGET=0
        IS_NATIVE=0
    elif [[ "${CONDA_BUILD_CROSS_COMPILATION:-0}" == "1" ]]; then
        BUILD_MODE="cross-target"
        IS_CROSS_COMPILER=0
        IS_CROSS_TARGET=1
        IS_NATIVE=0
    else
        BUILD_MODE="native"
        IS_CROSS_COMPILER=0
        IS_CROSS_TARGET=0
        IS_NATIVE=1
    fi

    export BUILD_MODE IS_CROSS_COMPILER IS_CROSS_TARGET IS_NATIVE

    echo "=== Build Mode Detection ==="
    echo "TG_:             ${tg}"
    echo "target_platform: ${target_platform}"
    echo "build_platform:  ${build_platform:-unknown}"
    echo "BUILD_MODE:      ${BUILD_MODE}"
    echo "ZIG_TARGET:      ${ZIG_TARGET:-not set}"
    echo "============================"
}

# === Derive Zig Target from Conda Triplet ===
# Converts CONDA_TOOLCHAIN_HOST to zig -target format
# For Linux: removes '-conda-' (e.g., aarch64-conda-linux-gnu → aarch64-linux-gnu)
# For macOS/Windows: explicit mapping (different naming conventions)
derive_zig_target() {
    local conda_triplet="$1"

    case "${conda_triplet}" in
        # macOS: darwin → macos-none, arm64 → aarch64
        x86_64-conda-darwin)
            echo "x86_64-macos-none" ;;
        arm64-conda-darwin)
            echo "aarch64-macos-none" ;;
        # Windows: w64-mingw32 → windows-gnu
        x86_64-conda-w64-mingw32)
            echo "x86_64-windows-gnu" ;;
        # Linux and future archs: just remove '-conda-'
        *)
            echo "${conda_triplet//-conda-/-}" ;;
    esac
}

# === Install Activation Scripts ===
# Installs conda activation/deactivation scripts with placeholder substitution
install_activation_scripts() {
    local prefix="$1"
    local target_triplet="${2:-}"  # Empty for native builds

    # Create directories
    mkdir -p "${prefix}/etc/conda/activate.d"
    mkdir -p "${prefix}/etc/conda/deactivate.d"

    # Determine compiler basenames
    local cc_basename=$(basename "${CC:-cc}")
    local cxx_basename=$(basename "${CXX:-c++}")
    local ar_basename=$(basename "${AR:-ar}")
    local ld_basename=$(basename "${LD:-ld}")

    # Process and install activation script
    sed -e "s|@CC@|${cc_basename}|g" \
        -e "s|@CXX@|${cxx_basename}|g" \
        -e "s|@AR@|${ar_basename}|g" \
        -e "s|@LD@|${ld_basename}|g" \
        -e "s|@CROSS_TARGET_TRIPLET@|${target_triplet}|g" \
        "${RECIPE_DIR}/scripts/activate.sh" \
        > "${prefix}/etc/conda/activate.d/zig_activate.sh"

    # Process and install deactivation script
    cp "${RECIPE_DIR}/scripts/deactivate.sh" \
       "${prefix}/etc/conda/deactivate.d/zig_deactivate.sh"

    # Make executable
    chmod +x "${prefix}/etc/conda/activate.d/zig_activate.sh"
    chmod +x "${prefix}/etc/conda/deactivate.d/zig_deactivate.sh"

    # Windows scripts (if applicable)
    if [[ "${target_platform}" == win-* ]]; then
        sed -e "s|@CC@|${cc_basename}|g" \
            -e "s|@CXX@|${cxx_basename}|g" \
            -e "s|@AR@|${ar_basename}|g" \
            -e "s|@LD@|${ld_basename}|g" \
            "${RECIPE_DIR}/scripts/activate.bat" \
            > "${prefix}/etc/conda/activate.d/zig_activate.bat"

        cp "${RECIPE_DIR}/scripts/deactivate.bat" \
           "${prefix}/etc/conda/deactivate.d/zig_deactivate.bat"
    fi

    echo "Activation scripts installed to ${prefix}/etc/conda/"
}

# === Install Wrapper Scripts ===
# Installs toolchain wrapper scripts (conda-zig-cc, etc.)
install_wrapper_scripts() {
    local prefix="$1"

    mkdir -p "${prefix}/bin"

    for wrapper in "${RECIPE_DIR}"/scripts/wrappers/conda-zig-*; do
        if [[ -f "${wrapper}" ]]; then
            local basename=$(basename "${wrapper}")
            cp "${wrapper}" "${prefix}/bin/${basename}"
            chmod +x "${prefix}/bin/${basename}"
        fi
    done

    echo "Wrapper scripts installed to ${prefix}/bin/"
}

# === Generate Triplet-Prefixed Wrappers ===
# Creates native triplet wrappers that forward to unprefixed zig binary
# Used by native packages to provide consistent naming across platforms
generate_native_triplet_wrappers() {
    local prefix="$1"
    local conda_triplet="$2"  # e.g., x86_64-conda-linux-gnu

    mkdir -p "${prefix}/bin"

    # Main triplet wrapper → unprefixed zig
    cat > "${prefix}/bin/${conda_triplet}-zig" << 'EOF'
#!/usr/bin/env bash
exec "${CONDA_PREFIX}/bin/zig" "$@"
EOF
    chmod +x "${prefix}/bin/${conda_triplet}-zig"

    # Tool wrappers (cc, c++, ar)
    for tool in cc c++ ar; do
        cat > "${prefix}/bin/${conda_triplet}-zig-${tool}" << EOF
#!/usr/bin/env bash
exec "\${CONDA_PREFIX}/bin/zig" ${tool} "\$@"
EOF
        chmod +x "${prefix}/bin/${conda_triplet}-zig-${tool}"
    done

    echo "Native triplet wrappers installed: ${conda_triplet}-zig[-cc|-c++|-ar]"
}

# === Generate Cross-Compiler Wrappers ===
# Creates cross-compiler wrappers with target triplet prefix
# These invoke the native zig with -target flag
generate_cross_wrappers() {
    local prefix="$1"
    local native_triplet="$2"   # e.g., x86_64-conda-linux-gnu (runs on build host)
    local target_triplet="$3"   # e.g., aarch64-conda-linux-gnu (target platform)
    local zig_target="$4"       # e.g., aarch64-linux-gnu (zig -target arg)

    mkdir -p "${prefix}/bin"

    # Main cross-compiler wrapper: target-zig → native-zig -target <target>
    cat > "${prefix}/bin/${target_triplet}-zig" << EOF
#!/usr/bin/env bash
exec "\${CONDA_PREFIX}/bin/${native_triplet}-zig" -target ${zig_target} "\$@"
EOF
    chmod +x "${prefix}/bin/${target_triplet}-zig"

    # Tool wrappers (cc, c++, ar)
    for tool in cc c++ ar; do
        cat > "${prefix}/bin/${target_triplet}-zig-${tool}" << EOF
#!/usr/bin/env bash
exec "\${CONDA_PREFIX}/bin/${native_triplet}-zig" ${tool} -target ${zig_target} "\$@"
EOF
        chmod +x "${prefix}/bin/${target_triplet}-zig-${tool}"
    done

    echo "Cross-compiler wrappers installed: ${target_triplet}-zig[-cc|-c++|-ar]"
    echo "  → Forward to ${native_triplet}-zig with -target ${zig_target}"
}

# CROSS-COMPILER INSTALLATION

# === Install Cross-Compiler ===
# Installs zig as a cross-compiler using conda-style triplet wrappers
#
# Cross-compiler layout (e.g., zig_linux-aarch64 on linux-64):
#   $PREFIX/bin/x86_64-conda-linux-gnu-zig         # Native binary (runs on host)
#   $PREFIX/bin/x86_64-conda-linux-gnu-zig-cc      # Native tool wrapper
#   $PREFIX/bin/aarch64-conda-linux-gnu-zig        # Cross wrapper → native -target
#   $PREFIX/bin/aarch64-conda-linux-gnu-zig-cc     # Cross tool wrapper
#   $PREFIX/lib/zig/                               # Standard library (universal)
#
install_cross_compiler() {
    local source_dir="$1"
    local prefix="$2"

    echo "=== Installing Cross-Compiler ==="
    echo "Build host:     ${target_platform}"
    echo "Target (TG_):   ${TG_}"

    # Use environment variables set by conda build:
    #   CONDA_TOOLCHAIN_BUILD - native triplet (where build runs)
    #   CONDA_TOOLCHAIN_HOST  - target triplet (where binary runs)
    #   ZIG_TARGET            - zig -target argument (from recipe.yaml script env)
    local native_triplet="${CONDA_TOOLCHAIN_BUILD}"
    local target_triplet="${CONDA_TOOLCHAIN_HOST}"
    local zig_target="${ZIG_TARGET:-$(derive_zig_target "${target_triplet}")}"

    echo "Native triplet: ${native_triplet}"
    echo "Target triplet: ${target_triplet}"
    echo "Zig target:     ${zig_target}"

    # Install native zig binary (runs on build host)
    mkdir -p "${prefix}/bin"
    if [[ -f "${source_dir}/zig" ]]; then
        cp "${source_dir}/zig" "${prefix}/bin/${native_triplet}-zig"
    elif [[ -f "${source_dir}/bin/zig" ]]; then
        cp "${source_dir}/bin/zig" "${prefix}/bin/${native_triplet}-zig"
    else
        echo "ERROR: Cannot find zig binary in ${source_dir}"
        return 1
    fi
    chmod +x "${prefix}/bin/${native_triplet}-zig"

    # Create native tool wrappers
    for tool in cc c++ ar; do
        cat > "${prefix}/bin/${native_triplet}-zig-${tool}" << EOF
#!/usr/bin/env bash
exec "\${CONDA_PREFIX}/bin/${native_triplet}-zig" ${tool} "\$@"
EOF
        chmod +x "${prefix}/bin/${native_triplet}-zig-${tool}"
    done

    # Install standard library (universal across targets)
    mkdir -p "${prefix}/lib"
    if [[ -d "${source_dir}/lib/zig" ]]; then
        cp -r "${source_dir}/lib/zig" "${prefix}/lib/"
    elif [[ -d "${source_dir}/lib" ]]; then
        mkdir -p "${prefix}/lib/zig"
        cp -r "${source_dir}/lib/"* "${prefix}/lib/zig/"
    fi

    # Generate cross-compiler wrappers
    generate_cross_wrappers "${prefix}" "${native_triplet}" "${target_triplet}" "${zig_target}"

    echo "Cross-compiler installed:"
    echo "  Native:   ${prefix}/bin/${native_triplet}-zig"
    echo "  Cross:    ${prefix}/bin/${target_triplet}-zig"
    echo "  Wrappers: ${prefix}/bin/${target_triplet}-zig-{cc,c++,ar}"
    echo "  Stdlib:   ${prefix}/lib/zig/"
}

# === Install Native Compiler ===
# Installs zig as a native compiler with standard layout and triplet wrappers
#
# Layout:
#   $PREFIX/bin/zig                              # Unprefixed (convenience)
#   $PREFIX/bin/x86_64-conda-linux-gnu-zig       # Triplet-prefixed wrapper
#   $PREFIX/bin/x86_64-conda-linux-gnu-zig-cc    # Tool wrapper
#   $PREFIX/lib/zig/                             # Standard library
#
install_native_compiler() {
    local source_dir="$1"
    local prefix="$2"

    echo "=== Installing Native Compiler ==="

    # Use environment variable set by conda build:
    #   CONDA_TOOLCHAIN_HOST - target triplet (where binary runs)
    # For native builds, HOST == BUILD
    local conda_triplet="${CONDA_TOOLCHAIN_HOST}"
    echo "Conda triplet: ${conda_triplet}"

    # Install binary
    mkdir -p "${prefix}/bin"
    if [[ -f "${source_dir}/zig" ]]; then
        cp "${source_dir}/zig" "${prefix}/bin/zig"
    elif [[ -f "${source_dir}/bin/zig" ]]; then
        cp "${source_dir}/bin/zig" "${prefix}/bin/zig"
    else
        echo "ERROR: Cannot find zig binary in ${source_dir}"
        return 1
    fi
    chmod +x "${prefix}/bin/zig"

    # Install standard library
    mkdir -p "${prefix}/lib"
    if [[ -d "${source_dir}/lib/zig" ]]; then
        cp -r "${source_dir}/lib/zig" "${prefix}/lib/"
    elif [[ -d "${source_dir}/lib" ]]; then
        mkdir -p "${prefix}/lib/zig"
        cp -r "${source_dir}/lib/"* "${prefix}/lib/zig/"
    fi

    # Install documentation if present
    if [[ -d "${source_dir}/doc" ]]; then
        mkdir -p "${prefix}/doc"
        cp -r "${source_dir}/doc/"* "${prefix}/doc/"
    fi

    # Generate triplet-prefixed wrappers
    generate_native_triplet_wrappers "${prefix}" "${conda_triplet}"

    echo "Native compiler installed:"
    echo "  Binary:   ${prefix}/bin/zig"
    echo "  Triplet:  ${prefix}/bin/${conda_triplet}-zig"
    echo "  Wrappers: ${prefix}/bin/${conda_triplet}-zig-{cc,c++,ar}"
    echo "  Stdlib:   ${prefix}/lib/zig/"
}

# === Install Native Compiler Implementation ===
# Installs ONLY the triplet-prefixed binary and stdlib (no wrappers, no activation)
# Used by zig_impl_$TG_ package
#
# Layout:
#   $PREFIX/bin/x86_64-conda-linux-gnu-zig       # Triplet-prefixed binary
#   $PREFIX/lib/zig/                             # Standard library
#   $PREFIX/doc/                                 # Documentation
#
install_native_compiler_impl() {
    local source_dir="$1"
    local prefix="$2"

    echo "=== Installing Native Compiler Implementation ==="

    local conda_triplet="${CONDA_TOOLCHAIN_HOST:-x86_64-conda-linux-gnu}"
    echo "Conda triplet: ${conda_triplet}"

    # Install triplet-prefixed binary (NOT unprefixed)
    mkdir -p "${prefix}/bin"
    if [[ -f "${source_dir}/zig" ]]; then
        cp "${source_dir}/zig" "${prefix}/bin/${conda_triplet}-zig"
    elif [[ -f "${source_dir}/bin/zig" ]]; then
        cp "${source_dir}/bin/zig" "${prefix}/bin/${conda_triplet}-zig"
    else
        echo "ERROR: Cannot find zig binary in ${source_dir}"
        return 1
    fi
    chmod +x "${prefix}/bin/${conda_triplet}-zig"

    # Install standard library
    mkdir -p "${prefix}/lib"
    if [[ -d "${source_dir}/lib/zig" ]]; then
        cp -r "${source_dir}/lib/zig" "${prefix}/lib/"
    elif [[ -d "${source_dir}/lib" ]]; then
        mkdir -p "${prefix}/lib/zig"
        cp -r "${source_dir}/lib/"* "${prefix}/lib/zig/"
    fi

    # Install documentation if present
    if [[ -d "${source_dir}/doc" ]]; then
        mkdir -p "${prefix}/doc"
        cp -r "${source_dir}/doc/"* "${prefix}/doc/"
    fi

    echo "Native compiler impl installed:"
    echo "  Binary:   ${prefix}/bin/${conda_triplet}-zig"
    echo "  Stdlib:   ${prefix}/lib/zig/"
    echo "  (NO activation scripts, NO wrappers - those go in zig_$TG_)"
}

# === Install Cross-Compiler Implementation ===
# Installs ONLY the native binary and stdlib for cross-compilation (no wrappers)
# Used by zig_impl_$TG_ package for cross-compilers
#
# Layout:
#   $PREFIX/bin/x86_64-conda-linux-gnu-zig       # Native binary (runs on host)
#   $PREFIX/lib/zig/                             # Standard library (universal)
#
install_cross_compiler_impl() {
    local source_dir="$1"
    local prefix="$2"

    echo "=== Installing Cross-Compiler Implementation ==="

    local native_triplet="${CONDA_TOOLCHAIN_BUILD:-x86_64-conda-linux-gnu}"
    echo "Native triplet: ${native_triplet}"

    # Install native zig binary (runs on build host)
    mkdir -p "${prefix}/bin"
    if [[ -f "${source_dir}/zig" ]]; then
        cp "${source_dir}/zig" "${prefix}/bin/${native_triplet}-zig"
    elif [[ -f "${source_dir}/bin/zig" ]]; then
        cp "${source_dir}/bin/zig" "${prefix}/bin/${native_triplet}-zig"
    else
        echo "ERROR: Cannot find zig binary in ${source_dir}"
        return 1
    fi
    chmod +x "${prefix}/bin/${native_triplet}-zig"

    # Install standard library (universal across targets)
    mkdir -p "${prefix}/lib"
    if [[ -d "${source_dir}/lib/zig" ]]; then
        cp -r "${source_dir}/lib/zig" "${prefix}/lib/"
    elif [[ -d "${source_dir}/lib" ]]; then
        mkdir -p "${prefix}/lib/zig"
        cp -r "${source_dir}/lib/"* "${prefix}/lib/zig/"
    fi

    echo "Cross-compiler impl installed:"
    echo "  Native:   ${prefix}/bin/${native_triplet}-zig"
    echo "  Stdlib:   ${prefix}/lib/zig/"
    echo "  (NO cross wrappers - those go in zig_$TG_)"
}

# === Install Zig Compiler (Dispatcher) ===
# Dispatches to native or cross-compiler installation based on BUILD_MODE and PKG_VARIANT
#
install_zig_compiler() {
    local source_dir="$1"
    local prefix="${2:-${PREFIX}}"

    # Ensure build mode is detected
    if [[ -z "${BUILD_MODE:-}" ]]; then
        detect_build_mode
    fi

    # Check if this is an impl package (set by recipe.yaml script env)
    if [[ "${PKG_VARIANT:-}" == "impl" ]]; then
        echo "Installing implementation package (zig_impl_$TG_)"
        case "${BUILD_MODE}" in
            native|cross-target)
                install_native_compiler_impl "${source_dir}" "${prefix}"
                ;;
            cross-compiler)
                install_cross_compiler_impl "${source_dir}" "${prefix}"
                ;;
            *)
                echo "ERROR: Unknown BUILD_MODE: ${BUILD_MODE}"
                return 1
                ;;
        esac
    else
        # Legacy path for non-impl packages (backwards compatibility)
        echo "Installing full package (legacy zig_$TG_ pattern)"
        case "${BUILD_MODE}" in
            native|cross-target)
                install_native_compiler "${source_dir}" "${prefix}"
                install_activation_scripts "${prefix}" ""
                install_wrapper_scripts "${prefix}"
                ;;
            cross-compiler)
                install_cross_compiler "${source_dir}" "${prefix}"
                ;;
            *)
                echo "ERROR: Unknown BUILD_MODE: ${BUILD_MODE}"
                return 1
                ;;
        esac
    fi

    echo "=== Zig Compiler Installation Complete ==="
}
