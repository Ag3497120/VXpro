#!/usr/bin/env python3
# cr2w.py: a minimal reader of Cyberpunk 2077's CR2W files (as unpacked by rdscan -x): the name table and each export's
# properties (name, type, raw bytes), enough for a mesh's boneNames / boneRigMatrices and a rig's boneNames /
# boneParentIndexes / boneTransforms. Values are decoded for: CName, array:CName, Matrix, array:Matrix, Int16/32,
# array:Int16, Uint*, Float, Vector4, Quaternion, structs (recursively). Others are kept as bytes.
#   cr2w.py FILE [PROP ...]   prints the exports' classes and the named properties
import struct, sys

class CR2W:
    def __init__(self, data):
        self.d = d = data
        assert d[:4] == b'CR2W', 'not CR2W'
        hdr = struct.unpack_from('<IIIQIIII', d, 4)   # version flags timestamp build objectsEnd buffersEnd crc
        tables = [struct.unpack_from('<III', d, 40 + 12 * i) for i in range(10)]
        so, sn, _ = tables[0]; self.strings = d[so:so + sn]
        no, nn, _ = tables[1]
        self.names = []
        for i in range(nn):
            off, h = struct.unpack_from('<II', d, no + 8 * i)
            e = self.strings.index(b'\0', off); self.names.append(self.strings[off:e].decode('utf8', 'replace'))
        eo, en, _ = tables[4]
        self.exports = []
        for i in range(en):
            cls, flags, parent, size, off, tmpl, crc = struct.unpack_from('<HHIIIII', d, eo + 24 * i)
            self.exports.append((self.names[cls], off, size))

    def props(self, off, end):
        d = self.d; p = off + 1 if d[off] == 0 else off   # (a chunk begins with a zero byte)
        out = []
        while p + 2 <= end:
            ni = struct.unpack_from('<H', d, p)[0]
            if ni == 0: break
            ti, sz = struct.unpack_from('<HI', d, p + 2)
            if sz < 4: break
            out.append((self.names[ni], self.names[ti], p + 8, p + 4 + sz)); p += 4 + sz   # (size: itself + the value)
        return out

    def value(self, typ, a, b):
        d = self.d
        if typ == 'CName': return self.names[struct.unpack_from('<H', d, a)[0]]
        if typ in ('Int16', 'Uint16'): return struct.unpack_from('<h' if typ == 'Int16' else '<H', d, a)[0]
        if typ in ('Int32', 'Uint32'): return struct.unpack_from('<i' if typ == 'Int32' else '<I', d, a)[0]
        if typ in ('Uint8', 'Int8', 'Bool'): return d[a]
        if typ == 'Float': return struct.unpack_from('<f', d, a)[0]
        if typ in ('Uint64', 'Int64'): return struct.unpack_from('<Q' if typ == 'Uint64' else '<q', d, a)[0]
        if typ == 'Double': return struct.unpack_from('<d', d, a)[0]
        if typ.startswith('E') and b - a == 2: return self.names[struct.unpack_from('<H', d, a)[0]]   # (an enum: its value's name)
        if typ.startswith('array:'):
            n = struct.unpack_from('<I', d, a)[0]; et = typ[6:]; p = a + 4; out = []
            fixed = {'CName': 2, 'Int16': 2, 'Uint16': 2, 'Int32': 4, 'Uint32': 4, 'Float': 4, 'Uint8': 1, 'Int8': 1, 'Uint64': 8, 'Int64': 8, 'Bool': 1}
            for _ in range(n):
                if et in fixed: out.append(self.value(et, p, p + fixed[et])); p += fixed[et]
                else:   # (a struct: its property list, ending with a zero name)
                    q = p + 1; fields = {}   # (a struct: a zero byte, its properties, a zero name)
                    while True:
                        ni = struct.unpack_from('<H', d, q)[0]
                        if ni == 0: q += 2; break
                        ti, sz = struct.unpack_from('<HI', d, q + 2)
                        if sz < 4 or q + 4 + sz > len(d): raise ValueError('bad size')
                        fields[self.names[ni]] = self.value(self.names[ti], q + 8, q + 4 + sz); q += 4 + sz
                    out.append(fields); p = q
            return out
        # a struct value (Matrix, Vector4, Quaternion, ...): its property list
        fields = {}; q = a + 1 if d[a] == 0 else a
        try:
            while q + 2 <= b:
                ni = struct.unpack_from('<H', d, q)[0]
                if ni == 0: break
                ti, sz = struct.unpack_from('<HI', d, q + 2)
                if sz < 4 or q + 4 + sz > b: raise ValueError('bad size')
                fields[self.names[ni]] = self.value(self.names[ti], q + 8, q + 4 + sz); q += 4 + sz
        except (IndexError, struct.error, ValueError):
            return d[a:b]
        return fields if fields else d[a:b]

def matrix(m):   # a Matrix struct (X, Y, Z, W rows of Vector4) -> 4x4 list, rows
    return [[m.get(r, {}).get(c, 0.0) for c in 'XYZW'] for r in 'XYZW']

if __name__ == '__main__':
    c = CR2W(open(sys.argv[1], 'rb').read())
    want = set(sys.argv[2:])
    for cls, off, size in c.exports:
        print('export', cls, off, size)
        for name, typ, a, b in c.props(off, off + size):
            if want and name not in want: print('  ', name, typ, b - a); continue
            print('  ', name, typ, c.value(typ, a, b))
