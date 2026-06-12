#!/usr/bin/env python3
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

def exact(path):
    for k in files:
        if k == path:
            return k
    return None

# effect.json per dir (exact path)
for ef in ['effects/waterflow/effect.json','effects/lightshafts/effect.json','effects/shake/effect.json','effects/blurradial/effect.json']:
    k = exact(ef)
    print("\n==== effect.json", ef, "->", k)
    if k:
        ej = json.loads(files[k])
        print("  replacementkey:", ej.get('replacementkey'), " passes-material:",
              [p.get('material') for p in ej.get('passes',[])])

for mat in ['materials/effects/waterflow.json','materials/effects/lightshafts.json',
            'materials/effects/shake.json','materials/effects/blur_radial_gaussian.json']:
    k = exact(mat)
    print("\n#### MATERIAL", mat)
    if k:
        print(files[k].decode('utf-8','replace'))

print("\n\n========== waterflow.frag ==========")
print(files[exact('shaders/effects/waterflow.frag')].decode('utf-8','replace'))
print("\n\n========== waterflow.vert ==========")
print(files[exact('shaders/effects/waterflow.vert')].decode('utf-8','replace'))
print("\n\n========== shake.frag ==========")
print(files[exact('shaders/effects/shake.frag')].decode('utf-8','replace'))
print("\n\n========== shake.vert ==========")
print(files[exact('shaders/effects/shake.vert')].decode('utf-8','replace'))
