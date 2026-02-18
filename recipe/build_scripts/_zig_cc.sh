# ZIG CC COMPILER WRAPPERS (zig-native build mode)
#
# This file contains compiler wrapper functions for zig-native build mode,
# where zig is used as the primary C/C++ compiler instead of GCC.
#
# Functions:
#   - setup_zig_cc: Creates zig cc/c++/ar/ranlib wrapper scripts
#   - create_filtered_llvm_config: Creates llvm-config wrapper filtering unsupported flags
#
# Usage in build scripts:
#   source "$(dirname "$0")/_zig_cc.sh"
#   setup_zig_cc "${BOOTSTRAP_ZIG}" "x86_64-linux-gnu" "baseline"
#   create_filtered_llvm_config "${PREFIX}/bin/llvm-config"

# === Setup zig as C/C++ compiler ===
# Creates wrapper scripts for CMake that invoke zig cc/c++/ar/ranlib
# This eliminates the need for GCC workarounds since zig bundles its own libc
#
# Args:
#   $1 - zig binary path (required)
#   $2 - target triple (default: native)
#   $3 - mcpu (default: baseline)
#
# Exports: ZIG_CC, ZIG_CXX, ZIG_AR, ZIG_RANLIB
#
# Usage:
#   setup_zig_cc "${BOOTSTRAP_ZIG}" "x86_64-linux-gnu" "baseline"
#   cmake ... -DCMAKE_C_COMPILER="${ZIG_CC}" ...
#
setup_zig_cc() {
    local zig="$1"
    local target="${2:-native}"
    local mcpu="${3:-baseline}"
    local wrapper_dir="${SRC_DIR}/zig-cc-wrappers"

    if [[ -z "${zig}" ]] || [[ ! -x "${zig}" ]]; then
        echo "ERROR: setup_zig_cc requires valid zig binary path" >&2
        return 1
    fi

    mkdir -p "${wrapper_dir}"

    # zig-cc wrapper - filters out GCC-specific flags that zig doesn't support
    cat > "${wrapper_dir}/zig-cc" << 'WRAPPER_EOF'
#!/usr/bin/env bash
# Filter out flags that zig cc doesn't support
# Handles both -Wl,FLAG and -Xlinker FLAG patterns
args=()
is_linking=0
skip_next=0

for arg in "$@"; do
    # Skip this arg if marked by -Xlinker handling
    if [[ $skip_next -eq 1 ]]; then
        skip_next=0
        continue
    fi

    case "$arg" in
        # Detect if this is a link step (has -o but no -c)
        -o) is_linking=1; args+=("$arg") ;;
        -c) is_linking=0; args+=("$arg") ;;

        # Handle -Xlinker FLAG (passes next arg directly to linker)
        -Xlinker)
            # Peek at next argument - we need to check if it should be filtered
            # For now, just skip -Xlinker entirely as zig handles linker args differently
            skip_next=1
            continue ;;

        # Unsupported linker flags in -Wl, format
        -Wl,-rpath-link|-Wl,-rpath-link,*|-Wl,--disable-new-dtags)
            continue ;;
        -Wl,--allow-shlib-undefined|-Wl,--no-allow-shlib-undefined)
            continue ;;
        -Wl,-Bsymbolic-functions|-Wl,-Bsymbolic)
            continue ;;
        -Wl,-soname|-Wl,-soname,*)
            continue ;;
        -Wl,--version-script|-Wl,--version-script,*)
            continue ;;
        -Wl,-z,*|-Wl,-z)
            continue ;;
        -Wl,--as-needed|-Wl,--no-as-needed)
            continue ;;
        -Wl,-O*)
            continue ;;
        -Wl,--gc-sections|-Wl,--no-gc-sections)
            continue ;;
        -Wl,--build-id|-Wl,--build-id=*)
            continue ;;
        -Wl,--color-diagnostics)
            continue ;;

        # Standalone linker flags (shouldn't appear but filter anyway)
        -Bsymbolic-functions|-Bsymbolic)
            continue ;;

        # GCC-specific optimization flags
        -march=*|-mtune=*|-ftree-vectorize)
            continue ;;
        # Stack protector handled differently by zig
        -fstack-protector-strong|-fstack-protector)
            continue ;;
        -fno-plt)
            continue ;;
        # Debug prefix maps - zig handles differently
        -fdebug-prefix-map=*)
            continue ;;
        *)
            args+=("$arg") ;;
    esac
done
# Add libstdc++ when linking (LLVM libs need it)
if [[ $is_linking -eq 1 ]]; then
    args+=("-lstdc++")
fi
WRAPPER_EOF
    echo "exec \"${zig}\" cc -target ${target} -mcpu=${mcpu} \"\${args[@]}\"" >> "${wrapper_dir}/zig-cc"
    chmod +x "${wrapper_dir}/zig-cc"

    # zig-c++ wrapper - same filtering as zig-cc, always links libstdc++ for C++
    cat > "${wrapper_dir}/zig-cxx" << 'WRAPPER_EOF'
#!/usr/bin/env bash
# Filter out flags that zig c++ doesn't support
# Handles both -Wl,FLAG and -Xlinker FLAG patterns
args=()
is_linking=0
skip_next=0

