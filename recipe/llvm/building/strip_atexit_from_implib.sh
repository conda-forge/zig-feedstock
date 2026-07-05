# Reusable function: strip atexit from a MinGW import lib
# Used by both the fast-fail stub test AND the real Phase 1.5.
# Any bug here surfaces in ~5 s (stub) instead of ~90 min (post-build).
#
# Usage: strip_atexit_from_implib <implib_path> <zig_bin> [dll_fallback] [machine]
#   implib_path : path to .dll.a to clean in-place
#   zig_bin     : (unused, kept for backward compatibility)
#   dll_fallback: (unused, kept for backward compatibility)
#   machine     : (unused, kept for backward compatibility)
#
# Returns 0 on success (or if no atexit found), 1 on failure.
#
# Implementation: uses python3 to directly parse and rewrite the ar archive
# binary, removing any import entry members that contain atexit.
#
# WHY NOT ar x / ar d:
#   COFF import library members ALL have the same ar member name (the DLL name,
#   e.g., "libTest.dll/").  When ar x extracts 49000 members with the same name,
#   each overwrites the previous — only the last survives.  ar d with a name
#   deletes only the FIRST matching member (almost certainly not the atexit one).
#   Direct binary manipulation is the only reliable approach.
strip_atexit_from_implib() {
  local _implib="$1"
  local _zig_bin="$2"          # kept for backward compatibility, unused
  local _dll_fallback="${3:-libLLVM-20}"  # kept for backward compatibility, unused
  local _machine="${4:-}"                  # kept for backward compatibility, unused
  local _dir _bak

  _dir=$(dirname "${_implib}")
  _bak="${_implib}.bak"

  # Restore backup on failure
  _strip_restore() {
    if [[ -f "${_bak}" ]]; then
      cp "${_bak}" "${_implib}"
      echo "    restored backup after failure"
    fi
  }

  # ── Step 1: Detection ────────────────────────────────────────────────────────
  # Use `strings` — GNU nm can't read aarch64 COFF short import entries, but
  # `strings` finds symbol names in any binary format.
  { set +x; } 2>/dev/null
  local _has_atexit=false
  if strings -a "${_implib}" 2>/dev/null | grep -qx 'atexit'; then
    _has_atexit=true
  fi
  set -x

  if ! ${_has_atexit}; then
    echo "    no atexit in import lib — nothing to do"
    return 0
  fi
  echo "    atexit found — removing via python3 archive manipulation..."

  # ── Step 2: Make a backup before any modification ────────────────────────────
  cp "${_implib}" "${_bak}"

  # ── Step 3: Python3 archive manipulation ─────────────────────────────────────
  # Parse the ar archive binary directly, remove atexit member(s), and rebuild
  # the linker symbol tables with corrected member offsets.
  #
  # COFF import lib members all have the same name (the DLL name), so ar x/ar d
  # cannot distinguish them.  We must read the archive member-by-member, check
  # each body for the atexit symbol, and write a new archive excluding matches.
  local _py_exit
  python3 - "${_implib}" <<'PYEOF'
"""Remove atexit import entries from a COFF import library archive.

COFF import lib members all have the same ar name (the DLL name).
ar x/ar d cannot handle this -- use direct binary archive manipulation.

Exit codes:
  0  atexit member(s) removed successfully
  1  no atexit member found (detection was a false positive)
  2  error (parse failure, write failure, etc.)
"""
import sys
import struct
import os

MAGIC = b'!<arch>\n'
HDR_SIZE = 60
HDR_MAGIC = b'\x60\x0a'


def parse_ar(data):
    """Parse ar archive into list of (offset, header_bytes, body_bytes).

    offset is the byte offset of the header from the start of the archive.
    Returns list of (offset, hdr, body) tuples.
    """
    if data[:8] != MAGIC:
        print("ERROR: not an ar archive (bad magic)", file=sys.stderr)
        sys.exit(2)
    pos = 8
    members = []
    while pos + HDR_SIZE <= len(data):
        hdr = data[pos:pos + HDR_SIZE]
        if hdr[58:60] != HDR_MAGIC:
            print(f"ERROR: invalid header magic at offset {pos:#x}", file=sys.stderr)
            sys.exit(2)
        try:
            size_str = hdr[48:58].decode('ascii').strip()
            size = int(size_str)
        except (ValueError, UnicodeDecodeError) as e:
            print(f"ERROR: bad size field at offset {pos:#x}: {e}", file=sys.stderr)
            sys.exit(2)
        body = data[pos + HDR_SIZE:pos + HDR_SIZE + size]
        members.append((pos, hdr, body))
        pos += HDR_SIZE + size + (size % 2)  # padding byte for odd-sized members
    return members


def member_name(hdr):
    """Return the raw name field of an ar header (16 bytes, space-padded)."""
    return hdr[:16].decode('ascii', errors='replace')


def is_first_linker(hdr):
    name = member_name(hdr).rstrip()
    return name == '/'


def is_second_linker(hdr):
    name = member_name(hdr).rstrip()
    # Second linker member also has name "/" but is the second occurrence
    return name == '/'


def is_longnames(hdr):
    name = member_name(hdr).rstrip()
    return name == '//'


def is_special(hdr):
    name = member_name(hdr).rstrip()
    return name in ('/', '//') or name.startswith('#')


def has_atexit(body):
    """Check if member body contains 'atexit' as a bounded symbol name.

    Looks for \\0atexit\\0 anywhere in the body, or atexit\\0 at position 0.
    This matches both short-import entries (symbol in string table) and
    long-import entries (symbol in COFF symbol table).
    """
    target = b'atexit\x00'
    idx = 0
    while True:
        idx = body.find(target, idx)
        if idx < 0:
            return False
        # Bounded: preceded by \0 or at start of body
        if idx == 0 or body[idx - 1:idx] == b'\x00':
            return True
        idx += 1


def rebuild_first_linker(old_body, removed_set, offset_map):
    """Rebuild first linker member (big-endian COFF symbol table).

    removed_set: set of old member offsets that were removed
    offset_map:  dict mapping old member offset -> new member offset
    """
    if len(old_body) < 4:
        print("WARNING: first linker member too short to parse, copying as-is",
              file=sys.stderr)
        return old_body

    num_syms = struct.unpack('>I', old_body[:4])[0]
    table_end = 4 + num_syms * 4
    if table_end > len(old_body):
        print("WARNING: first linker member offset table truncated, copying as-is",
              file=sys.stderr)
        return old_body

    raw_offsets = struct.unpack(f'>{num_syms}I', old_body[4:table_end])
    str_data = old_body[table_end:]

    # Parse null-terminated string table
    strings = []
    pos = 0
    for _ in range(num_syms):
        end = str_data.find(b'\x00', pos)
        if end < 0:
            end = len(str_data)
        strings.append(str_data[pos:end])
        pos = end + 1

    # Filter: drop symbols whose old offset is in removed_set; remap the rest
    new_offsets = []
    new_strings = []
    removed_count = 0
    for off, s in zip(raw_offsets, strings):
        if off in removed_set:
            removed_count += 1
            continue
        new_offsets.append(offset_map.get(off, off))
        new_strings.append(s)

    print(f"    first linker member: removed {removed_count} symbol(s), "
          f"kept {len(new_offsets)}", file=sys.stderr)

    n = len(new_offsets)
    result = struct.pack('>I', n)
    if n:
        result += struct.pack(f'>{n}I', *new_offsets)
    for s in new_strings:
        result += s + b'\x00'
    return result


def rebuild_second_linker(old_body, removed_set, offset_map):
    """Rebuild second linker member (little-endian COFF symbol table).

    removed_set: set of old member offsets that were removed
    offset_map:  dict mapping old member offset -> new member offset
    """
    pos = 0
    try:
        num_members = struct.unpack('<I', old_body[pos:pos + 4])[0]
        pos += 4
        member_offsets = list(struct.unpack(
            f'<{num_members}I', old_body[pos:pos + num_members * 4]))
        pos += num_members * 4
        num_syms = struct.unpack('<I', old_body[pos:pos + 4])[0]
        pos += 4
        indices = list(struct.unpack(
            f'<{num_syms}H', old_body[pos:pos + num_syms * 2]))
        pos += num_syms * 2
    except struct.error as e:
        print(f"WARNING: second linker member truncated ({e}), copying as-is",
              file=sys.stderr)
        return old_body

    str_data = old_body[pos:]

    # Parse null-terminated string table
    strings = []
    spos = 0
    for _ in range(num_syms):
        end = str_data.find(b'\x00', spos)
        if end < 0:
            end = len(str_data)
        strings.append(str_data[spos:end])
        spos = end + 1

    # Build new member offset list (1-based index mapping: old 1-based -> new 1-based)
    # old_to_new_idx maps OLD 1-based index -> NEW 1-based index (or None if removed)
    old_to_new_idx = {}
    new_member_offsets = []
    for i, off in enumerate(member_offsets):
        old_idx = i + 1  # 1-based
        if off in removed_set:
            old_to_new_idx[old_idx] = None  # removed
        else:
            new_member_offsets.append(offset_map.get(off, off))
            old_to_new_idx[old_idx] = len(new_member_offsets)  # new 1-based index

    # Filter symbols: drop those pointing to removed members; remap the rest
    new_indices = []
    new_strings = []
    removed_count = 0
    for idx_val, s in zip(indices, strings):
        mapped = old_to_new_idx.get(idx_val)
        if mapped is None:
            removed_count += 1
            continue
        new_indices.append(mapped)
        new_strings.append(s)

    print(f"    second linker member: removed {removed_count} symbol(s), "
          f"kept {len(new_indices)}", file=sys.stderr)

    nm = len(new_member_offsets)
    ns = len(new_indices)
    result = struct.pack('<I', nm)
    if nm:
        result += struct.pack(f'<{nm}I', *new_member_offsets)
    result += struct.pack('<I', ns)
    if ns:
        result += struct.pack(f'<{ns}H', *new_indices)
    for s in new_strings:
        result += s + b'\x00'
    return result


def write_ar(members_to_write):
    """Serialise a list of (hdr, body) pairs back to ar bytes.

    Updates the Size field in each header to match the (possibly rebuilt) body.
    Returns the raw archive bytes.
    """
    out = bytearray(MAGIC)
    for hdr, body in members_to_write:
        # Patch size field in header
        hdr = bytearray(hdr)
        size_field = f'{len(body):<10}'.encode('ascii')
        hdr[48:58] = size_field
        out += bytes(hdr)
        out += body
        if len(body) % 2:
            out += b'\n'  # ar padding byte (conventionally \n)
    return bytes(out)


def main():
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <implib.dll.a>", file=sys.stderr)
        sys.exit(2)

    path = sys.argv[1]
    try:
        with open(path, 'rb') as f:
            data = f.read()
    except OSError as e:
        print(f"ERROR: cannot read {path}: {e}", file=sys.stderr)
        sys.exit(2)

    print(f"    archive size: {len(data):,} bytes", file=sys.stderr)
    members = parse_ar(data)
    print(f"    total members: {len(members)}", file=sys.stderr)

    # ── DIAGNOSTIC: full member enumeration ──────────────────────────────────
    # Unconditional (win-32/win-arm64 known-good AND win-64 broken) so CI logs
    # give us a direct diff of native zig-ar archive layout across targets.
    print(f"STRIP_ATEXIT_DIAG: total member count: {len(members)}", file=sys.stderr)
    for i, (off, hdr, body) in enumerate(members):
        raw_name = hdr[:16]
        print(
            f"STRIP_ATEXIT_DIAG: member[{i}] offset={off:#x} "
            f"name={member_name(hdr)!r} raw_name={raw_name!r} size={len(body)}",
            file=sys.stderr,
        )

    # Identify the special members by position/name, import members by the rest.
    # Layout: [first_linker "/"] [second_linker "/"] [longnames "//"] [import...]
    # The first two "/" members are linker members; we rebuild both.
    # "//" is longnames; we preserve as-is.
    slash_count = 0
    first_linker_idx = None
    second_linker_idx = None
    longnames_idx = None

    for i, (off, hdr, body) in enumerate(members):
        nm = member_name(hdr).rstrip()
        if nm == '/':
            slash_count += 1
            if slash_count == 1:
                first_linker_idx = i
            elif slash_count == 2:
                second_linker_idx = i
        elif nm == '//' and longnames_idx is None:
            longnames_idx = i

    print(f"    first linker member index:  {first_linker_idx}", file=sys.stderr)
    print(f"    second linker member index: {second_linker_idx}", file=sys.stderr)
    print(f"    longnames member index:     {longnames_idx}", file=sys.stderr)

    # ── DIAGNOSTIC: linker/symbol-table fields the strip logic keys on ───────
    print(
        f"STRIP_ATEXIT_DIAG: first_linker_present={first_linker_idx is not None} "
        f"second_linker_present={second_linker_idx is not None} "
        f"longnames_present={longnames_idx is not None} slash_count={slash_count}",
        file=sys.stderr,
    )
    if first_linker_idx is not None:
        _fl_body = members[first_linker_idx][2]
        if len(_fl_body) >= 4:
            _fl_num_syms = struct.unpack('>I', _fl_body[:4])[0]
        else:
            _fl_num_syms = None
        print(
            f"STRIP_ATEXIT_DIAG: first_linker body_size={len(_fl_body)} "
            f"parsed_num_syms={_fl_num_syms}",
            file=sys.stderr,
        )
    if second_linker_idx is not None:
        _sl_body = members[second_linker_idx][2]
        if len(_sl_body) >= 4:
            _sl_num_members = struct.unpack('<I', _sl_body[:4])[0]
            _sl_syms_off = 4 + _sl_num_members * 4
            if len(_sl_body) >= _sl_syms_off + 4:
                _sl_num_syms = struct.unpack(
                    '<I', _sl_body[_sl_syms_off:_sl_syms_off + 4])[0]
            else:
                _sl_num_syms = None
        else:
            _sl_num_members = None
            _sl_num_syms = None
        print(
            f"STRIP_ATEXIT_DIAG: second_linker body_size={len(_sl_body)} "
            f"parsed_num_members={_sl_num_members} parsed_num_syms={_sl_num_syms}",
            file=sys.stderr,
        )

    # Scan import members for atexit
    atexit_indices = []
    import_count = 0
    for i, (off, hdr, body) in enumerate(members):
        if i == first_linker_idx or i == second_linker_idx or i == longnames_idx:
            continue
        import_count += 1
        if has_atexit(body):
            atexit_indices.append(i)

    print(f"    import members scanned: {import_count}", file=sys.stderr)
    print(f"    atexit members found:   {len(atexit_indices)}", file=sys.stderr)

    # ── DIAGNOSTIC: exact selection set BEFORE any deletion/guard decision ───
    print(
        f"STRIP_ATEXIT_DIAG: selected for removal: {len(atexit_indices)} of "
        f"{import_count} import members (of {len(members)} total)",
        file=sys.stderr,
    )
    for i in atexit_indices:
        off, hdr, body = members[i]
        print(
            f"STRIP_ATEXIT_DIAG: selected member[{i}] offset={off:#x} "
            f"name={member_name(hdr)!r} size={len(body)}",
            file=sys.stderr,
        )

    if not atexit_indices:
        print("    no atexit member found — strings detection was a false positive",
              file=sys.stderr)
        sys.exit(1)

    # ── Safety guard: refuse implausible over-deletion ──────────────────────
    # atexit is a single CRT thunk; only a small, fixed number of import
    # members should ever reference it (observed: 1-2 on all known targets).
    # If the match set covers most/all of the archive's import members, the
    # detection has gone wrong (e.g. a native-mingw ar member layout that
    # defeats the null-boundary check in has_atexit) and writing the result
    # would zero out the import library. Abort loudly instead of silently
    # producing a near-empty .dll.a — this must never regress into a
    # 0-symbol implib again.
    _MAX_ATEXIT_MEMBERS = 8
    if (len(atexit_indices) > _MAX_ATEXIT_MEMBERS
            or (import_count > 0
                and len(atexit_indices) > import_count // 2)):
        print(
            f"    ERROR: refusing to strip — {len(atexit_indices)} of "
            f"{import_count} import members matched atexit (expected a "
            f"handful at most). This looks like an over-broad match rather "
            f"than the real atexit thunk; aborting to avoid destroying the "
            f"import library.",
            file=sys.stderr,
        )
        sys.exit(2)

    for i in atexit_indices:
        off, hdr, body = members[i]
        print(f"      member[{i}] offset={off:#x} name={member_name(hdr)!r} "
              f"size={len(body)}", file=sys.stderr)

    # Build set of old offsets that are being removed
    removed_set = {members[i][0] for i in atexit_indices}

    # Compute new offsets after removal.
    # We need to know: for each kept member, what is its new byte offset?
    # Strategy: simulate the write pass to get new offsets.
    kept_indices = [i for i in range(len(members)) if i not in set(atexit_indices)]

    # Temporarily note which indices are "kept" (we'll rebuild linkers separately)
    # First, determine new offsets for ALL kept members in their final order.
    # Linker members at positions 0 and 1 will be rebuilt; their size may change.
    # We do a two-pass approach: compute offsets using original body sizes, then
    # rebuild linker members with corrected offsets.  Since linker member sizes
    # can change when symbols are removed, we iterate until stable (usually 1-2x).

    def compute_new_offsets(members_list):
        """Given ordered list of (hdr, body), compute byte offset of each member."""
        offsets = []
        pos = 8  # after MAGIC
        for hdr, body in members_list:
            offsets.append(pos)
            pos += HDR_SIZE + len(body) + (len(body) % 2)
        return offsets

    # Build the kept members list (without rebuilding linkers yet)
    kept_members = [(members[i][1], members[i][2]) for i in kept_indices]

    # Compute old->new offset mapping using original body sizes as approximation.
    # (Linker member bodies will change, but their position in the file is fixed
    # at index 0 and 1, so offset_map for import members is accurate.)
    new_offsets_approx = compute_new_offsets(kept_members)

    # Map: old archive offset -> new archive offset
    offset_map = {}
    for new_pos, orig_idx in zip(new_offsets_approx, kept_indices):
        old_off = members[orig_idx][0]
        offset_map[old_off] = new_pos

    # Rebuild linker members with corrected symbol tables
    rebuilt_first = None
    rebuilt_second = None

    if first_linker_idx is not None:
        old_first_body = members[first_linker_idx][2]
        rebuilt_first = rebuild_first_linker(old_first_body, removed_set, offset_map)

    if second_linker_idx is not None:
        old_second_body = members[second_linker_idx][2]
        rebuilt_second = rebuild_second_linker(old_second_body, removed_set, offset_map)

    # Now build the final member list with rebuilt linker bodies
    final_members = []
    for orig_idx in kept_indices:
        off, hdr, body = members[orig_idx]
        if orig_idx == first_linker_idx and rebuilt_first is not None:
            final_members.append((hdr, rebuilt_first))
        elif orig_idx == second_linker_idx and rebuilt_second is not None:
            final_members.append((hdr, rebuilt_second))
        else:
            final_members.append((hdr, body))

    # Re-compute new offsets with ACTUAL rebuilt body sizes, then re-build linkers
    # a second time to get accurate offsets (linker bodies may have changed size).
    new_offsets_final = compute_new_offsets(final_members)
    offset_map2 = {}
    for new_pos, orig_idx in zip(new_offsets_final, kept_indices):
        old_off = members[orig_idx][0]
        offset_map2[old_off] = new_pos

    # Second rebuild pass (offsets now reflect actual final sizes)
    if first_linker_idx is not None:
        old_first_body = members[first_linker_idx][2]
        rebuilt_first = rebuild_first_linker(old_first_body, removed_set, offset_map2)

    if second_linker_idx is not None:
        old_second_body = members[second_linker_idx][2]
        rebuilt_second = rebuild_second_linker(old_second_body, removed_set, offset_map2)

    # Rebuild final_members with second-pass linker bodies
    final_members = []
    for orig_idx in kept_indices:
        off, hdr, body = members[orig_idx]
        if orig_idx == first_linker_idx and rebuilt_first is not None:
            final_members.append((hdr, rebuilt_first))
        elif orig_idx == second_linker_idx and rebuilt_second is not None:
            final_members.append((hdr, rebuilt_second))
        else:
            final_members.append((hdr, body))

    # ── Safety guard: refuse an implausibly shrunk archive ───────────────────
    # Independent of how atexit_indices was computed, if the rebuilt archive
    # lost most of its members or shrank drastically, something over-deleted.
    # Better to abort and keep the original (working) import lib than write
    # a near-empty one that fails 20+ minutes later in a downstream link.
    kept_member_count = len(final_members)

    # ── DIAGNOSTIC: kept-member count + resulting symbol count ──────────────
    # Mirrors the field the caller's "Total symbols" check inspects downstream
    # (post-write strings-based count), but computed here from the rebuilt
    # linker member(s) so we see it even if the guards below abort first.
    _diag_first_syms = None
    _diag_second_syms = None
    if rebuilt_first is not None and len(rebuilt_first) >= 4:
        _diag_first_syms = struct.unpack('>I', rebuilt_first[:4])[0]
    if rebuilt_second is not None and len(rebuilt_second) >= 4:
        _diag_sl_num_members = struct.unpack('<I', rebuilt_second[:4])[0]
        _diag_sl_syms_off = 4 + _diag_sl_num_members * 4
        if len(rebuilt_second) >= _diag_sl_syms_off + 4:
            _diag_second_syms = struct.unpack(
                '<I', rebuilt_second[_diag_sl_syms_off:_diag_sl_syms_off + 4])[0]
    print(
        f"STRIP_ATEXIT_DIAG: kept_member_count={kept_member_count} "
        f"(of {len(members)} original) "
        f"rebuilt_first_linker_symbol_count={_diag_first_syms} "
        f"rebuilt_second_linker_symbol_count={_diag_second_syms}",
        file=sys.stderr,
    )

    if kept_member_count < (len(members) - len(atexit_indices)):
        print(
            f"    ERROR: internal inconsistency — expected "
            f"{len(members) - len(atexit_indices)} kept members, got "
            f"{kept_member_count}. Aborting.",
            file=sys.stderr,
        )
        sys.exit(2)
    if len(data) > 0 and len(final_members) > 0:
        _shrink_ratio = 1.0 - (sum(len(b) for _, b in final_members) / len(data))
        if _shrink_ratio > 0.5:
            print(
                f"    ERROR: refusing to write — archive body would shrink "
                f"by {_shrink_ratio:.0%} (from {len(data):,} bytes), far "
                f"more than removing a single atexit thunk should cause. "
                f"Aborting to avoid producing a near-empty import library.",
                file=sys.stderr,
            )
            sys.exit(2)

    # Serialise
    new_data = write_ar(final_members)
    print(f"    new archive size: {len(new_data):,} bytes "
          f"(delta {len(new_data) - len(data):+,})", file=sys.stderr)

    # Write atomically via temp file in same directory
    tmp_path = path + '.tmp_py'
    try:
        with open(tmp_path, 'wb') as f:
            f.write(new_data)
        os.replace(tmp_path, path)
    except OSError as e:
        print(f"ERROR: cannot write {path}: {e}", file=sys.stderr)
        # Clean up temp file if it exists
        try:
            os.rename(tmp_path, '/tmp/_strip_atexit_tmp_write_fail')
        except OSError:
            pass
        sys.exit(2)

    print(f"    OK: wrote new archive, removed {len(atexit_indices)} atexit member(s)",
          file=sys.stderr)
    sys.exit(0)


main()
PYEOF
  _py_exit=$?

  if [[ ${_py_exit} -eq 2 ]]; then
    echo "    ERROR: python3 archive manipulation failed"
    _strip_restore
    mv "${_bak}" "/tmp/_strip_atexit_bak_$$" 2>/dev/null || true
    return 1
  elif [[ ${_py_exit} -eq 1 ]]; then
    echo "    WARNING: atexit detected by strings but not found in any member"
    echo "    (false positive from archive metadata — treating as clean)"
    mv "${_bak}" "/tmp/_strip_atexit_bak_$$" 2>/dev/null || true
    return 0
  fi
  # _py_exit == 0: atexit member(s) removed

  # ── Step 5: Verification ─────────────────────────────────────────────────────
  { set +x; } 2>/dev/null
  local _still_has_atexit=false
  if strings -a "${_implib}" 2>/dev/null | grep -qx 'atexit'; then
    _still_has_atexit=true
  fi
  set -x

  if ${_still_has_atexit}; then
    echo "    ERROR: atexit still present after python3 rewrite!"
    _strip_restore
    mv "${_bak}" "/tmp/_strip_atexit_bak_$$" 2>/dev/null || true
    return 1
  fi
  echo "    OK: atexit removed — import lib format preserved"

  # Remove backup
  mv "${_bak}" "/tmp/_strip_atexit_bak_$$" 2>/dev/null || true
  return 0
}
