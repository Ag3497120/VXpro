#!/usr/bin/env python3
# macho_prepare.py: copy a macOS arm64 Mach-O for VX Mac Host (visionOS) and change only its load commands in the copy:
#   - LC_BUILD_VERSION: platform macOS -> visionOS (minos/sdk 26.0), so visionOS's dyld loads it;
#   - LC_LOAD_DYLIB / LC_ID_DYLIB / LC_RPATH paths: macOS layouts (Versions/A, ../Frameworks) to visionOS's, and the
#     libraries visionOS lacks (AppKit, Cocoa, Carbon, libcurl, the display parts of CoreGraphics/IOKit) to our shims
# #     (libvxkit, libvxcg, libvxmtl, ...: SHIMMED below) which re-export the real frameworks and add what is missing;
#   - the code signature is removed (the app build signs the copy with the user's own team);
#   - --as-dylib (the main executable): MH_EXECUTE -> MH_DYLIB, so VX Mac Host can load it (dyld refuses to dlopen an
#     executable) and call its entry point on a thread of its own while UIKit keeps the main thread: __PAGEZERO,
#     LC_MAIN and LC_LOAD_DYLINKER removed (the chained-fixup starts lose PAGEZERO's empty entry), LC_ID_DYLIB added in
#     the header's padding; the entry point's offset goes into the manifest and <name>.vxmac.plist beside the copy.
# Nothing else (except --pool-patch, below): no byte of code or data changes (each new path fits the command's existing
# size; the rest of the command is zero-filled as the linker leaves it). The source is never written; its SHA-256 is
# printed and recorded.
#
#   macho_prepare.py SRC DST [--system-shim] [--pool-patch] [--as-dylib] [--platform xros|xrsim|macos] [--json m.json] [--check]
#   --check: print what would change, write nothing. --platform macos: keep macOS (a Mac test of --as-dylib);
#   xrsim: the visionOS simulator (a Mac run of the whole route, the game's data read in place).
import argparse, hashlib, json, os, shutil, struct, subprocess, sys

LC_REQ_DYLD = 0x80000000
LC_LOAD_DYLIB, LC_ID_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LAZY_LOAD_DYLIB, LC_LOAD_UPWARD_DYLIB = \
    0xc, 0xd, 0x18 | LC_REQ_DYLD, 0x1f | LC_REQ_DYLD, 0x20, 0x23 | LC_REQ_DYLD
LC_RPATH, LC_BUILD_VERSION, LC_CODE_SIGNATURE, LC_VERSION_MIN_MACOSX = 0x1c | LC_REQ_DYLD, 0x32, 0x1d, 0x24
LC_SEGMENT_64, LC_MAIN, LC_LOAD_DYLINKER, LC_DYLD_CHAINED_FIXUPS = 0x19, 0x28 | LC_REQ_DYLD, 0xe, 0x34 | LC_REQ_DYLD
MH_EXECUTE, MH_DYLIB, MH_PIE = 2, 6, 0x200000
DYLIB_CMDS = {LC_LOAD_DYLIB: 'load', LC_ID_DYLIB: 'id', LC_LOAD_WEAK_DYLIB: 'weak', LC_REEXPORT_DYLIB: 'reexport',
              LC_LAZY_LOAD_DYLIB: 'lazy', LC_LOAD_UPWARD_DYLIB: 'upward'}
PLATFORM_MACOS, PLATFORM_XROS, PLATFORM_XROS_SIM = 1, 11, 12
VER_26 = 26 << 16

# The shims (VXMac/shims): one library per macOS library, so no image names one path twice (dyld refuses a duplicate
# linked dylib). Each re-exports the visionOS framework of the same name where there is one and adds what is missing.
SHIMMED = {
    'AppKit': '@rpath/libvxkit.dylib', 'Cocoa': '@rpath/libvxcocoa.dylib', 'Carbon': '@rpath/libvxcarbon.dylib',
    'CoreGraphics': '@rpath/libvxcg.dylib', 'IOKit': '@rpath/libvxiokit.dylib', 'Security': '@rpath/libvxsec.dylib',
    'GameKit': '@rpath/libvxgk.dylib', 'Metal': '@rpath/libvxmtl.dylib', 'MetalFX': '@rpath/libvxmtlfx.dylib',
    'AudioUnit': '@rpath/libvxaudiounit.dylib',   # (headers only on visionOS: AudioToolbox has it; Bink links it)
}
LIBS = {
    '/usr/lib/libcurl.4.dylib': '@rpath/libvxcurl.dylib',
}
SHIM_SYSTEM = '@rpath/libvxsystem.dylib'    # (libSystem + syslog$DARWIN_EXTSN: --system-shim)


