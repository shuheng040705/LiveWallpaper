#!/usr/bin/env python3
# Extract particle JSON definitions using a 'rope'/'ropetrail' renderer from scene.pkg files,
# plus the scene-object that references them (to learn controlpoint/binding/origin/texture).
import struct, glob, os, json, sys

ROOT = "/Users/a55555/Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/workshop/content/431960"

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

targets = sys.argv[1:] or ["3713659808","3680422061","3440483127","3470764447","3233141951"]
for tid in targets:
    pkg = os.path.join(ROOT, tid, "scene.pkg")
    if not os.path.exists(pkg):
        print(f"## {tid}: NO scene.pkg"); continue
    files = read_pkg(pkg)
    # find particle json files
    pjsons = {}
    for k,v in files.items():
        if k.endswith('.json') and ('particle' in k.lower()):
            try: pjsons[k] = json.loads(v)
            except: pass
    # which particle defs use rope?
    rope_files = {}
    for k,pj in pjsons.items():
        rends = pj.get('renderer')
        if isinstance(rends, list):
            for r in rends:
                if isinstance(r, dict) and r.get('name') in ('rope','ropetrail'):
                    rope_files[k] = pj
    print(f"\n########## {tid}: {len(rope_files)} rope particle file(s) ##########")
    for k,pj in rope_files.items():
        print(f"\n--- particle file: {k} ---")
        print("  renderer:", json.dumps(pj.get('renderer')))
        print("  controlpoint:", json.dumps(pj.get('controlpoint')))
        print("  emitter:", json.dumps(pj.get('emitter')))
        print("  maxcount:", pj.get('maxcount'), " starttime:", pj.get('starttime'),
              " animationmode:", pj.get('animationmode'))
        inits = [(i.get('name')) for i in (pj.get('initializer') or [])]
        ops = [(o.get('name')) for o in (pj.get('operator') or [])]
        print("  initializers:", inits)
        print("  operators:", ops)
        print("  material:", pj.get('material'))
        # material textures + blending
        mp = pj.get('material')
        if mp:
            mk = next((kk for kk in files if os.path.basename(kk)==os.path.basename(mp)), None)
            if mk:
                try:
                    mat = json.loads(files[mk]); ps0 = mat['passes'][0]
                    print("    mat.pass0.blending:", ps0.get('blending'),
                          " shader:", ps0.get('shader'),
                          " textures:", ps0.get('textures'),
                          " combos:", ps0.get('combos'))
                except Exception as e: print("    mat parse err", e)
    # find scene objects referencing these particle files
    sj_key = next((kk for kk in files if kk.endswith('scene.json')), None)
    if sj_key:
        sj = json.loads(files[sj_key])
        for o in sj.get('objects', []):
            pp = o.get('particle')
            if pp and any(os.path.basename(pp)==os.path.basename(rf) for rf in rope_files):
                print(f"\n  >> scene object using rope particle '{pp}':")
                for fld in ['id','name','origin','scale','angles','visible','particle','instanceoverride','color']:
                    if fld in o: print(f"     {fld}: {json.dumps(o[fld])}")
