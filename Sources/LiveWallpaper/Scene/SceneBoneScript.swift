import JavaScriptCore
import simd

/// Bridges copied SceneScript matrices to the native pose. No script receives pointers to render data.
enum SceneBoneScript {
    static func install(in context: JSContext) {
        let matrixOperation: @convention(block) (String, [NSNumber]) -> Any = { operation, values in
            guard values.count == 16 else { return NSNull() }
            var m = matrix_identity_float4x4
            for i in values.indices { m[i / 4][i % 4] = values[i].floatValue }
            let det = m.determinant
            if operation == "determinant" { return det }
            guard det.isFinite && abs(det) > 1e-12 else { return NSNull() }
            return m.inverse.columnMajor
        }
        context.setObject(matrixOperation, forKeyedSubscript: "__weBoneMatrix" as NSString)
        context.evaluateScript(prelude)
    }

    static func bind(in context: JSContext, poses: [Int: SceneBonePose]) {
        let perform: @convention(block) (Int, String, JSValue, JSValue) -> Any = { layer, operation, bone, args in
            guard let pose = poses[layer] else {
                return operation == "count" ? 0 : operation == "index" || operation == "parent" ? -1 : NSNull() as Any
            }
            let i: Int
            if bone.isString { i = pose.index(name: bone.toString() ?? "") }
            else if bone.isNumber, let idx = Int(exactly: bone.toDouble()) { i = idx }
            else { i = -1 }
            let valid = pose.bones.indices.contains(i)
            switch operation {
            case "count": return pose.bones.count
            case "layerTransform": return pose.layerToScene.columnMajor
            case "index": return valid ? i : -1
            case "parent": return valid ? pose.bones[i].parent : -1
            case "world", "local": return pose.transform(i, inScene: operation == "world")?.columnMajor as Any? ?? NSNull()
            case "setWorld", "setLocal":
                if let values = args.toArray() as? [NSNumber], let mat = simd_float4x4(columns: values.map(\.floatValue)) {
                    pose.setTransform(mat, i, inScene: operation == "setWorld")
                }
            case "reset":
                if bone.isNull || bone.isUndefined { pose.reset(nil) }
                else if valid { pose.reset(i) }
            case "impulse":
                guard let values = args.toArray() as? [NSNumber], values.count == 6 else { return NSNull() }
                let v = values.map(\.floatValue)
                let direction = SIMD3(v[0], v[1], v[2]), angular = SIMD3(v[3], v[4], v[5])
                if bone.isNull || bone.isUndefined {
                    for j in pose.bones.indices { pose.impulse(j, direction: direction, angular: angular) }
                } else { pose.impulse(i, direction: direction, angular: angular) }
            default: break
            }
            return NSNull()
        }
        context.setObject(perform, forKeyedSubscript: "__weBone" as NSString)
        context.evaluateScript("""
        __weInstallBones(thisLayer);
        for (const layer of (globalThis.__layerList || [])) __weInstallBones(layer);
        """)
    }

