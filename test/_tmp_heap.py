#!/usr/bin/env python3
"""一次性排查脚本：正规解析 .NET 的 #US 字符串堆，
按真实条目起始偏移定位字符串，再用它对 IL 里的 ldstr token。"""
import struct, sys
import dnfile

path, want = sys.argv[1], sys.argv[2]
pe = dnfile.dnPE(path)
us = pe.net.metadata.streams.get(b'#US')
ud = us.__data__ if hasattr(us, '__data__') else us.get_data()


def entries():
    """产出 (堆偏移, 字符串) 对。"""
    i = 1  # 堆首字节是空串
    n = len(ud)
    while i < n:
        b = ud[i]
        if b == 0:
            i += 1
            continue
        if b & 0x80:
            if i + 1 >= n:
                break
            ln = ((b & 0x7f) << 8) | ud[i + 1]
            start = i + 2
        else:
            ln = b
            start = i + 1
        if ln == 0 or start + ln > n:
            i += 1
            continue
        try:
            yield i, ud[start:start + ln].decode('utf-16le')
        except Exception:
            pass
        i = start + ln + 1  # 结尾还有一个终结字节


hits = [(off, s) for off, s in entries() if want in s]
print('含 %r 的堆条目：' % want)
for off, s in hits[:10]:
    print('   偏移 %s  %r' % (hex(off), s))
if not hits:
    sys.exit(0)

tok = 0x70000000 | hits[0][0]
print('\n用第一个做 token:', hex(tok))


def s_at(t):
    o = t - 0x70000000
    if o < 0 or o >= len(ud):
        return None
    b = ud[o]
    if b & 0x80:
        ln = ((b & 0x7f) << 8) | ud[o + 1]
        raw = ud[o + 2:o + 2 + ln]
    else:
        raw = ud[o + 1:o + 1 + b]
    try:
        return raw.decode('utf-16le')
    except Exception:
        return None


def code_of(rva):
    b = pe.get_data(rva, 1)[0]
    if (b & 3) == 2:
        return pe.get_data(rva + 1, b >> 2)
    if (b & 3) == 3:
        hdr = pe.get_data(rva, 12)
        return pe.get_data(rva + 12, struct.unpack('<I', hdr[4:8])[0])
    return b''


def rows_of(c):
    return c.rows if hasattr(c, 'rows') else c


tb = b'\x72' + struct.pack('<I', tok)
print('\n引用它的方法：')
for ty in rows_of(pe.net.mdtables.TypeDef):
    if not ty.MethodList:
        continue
    for m in rows_of(ty.MethodList):
        row = getattr(m, 'row', m)
        if not getattr(row, 'Rva', 0):
            continue
        body = code_of(row.Rva)
        if tb in body:
            print('\n=== %s.%s :: %s (%d 字节)' % (ty.TypeNamespace, ty.TypeName, row.Name, len(body)))
            seen = []
            for i in range(len(body) - 5):
                if body[i] == 0x72:
                    s = s_at(struct.unpack('<I', body[i + 1:i + 5])[0])
                    if s and s.strip() and s not in seen:
                        seen.append(s)
            for s in seen:
                print('     ', repr(s))
