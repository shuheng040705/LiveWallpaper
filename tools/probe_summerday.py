#!/usr/bin/env python3
# Unpack 3734696250 Summer Day scene.pkg fresh; dump objects + base image effects + materials/shaders/textures.
import struct, json, os, sys

PKG = "/Users/a55555/Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/workshop/content/431960/3734696250/scene.pkg"

def safe(s):
    return ''.join(c if (32 <= ord(c) < 127) else '?' for c in s)

def read_pkg(path):
    d = open(path, 'rb').read(); off = 0
    def i32():
        nonlocal off; v = struct.unpack_from('<i', d, off)[0]; off += 4; return v
    mlen = i32(); magic = d[off:off+mlen].decode('utf-8','replace'); off += mlen
    count = i32(); entries = []
    for _ in range(count):
        nlen = i32(); name = d[off:off+nlen].decode('utf-8','replace'); off += nlen
        o = i32(); sz = i32(); entries.append((name, o, sz))
    base = off
    return magic, {name.replace('\\','/'): d[base+o:base+o+sz] for name,o,sz in entries}

magic, files = read_pkg(PKG)
print("MAGIC", safe(magic), "FILES", len(files))

def find(basename):
    for k in files:
        if os.path.basename(k) == os.path.basename(basename):
            return k
    return None

sj_key = next(k for k in files if k.endswith('scene.json'))
sj = json.loads(files[sj_key])
op = sj.get('general',{}).get('orthogonalprojection')
print("ORTHO", op)
objs = sj.get('objects', [])
print("OBJ_COUNT", len(objs))
for i,o in enumerate(objs):
    kind = 'image' if 'image' in o else ('particle' if 'particle' in o else '?')
    print(f"--- OBJ[{i}] id={o.get('id')} name={safe(str(o.get('name','')))} kind={kind} "
          f"size={o.get('size')} origin={o.get('origin')} scale={o.get('scale')} "
          f"angles={o.get('angles')} visible={o.get('visible')}")
    effs = o.get('effects', [])
    if effs:
        print(f"    EFFECTS x{len(effs)}")
        for j,e in enumerate(effs):
            print(f"      EFF[{j}] name={safe(str(e.get('name','')))} file={e.get('file')} "
                  f"visible={e.get('visible')} id={e.get('id')}")
            # effect.json
            ef = e.get('file')
            efk = find(ef) if ef else None
            if efk:
                ej = json.loads(files[efk])
                print(f"         effect.json keys={sorted(ej.keys())}")
                print(f"         effect name={safe(str(ej.get('name','')))}")
                passes = ej.get('passes', [])
                for pi,pp in enumerate(passes):
                    print(f"         pass[{pi}] material={pp.get('material')} keys={sorted(pp.keys())}")
            # per-object effect override constantshadervalues / passes
            for pi,pp in enumerate(e.get('passes', [])):
                csv = pp.get('constantshadervalues', {})
                tx = pp.get('textures')
                print(f"         OBJ-EFF pass[{pi}] csv={json.dumps(csv)} textures={tx}")

print("\n===== writing detailed dump for base image (obj with most effects) =====")
# base image = the image object that has effects
base = None
for o in objs:
    if 'image' in o and o.get('effects'):
        base = o; break
if base is None:
    base = next(o for o in objs if 'image' in o)
print("BASE id", base.get('id'), "name", safe(str(base.get('name',''))))
