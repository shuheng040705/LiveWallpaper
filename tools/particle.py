#!/usr/bin/env python3
# 逆向 WE 粒子 JSON 格式:dump 几个真实 particle preset 的完整结构。
import struct, glob, os, json

ROOT='/Users/a55555/Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/workshop/content/431960'
OUT='/Users/a55555/Developer/LiveWallpaper/tools/particle_result.txt'
L=[]
def p(*a): L.append(' '.join(str(x) for x in a))

def rd(path):
    d=open(path,'rb').read();o=[0]
    def i():
        v=struct.unpack_from('<i',d,o[0])[0];o[0]+=4;return v
    ml=i();o[0]+=ml;c=i();E=[]
    for _ in range(c):
        nl=i();nm=d[o[0]:o[0]+nl].decode('utf-8','replace');o[0]+=nl;of=i();sz=i();E.append((nm,of,sz))
    b=o[0];return {n.replace(chr(92),'/'):d[b+of:b+of+sz] for n,of,sz in E}

# 收集所有 scene 里的 particle JSON,统计字段
all_particle_files=[]
emitter_keys=set(); init_names={}; op_names={}; top_keys=set()
samples=[]
for pk in sorted(glob.glob(os.path.join(ROOT,'*/scene.pkg'))):
    wid=os.path.basename(os.path.dirname(pk))
    try: f=rd(pk)
    except: continue
    for k in f:
        if '/particle' in k.lower() and k.endswith('.json') or (k.startswith('particles/') and k.endswith('.json')):
            try: pj=json.loads(f[k])
            except: continue
            all_particle_files.append((wid,k))
            top_keys.update(pj.keys())
            ems = pj.get('emitter') or pj.get('emitters') or []
            if isinstance(ems,dict): ems=[ems]
            for em in ems:
                if isinstance(em,dict): emitter_keys.update(em.keys())
            for ini in pj.get('initializer',[]) or pj.get('initializers',[]) or []:
                if isinstance(ini,dict):
                    nm=ini.get('name','?'); init_names[nm]=init_names.get(nm,0)+1
            for op in pj.get('operator',[]) or pj.get('operators',[]) or []:
                if isinstance(op,dict):
                    nm=op.get('name','?'); op_names[nm]=op_names.get(nm,0)+1
            if len(samples)<3:
                samples.append((wid,k,pj))

p("=== particle JSON 总数:%d ==="%len(all_particle_files))
p("top-level keys:", sorted(top_keys))
p("emitter keys:", sorted(emitter_keys))
p("\ninitializer names(出现次数):")
for n,c in sorted(init_names.items(),key=lambda x:-x[1]): p("  %-28s %d"%(n,c))
p("\noperator names(出现次数):")
for n,c in sorted(op_names.items(),key=lambda x:-x[1]): p("  %-28s %d"%(n,c))

p("\n\n=== 3 个完整样本 ===")
for wid,k,pj in samples:
    p("\n----- %s : %s -----"%(wid,k))
    p(json.dumps(pj,ensure_ascii=False,indent=1)[:2500])

open(OUT,'w').write('\n'.join(L)+'\n')
print("done",len(L),"lines, particle files:",len(all_particle_files))
