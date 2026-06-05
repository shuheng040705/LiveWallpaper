#!/usr/bin/env python3
# Dump every particle layer of a scene: object origin/scale/angles, emitter, sizerandom, velocity, material+texture.
import struct, os, json, sys
ROOT = "/Users/a55555/Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/workshop/content/431960"
def read_pkg(path):
    d = open(path,'rb').read(); off=0
    def i32():
        nonlocal off; v=struct.unpack_from('<i',d,off)[0]; off+=4; return v
    mlen=i32(); off+=mlen; count=i32(); ents=[]
    for _ in range(count):
        nlen=i32(); name=d[off:off+nlen].decode('utf-8','replace'); off+=nlen
        o=i32(); sz=i32(); ents.append((name,o,sz))
    base=off
    return {n.replace('\\','/'):d[base+o:base+o+sz] for n,o,sz in ents}
for tid in sys.argv[1:]:
    pkg=os.path.join(ROOT,tid,"scene.pkg")
    if not os.path.exists(pkg): print(tid,"NO pkg"); continue
    files=read_pkg(pkg)
    sj=json.loads(next(files[k] for k in files if k.endswith('scene.json')))
    print(f"\n###### {tid}  canvas? ######")
    for o in sj.get('objects',[]):
        pp=o.get('particle')
        if not pp: continue
        pk=next((k for k in files if os.path.basename(k)==os.path.basename(pp)), None)
        pj=json.loads(files[pk]) if pk else {}
        em=(pj.get('emitter') or [{}])[0]
        sz=next((i for i in (pj.get('initializer') or []) if i.get('name')=='sizerandom'), {})
        vr=next((i for i in (pj.get('initializer') or []) if i.get('name')=='velocityrandom'), {})
        ops=[op.get('name') for op in (pj.get('operator') or [])]
        grav=next((op.get('gravity') for op in (pj.get('operator') or []) if op.get('name')=='movement'), None)
        mat=None; tex=None
        mp=pj.get('material')
        if mp:
            mk=next((k for k in files if os.path.basename(k)==os.path.basename(mp)),None)
            if mk:
                m=json.loads(files[mk]); p0=m['passes'][0]; tex=p0.get('textures'); mat=p0.get('blending')
        print(f"  obj id={o.get('id')} name={json.dumps(o.get('name'),ensure_ascii=False)} vis={json.dumps(o.get('visible'))}")
        print(f"    origin={o.get('origin')} scale={o.get('scale')} angles={o.get('angles')}")
        io=o.get('instanceoverride')
        if io: print(f"    instanceoverride={ {k:io[k] for k in io if k not in ('id',)} }")
        print(f"    emitter={json.dumps(em)}")
        print(f"    sizerandom min={sz.get('min')} max={sz.get('max')}  maxcount={pj.get('maxcount')} starttime={pj.get('starttime')}")
        print(f"    velocityrandom min={vr.get('min')} max={vr.get('max')}  gravity={grav}  ops={ops}")
        print(f"    renderer={json.dumps(pj.get('renderer'))}  mat.blend={mat} tex={tex}")
