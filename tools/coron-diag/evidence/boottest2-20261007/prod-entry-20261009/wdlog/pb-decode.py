#!/usr/bin/env python3
"""Generic protobuf wire-format decoder for Studio RPC replies.
usage: pb-decode.py <studio-rpc.sh out-file>
Splits the received bytes into frames (SOF 0xAB .. EOF 0xAD, ESC 0xAC), un-escapes, and prints each
frame as a nested field tree: length-delimited fields are decoded as sub-messages when they parse
cleanly, else shown as bytes/str. Field numbers are matched against the .proto files by hand."""
import sys, re

SOF, ESC, EOF = 0xAB, 0xAC, 0xAD


def frames(data):
    out, cur, esc, inside = [], [], False, False
    for b in data:
        if esc:
            cur.append(b); esc = False; continue
        if b == SOF:
            cur, inside = [], True
        elif b == ESC:
            esc = True
        elif b == EOF:
            if inside:
                out.append(bytes(cur))
            cur, inside = [], False
        elif inside:
            cur.append(b)
    return out


def varint(buf, i):
    v, s = 0, 0
    while True:
        b = buf[i]; i += 1
        v |= (b & 0x7F) << s; s += 7
        if not (b & 0x80):
            return v, i


def parse(buf):
    """Return list of (field, wiretype, value) or None if not a clean message."""
    i, out = 0, []
    try:
        while i < len(buf):
            key, i = varint(buf, i)
            f, wt = key >> 3, key & 7
            if f == 0:
                return None
            if wt == 0:
                v, i = varint(buf, i)
            elif wt == 2:
                ln, i = varint(buf, i)
                if i + ln > len(buf):
                    return None
                v = buf[i:i + ln]; i += ln
            elif wt == 5:
                v = int.from_bytes(buf[i:i + 4], 'little'); i += 4
            elif wt == 1:
                v = int.from_bytes(buf[i:i + 8], 'little'); i += 8
            else:
                return None
            out.append((f, wt, v))
    except IndexError:
        return None
    return out


def show(buf, depth):
    fields = parse(buf)
    pad = '  ' * depth
    for f, wt, v in fields:
        if wt == 2:
            sub = parse(v) if len(v) > 0 else None
            printable = all(32 <= c < 127 for c in v) and len(v) > 0
            if sub is not None and not (printable and len(v) < 4):
                print(f'{pad}{f}: {{  # {len(v)} bytes')
                show(v, depth + 1)
                print(f'{pad}}}')
            elif printable:
                print(f'{pad}{f}: "{v.decode()}"')
            else:
                print(f'{pad}{f}: bytes {v.hex(" ")}')
        else:
            print(f'{pad}{f}: {v} (0x{v:x})')


def main():
    t = open(sys.argv[1], encoding='utf-8', errors='replace').read()
    m = re.search(r'^RPC recv (\d+) bytes: (.*)$', t, re.M) or re.search(r'^PROBE recv (\d+) bytes: (.*)$', t, re.M)
    if not m:
        print('no recv line'); return
    data = bytes.fromhex(m.group(2).replace(' ', ''))
    fr = frames(data)
    print(f'{len(fr)} frame(s)')
    for n, f in enumerate(fr):
        print(f'--- frame {n} ({len(f)} bytes)')
        if parse(f) is None:
            print('  (not a clean message) ' + f.hex(' '))
        else:
            show(f, 1)


main()