# Pool-size patch for the main executable (the user approved it for the WORKSPACE COPY only; the App Store bundle is
# never written). Cyberpunk 2077 2.3.2 (Mac App Store), Contents/MacOS/Cyberpunk2077, SHA-256 below: the engine's
# memory pools reserve fixed address ranges whose sizes are immediates in the code (`movz xN, #imm, lsl #..`), 64+32+16
# GB plus a 4 GB range per linear pool: far beyond a visionOS app's address space. Same change as the Windows route
# (avp-port VXRuntime/src/game_patch.h, cyberpunk_pools): 16->8, 64->16, 32->8 GB, every 4 GB pool -> 1 GB. Pools
# commit from their start up (bump allocators), so a smaller range holds what the game uses.
# Each entry: (file offset, the 4-byte instruction expected there, the instruction written, what). Only these size
# instructions are recorded (no other byte of the game). Any expected word not found, or another SHA-256: refused.
#   0x10000fdc0  builds the three large pools' descriptors (Windows exe+0x260dc48)
#   0x100013398  DynamicLinearAllocator constructor: descriptor {allocator, granularity, flags, size}; all its 12
#                call sites pass 4 GB (0x1015fcbd0 makes three: Windows exe+0x68bd5d)
#   0x100014144  a pool constructor reserving 4 GB itself;  0x100e43afc  a 4 GB descriptor for the 0x10000cff0 pool
def _movz(rd, imm16, hw):
    return 0xd2800000 | (hw << 21) | (imm16 << 5) | rd
_G4, _G1 = (1, 2), (0x4000, 1)          # (imm16, hw): 4 GB = #1 lsl 32, 1 GB = #0x4000 lsl 16
POOL_PATCH_SHA256 = '3907f316f6adf9dd8188be82aeea9ae161445b2e1f6d25cf08c87b8a3ae6b421'
POOL_PATCHES = [
    (0x0000fde8, _movz(8, 4, 2), _movz(8, 2, 2), 'large pool 16 GB -> 8 GB'),
    (0x0000fe28, _movz(9, 0x10, 2), _movz(9, 4, 2), 'large pool 64 GB -> 16 GB'),
    (0x0000fe6c, _movz(9, 8, 2), _movz(9, 2, 2), 'large pool 32 GB -> 8 GB'),
    (0x00014170, _movz(1, *_G4), _movz(1, *_G1), 'pool (ctor 0x100014144) 4 GB -> 1 GB'),
    (0x00e43b0c, _movz(8, *_G4), _movz(8, *_G1), 'pool (0x100e43afc, 0x10000cff0 kind) 4 GB -> 1 GB'),
    (0x015fcbfc, _movz(22, *_G4), _movz(22, *_G1), 'three linear pools 4 GB -> 1 GB'),
] + [(o, _movz(8, *_G4), _movz(8, *_G1), 'linear pool 4 GB -> 1 GB') for o in (
    0x014f2e48, 0x01d23cb4, 0x02b13768, 0x02b13808, 0x02b147f0, 0x037cac30, 0x037cacb0, 0x03a316a0, 0x03a31e24)]


POOL_CORE = (0x0000fde8, 0x0000fe28, 0x0000fe6c, 0x015fcbfc)   # (--pool-patch-set core: the large three and the three linear pools, the Windows route's verified sites)


def pool_patch(buf, digest, which='all'):
    if digest != POOL_PATCH_SHA256:
        raise SystemExit('--pool-patch: SHA-256 %s is not Cyberpunk2077 2.3.2 (Mac App Store) %s: refused'
                         % (digest, POOL_PATCH_SHA256))
    patches = [p for p in POOL_PATCHES if which == 'all' or p[0] in POOL_CORE]
    for off, old, new, what in patches:
        got = struct.unpack_from('<I', buf, off)[0]
        if got != old:
            raise SystemExit('--pool-patch: %#x holds %#010x, not %#010x: refused' % (off, got, old))
    out = []
    for off, old, new, what in patches:
        struct.pack_into('<I', buf, off, new)
        out.append({'cmd': 'pool_patch', 'off': hex(off), 'what': what})
    return out


def map_path(p, image):
    """The visionOS path for a macOS install name, or None to keep it."""
    if p in LIBS:
        return LIBS[p]
    if p.startswith('/System/Library/Frameworks/'):
        fw = p.split('/')[4].split('.framework')[0]
        if fw in SHIMMED:
            return SHIMMED[fw]
        return '/System/Library/Frameworks/%s.framework/%s' % (fw, fw)   # flat bundle layout on visionOS
    if p == '/usr/lib/libSystem.B.dylib' and image.get('system_shim'):
        return SHIM_SYSTEM
    if p.startswith('@executable_path/../Frameworks/'):
        return '@executable_path/Frameworks/' + p[len('@executable_path/../Frameworks/'):]
    if p.startswith('@loader_path/../Frameworks/'):
        return '@executable_path/Frameworks/' + p[len('@loader_path/../Frameworks/'):]
    return None


