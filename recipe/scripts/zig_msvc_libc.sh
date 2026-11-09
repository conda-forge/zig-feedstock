#!/bin/bash
# Zig msvc-target activation (unix host, *-windows-msvc target)
# Installed to: $PREFIX/etc/conda/activate.d/zig_msvc_libc.sh
#
# Writes a zig libc file from the msvc-headers-libs / winsdk trees under
# CONDA_BUILD_WINSDK and exports ZIG_MSVC_LIBC_FILE / ZIG_MSVC_EXTRA_INCLUDES
# for the zig-cc wrapper. Sorts after the msvc-headers-libs/winsdk scripts.

_zml_root="${CONDA_BUILD_WINSDK:-}"
if [[ -z "${_zml_root}" ]]; then
    echo "zig msvc: set CONDA_BUILD_WINSDK to accept the Microsoft licences and enable msvc linking" >&2
    unset _zml_root
    return 0 2>/dev/null || exit 0
fi

_zml_sort() { sort -V 2>/dev/null || sort; }
_zml_msvc="$(ls -d "${_zml_root}"/msvc-* 2>/dev/null | _zml_sort | tail -n 1)"
_zml_sdk="$(ls -d "${_zml_root}"/winsdk-* 2>/dev/null | _zml_sort | tail -n 1)"
unset -f _zml_sort
if [[ ! -d "${_zml_msvc}/include" || ! -d "${_zml_sdk}/include" ]]; then
    echo "zig msvc: no msvc-*/winsdk-* trees under ${_zml_root} (not downloaded yet?)" >&2
    unset _zml_root _zml_msvc _zml_sdk
    return 0 2>/dev/null || exit 0
fi

# SDK headers keep MS casing (Windows.h); conda clang uses a VFS overlay zig
# cannot take, so add lowercase aliases once on case-sensitive filesystems.
# Probe: on a case-insensitive FS (macOS APFS) the lowercase name already resolves.
_zml_ci=0
if touch "${_zml_root}/.ZIG-CASE-PROBE" 2>/dev/null; then
    [[ -e "${_zml_root}/.zig-case-probe" ]] && _zml_ci=1
    rm -f "${_zml_root}/.ZIG-CASE-PROBE"
fi
if [[ "${_zml_ci}" == 0 && ! -e "${_zml_root}/.zig-lc-headers" ]]; then
    for _zml_d in "${_zml_sdk}/include" "${_zml_msvc}/include"; do
        while IFS= read -r _zml_h; do
            _zml_lc="$(dirname "${_zml_h}")/$(basename "${_zml_h}" | tr '[:upper:]' '[:lower:]')"
            [[ -e "${_zml_lc}" ]] || ln -s "$(basename "${_zml_h}")" "${_zml_lc}"
        done < <(find "${_zml_d}" -type f -name '*[A-Z]*' \( -name '*.h' -o -name '*.H' -o -name '*.hpp' -o -name '*.inl' \) 2>/dev/null)
    done
    # SDK headers also #include each other under a casing that differs from disk
    # (shared/DriverSpecs.h): alias every referenced name to its real file.
    _zml_mixed() {
        local _zml_idx _zml_names _zml_dirs _zml_d _zml_dir _zml_tgt _zml_nm _zml_lnk
        _zml_dirs=("${_zml_sdk}/include/ucrt" "${_zml_sdk}/include/um" "${_zml_sdk}/include/shared" "${_zml_sdk}/include/winrt" "${_zml_msvc}/include")
        _zml_idx="$(mktemp)" || return 0
        _zml_names="$(mktemp)" || { rm -f "${_zml_idx}"; return 0; }
        for _zml_d in "${_zml_dirs[@]}"; do
            [[ -d "${_zml_d}" ]] || continue
            ( cd "${_zml_d}" && find . \( -type f -o -type l \) -print 2>/dev/null ) \
                | sed 's|^\./||' \
                | awk -v d="${_zml_d}" '{ print tolower($0) "\t" d "\t" $0 }' >> "${_zml_idx}"
        done
        grep -rhIoE '^[[:space:]]*#[[:space:]]*include[[:space:]]*[<"][^>"]+[>"]' "${_zml_dirs[@]}" 2>/dev/null \
            | tr -d '\r' | sed -E 's/^[^<"]*[<"]//; s/[>"]$//; s|\\|/|g' | sort -u > "${_zml_names}"
        awk -F '\t' '
            NR == FNR { if (!($1 in idx)) idx[$1] = $2 "\t" $3; ex[$3] = 1; next }
            { n = $0 }
            n == "" || n ~ /^\// || n ~ /(^|\/)\.\.(\/|$)/ || (n in ex) { next }
            { k = tolower(n) }
            k in idx {
                split(idx[k], a, "\t"); up = ""; t = n
                while ((i = index(t, "/")) > 0) { up = up "../"; t = substr(t, i + 1) }
                print a[1] "\t" up a[2] "\t" n
            }' "${_zml_idx}" "${_zml_names}" 2>/dev/null \
            | while IFS=$'\t' read -r _zml_dir _zml_tgt _zml_nm; do
                _zml_lnk="${_zml_dir}/${_zml_nm}"
                [[ -e "${_zml_lnk}" || -L "${_zml_lnk}" ]] && continue
                mkdir -p "$(dirname "${_zml_lnk}")" 2>/dev/null || continue
                ln -s "${_zml_tgt}" "${_zml_lnk}" 2>/dev/null || true
            done
        rm -f "${_zml_idx}" "${_zml_names}"
        return 0
    }
    _zml_mixed || true
    unset -f _zml_mixed
    touch "${_zml_root}/.zig-lc-headers" 2>/dev/null || true
fi

_zml_file="${CONDA_PREFIX}/etc/zig/libc-x86_64-windows-msvc.txt"
mkdir -p "${CONDA_PREFIX}/etc/zig"
cat > "${_zml_file}" <<EOF
include_dir=${_zml_sdk}/include/ucrt
sys_include_dir=${_zml_msvc}/include
crt_dir=${_zml_sdk}/lib/ucrt/x64
msvc_lib_dir=${_zml_msvc}/lib/x64
kernel32_lib_dir=${_zml_sdk}/lib/um/x64
gcc_dir=
darwin_sdk_dir=
EOF

# Remember prior values once, for deactivate
if [[ -z "${_ZIG_MSVC_SAVED:-}" ]]; then
    export _ZIG_MSVC_SAVED=1
    if [[ -n "${ZIG_MSVC_LIBC_FILE+x}" ]]; then
        export _ZIG_MSVC_OLD_LIBC_FILE="${ZIG_MSVC_LIBC_FILE}"
    fi
    if [[ -n "${ZIG_MSVC_EXTRA_INCLUDES+x}" ]]; then
        export _ZIG_MSVC_OLD_EXTRA_INCLUDES="${ZIG_MSVC_EXTRA_INCLUDES}"
    fi
fi

export ZIG_MSVC_LIBC_FILE="${_zml_file}"
export ZIG_MSVC_EXTRA_INCLUDES="${_zml_sdk}/include/um:${_zml_sdk}/include/shared:${_zml_sdk}/include/winrt"

unset _zml_root _zml_msvc _zml_sdk _zml_file _zml_ci _zml_d _zml_h _zml_lc