    static let prelude = """
    (function() {
      const identity = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
      globalThis.Mat4 = class Mat4 {
        constructor(m) { this._m = Array.isArray(m) && m.length === 16 ? m.slice() : identity.slice(); }
        static identity() { return new Mat4(); }
        get m() { return this._m; } // Existing layer scripts also use column-major indexing.
        copy() { return new Mat4(this._m); }
        determinant() { return __weBoneMatrix('determinant',this._m); }
        inverse() { return new Mat4(__weBoneMatrix('inverse',this._m)); }
        transpose() { return new Mat4(this._m.map((_,i) => this._m[(i%4)*4 + Math.floor(i/4)])); }
        equals(other) { return other instanceof Mat4 && this._m.every((x,i) => Math.abs(x-other._m[i]) < 1e-5); }
        add(other) { return new Mat4(this._m.map((v,i) => v+other._m[i])); }
        subtract(other) { return new Mat4(this._m.map((v,i) => v-other._m[i])); }
        translation(v) {
          if (v === undefined) return new Vec3(this._m[12], this._m[13], this._m[14]);
          this._m[12] = v.x; this._m[13] = v.y; this._m[14] = v.z || 0;
          return this; // The official interactive puppet example passes this result to setBoneTransform.
        }
        static fromTranslation(v) { return new Mat4().translation(v); }
        static fromScale(v) {
          let t = new Mat4();
          if (typeof v === 'number') v = new Vec3(v,v,v);
          t._m[0] = v.x; t._m[5] = v.y; t._m[10] = v.z;
          return t;
        }
        static fromRotation(angle, axis) {
          let n = Math.hypot(axis.x, axis.y, axis.z);
          if (!n) return new Mat4();
          let x = axis.x/n, y = axis.y/n, z = axis.z/n, rad = angle*Math.PI/180;
          let c = Math.cos(rad), s = Math.sin(rad), a = 1-c;
          return new Mat4([c+x*x*a, y*x*a+z*s, z*x*a-y*s, 0,
                           x*y*a-z*s, c+y*y*a, z*y*a+x*s, 0,
                           x*z*a+y*s, y*z*a-x*s, c+z*z*a, 0, 0,0,0,1]);
        }
        multiply(other) {
          const a = this._m;
          if (typeof other === 'number') return new Mat4(a.map(x => x * other));
          if (other instanceof Vec4) {
            const v = [other.x, other.y, other.z, other.w];
            return new Vec4(...[0,1,2,3].map(r => v.reduce((s,n,k) => s + a[k*4+r]*n, 0)));
          }
          const b = other._m;
          return new Mat4(a.map((_,i) => {
            const r = i % 4, c = i - r;
            return a[r]*b[c] + a[4+r]*b[c+1] + a[8+r]*b[c+2] + a[12+r]*b[c+3];
          }));
        }
        translate(v) { return this.multiply(Mat4.fromTranslation(v)); }
        rotate(a, axis) { return this.multiply(Mat4.fromRotation(a,axis)); }
        scale(v) { return this.multiply(Mat4.fromScale(v)); }
        static fromEuler(x,y,z) {
          if (typeof x === 'object') ({x,y,z} = x);
          return Mat4.fromRotation(z,new Vec3(0,0,1)).rotate(y,new Vec3(0,1,0)).rotate(x,new Vec3(1,0,0));
        }
        static compose(t,r,s) { return Mat4.fromTranslation(t).multiply(Mat4.fromEuler(r)).scale(s); }
        right() { return new Vec3(...this._m.slice(0,3)); }
        up() { return new Vec3(...this._m.slice(4,7)); }
        forward() { return new Vec3(...this._m.slice(8,11)); }
        transformDirection(v) { return this.right().multiply(v.x).add(this.up().multiply(v.y)).add(this.forward().multiply(v.z || 0)); }
        transformPoint(v) { return this.transformDirection(v).add(this.translation()); }
        decompose() {
          const r = this.right(), u = this.up(), f = this.forward();
          const scale = new Vec3(r.length(), u.length(), f.length());
          const sy = -r.z/(scale.x || 1), ry = Math.asin(Math.max(-1,Math.min(1,sy)));
          const rx = Math.abs(Math.cos(ry)) > 1e-6 ? Math.atan2(u.z/(scale.y || 1),f.z/(scale.z || 1)) : 0;
          const rz = Math.abs(Math.cos(ry)) > 1e-6 ? Math.atan2(r.y,r.x) : Math.atan2(-u.x,u.y);
          return {translation: this.translation(), rotation: new Vec3(rx,ry,rz).multiply(180/Math.PI), scale};
        }
        extractEuler() { return this.decompose().rotation; }
      };
      globalThis.__weInstallBones = function(layer) {
        if (!layer || typeof layer.getBoneCount === 'function') return;
        const call = (op,bone,arg) => typeof __weBone === 'function' ? __weBone(layer.id,op,bone,arg) : null;
        layer.getTransformMatrix = () => new Mat4(call('layerTransform') || __weGetTransformMatrix(layer).m);
        layer.getBoneCount = () => call('count') || 0;
        layer.getBoneIndex = b => call('index',b) ?? -1;
        layer.getBoneParentIndex = b => call('parent',b) ?? -1;
        layer.getBoneTransform = b => new Mat4(call('world',b));
        layer.getLocalBoneTransform = b => new Mat4(call('local',b));
        layer.setBoneTransform = (b,m) => { if (m instanceof Mat4) call('setWorld',b,m._m); };
        layer.setLocalBoneTransform = (b,m) => { if (m instanceof Mat4) call('setLocal',b,m._m); };
        layer.getLocalBoneOrigin = b => layer.getLocalBoneTransform(b).translation();
        layer.setLocalBoneOrigin = (b,v) => layer.setLocalBoneTransform(b,layer.getLocalBoneTransform(b).translation(v));
        layer.getLocalBoneAngles = b => layer.getLocalBoneTransform(b).extractEuler();
        layer.setLocalBoneAngles = (b,v) => {
          const t = layer.getLocalBoneTransform(b).decompose();
          layer.setLocalBoneTransform(b,Mat4.compose(t.translation,v,t.scale));
        };
        layer.resetBonePhysicsSimulation = b => call('reset',b);
        layer.applyBonePhysicsImpulse = (b,d,a) => {
          if (b && typeof b === 'object') { a=d; d=b; b=null; }
          const parts = v => v ? [v.x,v.y,v.z || 0] : [0,0,0];
          call('impulse', b, parts(d).concat(parts(a)));
        };
      };
      __weInstallBones(thisLayer);
    })()
    """
}