def map_rpath(p):
    if p in ('@executable_path/../Frameworks', '@loader_path/../Frameworks'):
        return '@executable_path/Frameworks'
    return None


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for b in iter(lambda: f.read(1 << 22), b''):
            h.update(b)
    return h.hexdigest()


def edit(buf, image):
    magic, cpu, sub, ftype, ncmds, sizeofcmds, flags, _ = struct.unpack_from('<IiiIIIII', buf, 0)
    if magic != 0xfeedfacf or cpu != 0x0100000c:
        raise SystemExit('not a 64-bit arm64 Mach-O (fat files: thin them first with lipo)')
    changes, off = [], 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', buf, off)
        if cmd in DYLIB_CMDS or cmd == LC_RPATH:
            name_off = struct.unpack_from('<I', buf, off + 8)[0]
            end = buf.index(b'\0', off + name_off)
            old = buf[off + name_off:end].decode()
            new = map_rpath(old) if cmd == LC_RPATH else map_path(old, image)
            if image.get('platform', 'xros') == 'macos':
                new = None                     # (a Mac test: the paths stay)
            if new and new != old:
                room = size - name_off - 1
                if len(new) > room:
                    raise SystemExit('%s: "%s" does not fit (%d > %d bytes)' % (DYLIB_CMDS.get(cmd, 'rpath'), new, len(new), room))
                buf[off + name_off:off + size] = new.encode() + b'\0' * (size - name_off - len(new))
                changes.append({'cmd': DYLIB_CMDS.get(cmd, 'rpath'), 'old': old, 'new': new})
            else:
                changes.append({'cmd': DYLIB_CMDS.get(cmd, 'rpath'), 'old': old, 'kept': True})
        elif cmd == LC_BUILD_VERSION:
            platform, minos, sdk = struct.unpack_from('<III', buf, off + 8)
            if platform not in (PLATFORM_MACOS, PLATFORM_XROS, PLATFORM_XROS_SIM):
                raise SystemExit('unexpected platform %d' % platform)
            if image.get('platform', 'xros') in ('xros', 'xrsim'):
                to = PLATFORM_XROS if image.get('platform', 'xros') == 'xros' else PLATFORM_XROS_SIM
                struct.pack_into('<III', buf, off + 8, to, VER_26, VER_26)
                changes.append({'cmd': 'build_version', 'old': [platform, minos >> 16, sdk >> 16], 'new': [to, 26, 26]})
        elif cmd == LC_VERSION_MIN_MACOSX:
            raise SystemExit('LC_VERSION_MIN_MACOSX: not handled (no such image in this game)')
        off += size
    return changes


