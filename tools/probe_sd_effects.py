#!/usr/bin/env python3
# Dump raw effect.json + their material.json + shaders for the base image effects.
import struct, json, os

PKG = "/Users/a55555/Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/workshop/content/431960/3734696250/scene.pkg"

def read_pkg(path):
    d = open(path, 'rb').read(); off = 0
    def i32():
        nonlocal off; v = struct.unpack_from('<i', d, off)[0]; off += 4; return v
    mlen = i32(); off += mlen
    count = i32(); entries = []
    for _ in range(count):
        nlen = i32(); name = d[off:off+nlen].decode('utf-8','replace'); off += nlen
        o = i32(); sz = i32(); entries.append((name, o, sz))
    base = off
    return {name.replace('\\','/'): d[base+o:base+o+sz] for name,o,sz in entries}

files = read_pkg(PKG)
print("ALL FILE KEYS:")
for k in sorted(files.keys()):
    print("  ", k, len(files[k]))

def find(basename):
    bn = os.path.basename(basename)
    for k in files:
        if os.path.basename(k) == bn:
            return k
    return None

for ef in ['effects/waterflow/effect.json','effects/lightshafts/effect.json','effects/shake/effect.json','effects/blurradial/effect.json']:
    k = find(ef)
    print("\n========== ", ef, " key=", k)
    if k:
        ej = json.loads(files[k])
        print(json.dumps(ej, indent=1)[:2500])