for arg in "$@"; do
    # Skip this arg if marked by -Xlinker handling
    if [[ $skip_next -eq 1 ]]; then
        skip_next=0
        continue
    fi

    case "$arg" in
        # Detect if this is a link step (has -o but no -c)
        -o) is_linking=1; args+=("$arg") ;;
        -c) is_linking=0; args+=("$arg") ;;

        # Handle -Xlinker FLAG (passes next arg directly to linker)
        -Xlinker)
            # Skip -Xlinker and its following argument - zig handles linker args differently
            skip_next=1
            continue ;;

        # Unsupported linker flags in -Wl, format
        -Wl,-rpath-link|-Wl,-rpath-link,*|-Wl,--disable-new-dtags)
            continue ;;
        -Wl,--allow-shlib-undefined|-Wl,--no-allow-shlib-undefined)
            continue ;;
        -Wl,-Bsymbolic-functions|-Wl,-Bsymbolic)
            continue ;;
        -Wl,-soname|-Wl,-soname,*)
            continue ;;
        -Wl,--version-script|-Wl,--version-script,*)
            continue ;;
        -Wl,-z,*|-Wl,-z)
            continue ;;
        -Wl,--as-needed|-Wl,--no-as-needed)
            continue ;;
        -Wl,-O*)
            continue ;;
        -Wl,--gc-sections|-Wl,--no-gc-sections)
            continue ;;
        -Wl,--build-id|-Wl,--build-id=*)
            continue ;;
        -Wl,--color-diagnostics)
            continue ;;

        # Standalone linker flags (shouldn't appear but filter anyway)
        -Bsymbolic-functions|-Bsymbolic)
            continue ;;

        # GCC-specific optimization flags
        -march=*|-mtune=*|-ftree-vectorize)
            continue ;;
        -fstack-protector-strong|-fstack-protector)
            continue ;;
        -fno-plt)
            continue ;;
        -fdebug-prefix-map=*)
            continue ;;
        *)
            args+=("$arg") ;;
    esac
done
# Add libstdc++ when linking (LLVM libs need it)
if [[ $is_linking -eq 1 ]]; then
    args+=("-lstdc++")
fi
WRAPPER_EOF
    echo "exec \"${zig}\" c++ -target ${target} -mcpu=${mcpu} \"\${args[@]}\"" >> "${wrapper_dir}/zig-cxx"
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

    # Clear conda's compiler flags - zig handles optimization internally
    # These contain GCC-specific flags that break zig cc
    unset CFLAGS CXXFLAGS LDFLAGS CPPFLAGS
    export CFLAGS="" CXXFLAGS="" LDFLAGS="" CPPFLAGS=""

    echo "=== setup_zig_cc: Created zig compiler wrappers ==="
    echo "  ZIG_CC:     ${ZIG_CC}"
    echo "  ZIG_CXX:    ${ZIG_CXX}"
    echo "  ZIG_AR:     ${ZIG_AR}"
    echo "  ZIG_RANLIB: ${ZIG_RANLIB}"
    echo "  Target:     ${target}"
    echo "  MCPU:       ${mcpu}"
    echo "  (Cleared CFLAGS/LDFLAGS - zig handles optimization internally)"
}

# LLVM-CONFIG WRAPPER

# Create a filtered llvm-config wrapper that removes flags unsupported by zig's linker
# Args:
#   $1 - Path to llvm-config binary to wrap
# Creates a wrapper in place that filters out -Bsymbolic-functions and similar flags
create_filtered_llvm_config() {
    local llvm_config="$1"

    if [[ ! -x "${llvm_config}" ]]; then
        echo "ERROR: llvm-config not found or not executable: ${llvm_config}" >&2
        return 1
    fi

    # Don't wrap if already wrapped
    if [[ -f "${llvm_config}.real" ]]; then
        echo "  llvm-config already wrapped: ${llvm_config}"
        return 0
    fi

    echo "Creating filtered llvm-config wrapper: ${llvm_config}"
    mv "${llvm_config}" "${llvm_config}.real"

    cat > "${llvm_config}" << 'WRAPPER_EOF'
#!/usr/bin/env bash
# Wrapper for llvm-config that filters out flags unsupported by zig's linker
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_CONFIG="${SCRIPT_DIR}/$(basename "$0").real"

# Run the real llvm-config
output=$("${REAL_CONFIG}" "$@")

# Filter output for --ldflags and --system-libs which may contain unsupported flags
for arg in "$@"; do
    case "$arg" in
        --ldflags|--system-libs|--libs|--link-static|--link-shared)
            # Filter out GNU ld specific flags that zig's linker doesn't support
            output=$(echo "$output" | sed \
                -e 's/-Wl,-Bsymbolic-functions//g' \
                -e 's/-Bsymbolic-functions//g' \
                -e 's/-Wl,-Bsymbolic//g' \
                -e 's/-Bsymbolic//g' \
                -e 's/-Wl,--disable-new-dtags//g' \
                -e 's/  */ /g' \
                -e 's/^ *//' \
                -e 's/ *$//')
            break
            ;;
    esac
done

echo "$output"
WRAPPER_EOF
    chmod +x "${llvm_config}"
    echo "  ✓ Created wrapper: ${llvm_config}"
}
