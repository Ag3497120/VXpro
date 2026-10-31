#!/usr/bin/env python3
# check_imports.py: every symbol a prepared (visionOS) image imports, looked up where visionOS's dyld will look: the
# library its ordinal names after macho_prepare.py (an SDK .tbd, following its re-exports, or one of our shims, built
# by shims/Makefile, with its re-exports). Prints the symbols nobody exports (a launch would fail on a non-weak one).
#   check_imports.py IMAGE... [--shims DIR[:DIR...]] [--sdk PATH]   (the shims and the prepared images' directories)
import argparse, os, re, subprocess, sys

def tbd_exports(path, seen):
    """Symbols of a .tbd for arm64-xros (all its documents: umbrella re-exports are separate documents)."""
    out = set()
    if path in seen or not os.path.exists(path):
        return out
    seen.add(path)
    text = open(path, errors='replace').read()
    for doc in text.split('--- !tapi-tbd')[1:] or [text]:
        targets = re.search(r'targets:\s*\[([^\]]*)\]', doc)
        if targets and 'xros' not in targets.group(1) and 'arm64' not in targets.group(1):
            continue
        for key in ('symbols', 'weak-symbols', 'thread-local-symbols'):
            for m in re.finditer(key + r':\s*\[([^\]]*)\]', doc):
                out.update(s.strip().strip("'\"") for s in m.group(1).split(','))
        for m in re.finditer(r'objc-classes:\s*\[([^\]]*)\]', doc):
            for c in m.group(1).split(','):
                c = c.strip().strip("'\"")
                out.update(('_OBJC_CLASS_$_' + c, '_OBJC_METACLASS_$_' + c))
        for m in re.finditer(r'objc-eh-types:\s*\[([^\]]*)\]', doc):
            out.update('_OBJC_EHTYPE_$_' + c.strip().strip("'\"") for c in m.group(1).split(','))
        for m in re.finditer(r'objc-ivars:\s*\[([^\]]*)\]', doc):
            out.update('_OBJC_IVAR_$_' + c.strip().strip("'\"") for c in m.group(1).split(','))
    return out

def sdk_path_for(install, sdk):
    p = sdk + install
    for cand in (p + '.tbd', re.sub(r'\.dylib$', '.tbd', p)):
        if os.path.exists(cand):
            return cand
    return None

def dylib_exports(path, sdk, shims, seen):
    """Exports of an install name or a built shim (with its re-exports)."""
    if path.startswith('@rpath/') or path.startswith('@executable_path/'):
        f = next((os.path.join(d, os.path.basename(path)) for d in shims.split(':') if os.path.exists(os.path.join(d, os.path.basename(path)))), '')
        if not f or f in seen:
            return set()
        seen.add(f)
        # (the exports trie: what dyld reads; a stripped image has no symbol table)
        out = set(l.split()[-1] for l in subprocess.run(['dyld_info', '-exports', f], capture_output=True, text=True).stdout.splitlines()
                  if l.strip().startswith('0x'))
        txt = subprocess.run(['otool', '-l', f], capture_output=True, text=True).stdout
        for m in re.finditer(r'cmd LC_REEXPORT_DYLIB\n\s+cmdsize \d+\n\s+name (\S+)', txt):
            out |= dylib_exports(m.group(1), sdk, shims, seen)
        return out
    t = sdk_path_for(path, sdk)
    if not t:
        return set()
    out = tbd_exports(t, seen)
    for m in re.finditer(r"reexported-libraries:\s*\n\s*- targets:[^\n]*\n\s*libraries:\s*\[([^\]]*)\]", open(t).read()):
        for lib in m.group(1).split(','):
            out |= dylib_exports(lib.strip().strip("'\""), sdk, shims, seen)
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('images', nargs='+')
    here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument('--shims', default=os.path.join(here, '..', 'build', 'xros'))
    ap.add_argument('--sdk', default=subprocess.run(['xcrun', '--sdk', 'xros', '--show-sdk-path'], capture_output=True, text=True).stdout.strip())
    a = ap.parse_args()
    bad = 0
    for img in a.images:
        libs = [l.split()[0] for l in subprocess.run(['otool', '-L', img], capture_output=True, text=True).stdout.splitlines()[1:]]
        ftype = subprocess.run(['otool', '-hv', img], capture_output=True, text=True).stdout
        if 'DYLIB' in ftype:                         # (a dylib's own id is among the lines: wherever its LC_ID_DYLIB is)
            idm = re.search(r'cmd LC_ID_DYLIB\n\s+cmdsize \d+\n\s+name (\S+)', subprocess.run(['otool', '-l', img], capture_output=True, text=True).stdout)
            if idm and idm.group(1) in libs:
                libs.remove(idm.group(1))
        cache = {}
        missing = {}
        for l in libs:                               # (every library must exist where dyld will look)
            if l.startswith('@'):
                ok = any(os.path.exists(os.path.join(d, os.path.basename(l))) for d in a.shims.split(':'))
            else:
                ok = sdk_path_for(l, a.sdk) is not None
            if not ok:
                missing.setdefault('(library not found: %s)' % l, []).append('-')
        for line in subprocess.run(['nm', '-mu', img], capture_output=True, text=True).stdout.splitlines():
            m = re.match(r'\s*\(undefined\) (weak )?external (\S+)(?: \(from (\S+)\))?', line)
            if not m:
                continue
            weak, sym, frm = m.group(1), m.group(2), m.group(3)
            lib = next((l for l in libs if frm and (os.path.basename(l).split('.')[0] in (frm, 'lib' + frm) or ('/%s.framework/' % frm) in l or l.endswith('/' + frm))), None)
            if lib is None:
                lib = next((l for l in libs if frm and frm.lower() in l.lower()), None)
            if lib is None:
                missing.setdefault('(%s: no library)' % frm, []).append(sym); continue
            if lib not in cache:
                cache[lib] = dylib_exports(lib, a.sdk, ':'.join(os.path.abspath(d) for d in a.shims.split(':')), set())
            if sym not in cache[lib]:
                missing.setdefault(lib + (' [weak]' if weak else ''), []).append(sym)
        print('== %s: %d libraries' % (img, len(libs)))
        for lib, syms in sorted(missing.items()):
            print('  %s: %d missing: %s' % (lib, len(syms), ' '.join(sorted(syms))))
            if '[weak]' not in lib:
                bad += len(syms)
    print('non-weak missing: %d' % bad)
    sys.exit(1 if bad else 0)

if __name__ == '__main__':
    main()
