#!/usr/bin/env bash
set -euo pipefail

# Cross-compile zig for linux-riscv64 using zig as the C/C++ compiler
# This bypasses the sysroot_linux-riscv64 requirement since zig bundles its own libc

# --- Functions ---
source "${RECIPE_DIR}/build_scripts/_functions.sh"

# --- Configuration ---
ZIG_ARCH="riscv64"
ZIG_TARGET="${ZIG_ARCH}-linux-gnu"
ZIG_MCPU="${ZIG_MCPU:-baseline}"

echo "=== Cross-compiling zig for ${ZIG_TARGET} using zig as C/C++ compiler ==="
echo "  ZIG_ARCH: ${ZIG_ARCH}"
echo "  ZIG_TARGET: ${ZIG_TARGET}"
echo "  ZIG_MCPU: ${ZIG_MCPU}"

# --- Get bootstrap zig (native linux-64) ---
# Either use BUILD_PREFIX zig or install one
if [[ -x "${BUILD_PREFIX}/bin/zig" ]]; then
    BOOTSTRAP_ZIG="${BUILD_PREFIX}/bin/zig"
    echo "  Using BUILD_PREFIX zig: $(${BOOTSTRAP_ZIG} version)"
elif [[ -n "${BOOTSTRAP_ZIG:-}" ]] && [[ -x "${BOOTSTRAP_ZIG}" ]]; then
    echo "  Using BOOTSTRAP_ZIG: $(${BOOTSTRAP_ZIG} version)"
else
    echo "ERROR: No bootstrap zig found. Need native zig to cross-compile."
    exit 1
fi

# --- Setup zig as C/C++ compiler for CMake ---
# Zig bundles libc headers and can cross-compile without external sysroot
setup_zig_cc() {
    local zig="$1"
    local target="$2"
    local mcpu="$3"

    # Create wrapper scripts that CMake can use
    # (CMake doesn't handle semicolon-separated compiler args well in all cases)

    local wrapper_dir="${SRC_DIR}/zig-cc-wrappers"
    mkdir -p "${wrapper_dir}"

    # zig-cc wrapper
    cat > "${wrapper_dir}/zig-cc" << EOF
#!/usr/bin/env bash
exec "${zig}" cc -target ${target} -mcpu=${mcpu} "\$@"
EOF
    chmod +x "${wrapper_dir}/zig-cc"

    # zig-c++ wrapper
    cat > "${wrapper_dir}/zig-cxx" << EOF
#!/usr/bin/env bash
exec "${zig}" c++ -target ${target} -mcpu=${mcpu} "\$@"
EOF
    chmod +x "${wrapper_dir}/zig-cxx"

    # zig-ar wrapper
    cat > "${wrapper_dir}/zig-ar" << EOF
#!/usr/bin/env bash
exec "${zig}" ar "\$@"
EOF
    chmod +x "${wrapper_dir}/zig-ar"

    # zig-ranlib wrapper
    cat > "${wrapper_dir}/zig-ranlib" << EOF
#!/usr/bin/env bash
exec "${zig}" ranlib "\$@"
EOF
    chmod +x "${wrapper_dir}/zig-ranlib"

    export ZIG_CC="${wrapper_dir}/zig-cc"
    export ZIG_CXX="${wrapper_dir}/zig-cxx"
    export ZIG_AR="${wrapper_dir}/zig-ar"
    export ZIG_RANLIB="${wrapper_dir}/zig-ranlib"

    echo "  Created zig compiler wrappers in ${wrapper_dir}"
    echo "    ZIG_CC: ${ZIG_CC}"
    echo "    ZIG_CXX: ${ZIG_CXX}"
}

setup_zig_cc "${BOOTSTRAP_ZIG}" "${ZIG_TARGET}" "${ZIG_MCPU}"

# --- Configure CMake to use zig as compiler ---
EXTRA_CMAKE_ARGS+=(
    -DCMAKE_SYSTEM_NAME=Linux
    -DCMAKE_SYSTEM_PROCESSOR=${ZIG_ARCH}
    -DCMAKE_C_COMPILER="${ZIG_CC}"
    -DCMAKE_CXX_COMPILER="${ZIG_CXX}"
    -DCMAKE_AR="${ZIG_AR}"
    -DCMAKE_RANLIB="${ZIG_RANLIB}"
    -DCMAKE_CROSSCOMPILING=ON
    -DZIG_TARGET_TRIPLE=${ZIG_TARGET}
)

# Zig args for the zig build phase
EXTRA_ZIG_ARGS+=(
    -Dtarget=${ZIG_TARGET}
    -Dcpu=${ZIG_MCPU}
)

echo "=== CMake args for zig cross-compilation ==="
for arg in "${EXTRA_CMAKE_ARGS[@]}"; do
    echo "  ${arg}"
done

# --- Build ---
# Stage 1: CMake configure with zig as C/C++ compiler
echo "=== Stage 1: CMake configure ==="
cmake -S "${cmake_source_dir}" -B "${cmake_build_dir}" \
    -GNinja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${cmake_install_dir}" \
    "${EXTRA_CMAKE_ARGS[@]}"

# Stage 2: Build with CMake
echo "=== Stage 2: CMake build ==="
cmake --build "${cmake_build_dir}" -j"${CPU_COUNT}"

# Stage 3: Install
echo "=== Stage 3: Install ==="
cmake --install "${cmake_build_dir}"

# --- Copy to target build directory for zig self-hosted build ---
echo "=== Preparing for zig self-hosted build ==="
mkdir -p "${zig_build_dir}"
cp -r "${cmake_install_dir}"/* "${zig_build_dir}/"

# Stage 4: Build zig with zig (self-hosted)
echo "=== Stage 4: zig build (self-hosted) ==="
cd "${zig_build_dir}"

# Use the CMake-built zig1 to bootstrap the full compiler
if [[ -x "./zig" ]]; then
    ./zig build \
        -Doptimize=ReleaseFast \
        -Dtarget=${ZIG_TARGET} \
        -Dcpu=${ZIG_MCPU} \
        --prefix "${PREFIX}" \
        "${EXTRA_ZIG_ARGS[@]:-}"
else
    echo "WARNING: No zig binary found, skipping self-hosted build"
    # Just install what CMake built
    cp -r "${cmake_install_dir}"/* "${PREFIX}/"
fi

echo "=== Cross-compilation complete: ${ZIG_TARGET} ==="