def as_dylib(buf, install_name):
    """MH_EXECUTE -> MH_DYLIB in place (see the top). Returns (changes, entry offset)."""
    magic, cpu, sub, ftype, ncmds, sizeofcmds, flags, _ = struct.unpack_from('<IiiIIIII', buf, 0)
    if ftype != MH_EXECUTE:
        raise SystemExit('--as-dylib: not an executable')
    cmds, off = [], 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', buf, off)
        cmds.append((cmd, bytes(buf[off:off + size])))
        off += size
    first_sect = min(struct.unpack_from('<I', buf, o + 48)[0] for o in _section_offsets(buf) if struct.unpack_from('<I', buf, o + 48)[0])
    keep, entry, seg_index, dropped_seg = [], None, 0, None
    for cmd, raw in cmds:
        if cmd == LC_SEGMENT_64:
            name = raw[8:24].rstrip(b'\0').decode()
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from('<QQQQ', raw, 24)
            if name == '__PAGEZERO':
                if filesize or struct.unpack_from('<I', raw, 64)[0]:
                    raise SystemExit('--as-dylib: __PAGEZERO has contents')
                dropped_seg = seg_index
                seg_index += 1
                continue
            seg_index += 1
        elif cmd == LC_MAIN:
            entry, stack = struct.unpack_from('<QQ', raw, 8)
            continue
        elif cmd == LC_LOAD_DYLINKER:
            continue
        keep.append((cmd, raw))
    if entry is None or dropped_seg != 0:
        raise SystemExit('--as-dylib: no LC_MAIN, or __PAGEZERO is not the first segment')
    name = install_name.encode() + b'\0'
    idsize = (24 + len(name) + 7) & ~7
    idcmd = struct.pack('<IIIIII', LC_ID_DYLIB, idsize, 24, 2, 0x10000, 0x10000) + name
    idcmd += b'\0' * (idsize - len(idcmd))
    keep.append((LC_ID_DYLIB, idcmd))
    blob = b''.join(r for _, r in keep)
    if 32 + len(blob) > first_sect:
        raise SystemExit('--as-dylib: the load commands do not fit before the first section')
    buf[32:32 + sizeofcmds] = b'\0' * sizeofcmds
    buf[32:32 + len(blob)] = blob
    struct.pack_into('<III', buf, 12, MH_DYLIB, len(keep), len(blob))
    struct.pack_into('<I', buf, 24, flags & ~MH_PIE)
    # the chained fixups' per-segment starts: drop __PAGEZERO's (empty) entry, as segment indices moved down by one
    off = 32
    for cmd, raw in keep:
        if cmd == LC_DYLD_CHAINED_FIXUPS:
            dataoff = struct.unpack_from('<I', raw, 8)[0]
            starts = dataoff + struct.unpack_from('<I', buf, dataoff + 4)[0]
            seg_count = struct.unpack_from('<I', buf, starts)[0]
            offs = list(struct.unpack_from('<%dI' % seg_count, buf, starts + 4))
            if offs[0] != 0:
                raise SystemExit('--as-dylib: __PAGEZERO has fixups')
            struct.pack_into('<I', buf, starts, seg_count - 1)
            struct.pack_into('<%dI' % seg_count, buf, starts + 4, *(offs[1:] + [0]))
    return ([{'cmd': 'as_dylib', 'id': install_name, 'removed': ['__PAGEZERO', 'LC_MAIN', 'LC_LOAD_DYLINKER'],
              'entry_offset': entry}], entry)


def _section_offsets(buf):
    ncmds = struct.unpack_from('<I', buf, 16)[0]
    off = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', buf, off)
        if cmd == LC_SEGMENT_64:
            for k in range(struct.unpack_from('<I', buf, off + 64)[0]):
                yield off + 72 + 80 * k
        off += size


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('src'); ap.add_argument('dst')
    ap.add_argument('--system-shim', action='store_true', help='libSystem through libvxsystem (it re-exports libSystem)')
    ap.add_argument('--pool-patch', action='store_true', help='main executable only: the pool sizes (POOL_PATCHES)')
    ap.add_argument('--pool-patch-set', choices=['all', 'core'], default='all', help='all (default) or core (POOL_CORE only: an A/B)')
    ap.add_argument('--as-dylib', metavar='INSTALL_NAME', help='the main executable as a dylib (e.g. @rpath/Cyberpunk2077.dylib)')
    ap.add_argument('--platform', choices=['xros', 'xrsim', 'macos'], default='xros')
    ap.add_argument('--json'); ap.add_argument('--check', action='store_true')
    a = ap.parse_args()
    if os.path.realpath(a.src) == os.path.realpath(a.dst):
        raise SystemExit('refusing to write the source')
    digest = sha256(a.src)
    buf = bytearray(open(a.src, 'rb').read())
    changes = edit(buf, {'system_shim': a.system_shim, 'platform': a.platform})
    if a.pool_patch:
        changes += pool_patch(buf, digest, a.pool_patch_set)
    entry = None
    if a.as_dylib:
        c, entry = as_dylib(buf, a.as_dylib)
        changes += c
    rec = {'src': a.src, 'sha256': digest, 'size': len(buf), 'dst': a.dst, 'changes': changes}
    if not a.check:
        os.makedirs(os.path.dirname(os.path.abspath(a.dst)), exist_ok=True)
        tmp = a.dst + '.tmp'
        with open(tmp, 'wb') as f:
            f.write(buf)
        os.chmod(tmp, 0o755)
        # (the old signature no longer matches the edited header; the app build signs the copy with the user's team)
        subprocess.run(['codesign', '--remove-signature', tmp], check=True)
        os.replace(tmp, a.dst)
        rec['dst_sha256'] = sha256(a.dst)
        if entry is not None:
            import plistlib
            stem = os.path.basename(a.dst).rsplit('.dylib', 1)[0]
            with open(os.path.join(os.path.dirname(os.path.abspath(a.dst)), stem + '.vxmac.plist'), 'wb') as f:
                plistlib.dump({'image': os.path.basename(a.dst), 'entry_offset': entry, 'source_sha256': digest}, f)
    out = json.dumps(rec, indent=1)
    if a.json:
        open(a.json, 'w').write(out)
    print(out)


if __name__ == '__main__':
    main()
