// 太阳辉光屏幕精灵(sun-1/2/4):origin 脚本自投影到屏幕,加色混合的辉光 quad。
import Foundation

let sunSpriteShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct SunU {
    float2 centerUV;   // 投影后的屏幕中心 UV(0..1)
    float2 sizeUV;     // quad 半尺寸(屏幕 UV 比例)
    float brightness;
    float pad;
    float3 tint;
};
struct SVOut { float4 pos [[position]]; float2 uv [[user(locn0)]]; };

vertex SVOut sun_vertex(uint vid [[vertex_id]], constant SunU& u [[buffer(0)]]) {
    float2 c = float2(float(vid & 1), float((vid >> 1) & 1));   // 0,0 / 1,0 / 0,1 / 1,1
    float2 uv = u.centerUV + (c - 0.5) * (u.sizeUV * 2.0);
    SVOut o;
    o.pos = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
    o.uv = c;
    return o;
}

fragment float4 sun_fragment(SVOut in [[stage_in]], texture2d<float> tex [[texture(0)]],
                             sampler smp [[sampler(0)]], constant SunU& u [[buffer(0)]]) {
    float4 t = tex.sample(smp, in.uv);
    // 辉光:纹理 alpha=辉光形状(圆),配合 blend sourceRGB=sourceAlpha 加色 → 圆形辉光不带方边。
    return float4(t.rgb * u.tint * u.brightness, t.a);
}

// 全屏三角形(godrays 用)。
vertex SVOut god_vertex(uint vid [[vertex_id]]) {
    float2 c = float2(float((vid << 1) & 2), float(vid & 2));
    SVOut o; o.pos = float4(c * 2.0 - 1.0, 0.0, 1.0); o.uv = float2(c.x, 1.0 - c.y);
    return o;
}
// 体积光/god rays(WE sun-4 上的 godrays effect):从太阳屏幕位置径向采样累加亮度=光shaft。
struct GodU { float2 sunUV; float weight; float decay; float density; float exposure; };
fragment float4 godrays_fragment(SVOut in [[stage_in]], texture2d<float> scene [[texture(0)]],
                                 sampler smp [[sampler(0)]], constant GodU& g [[buffer(0)]]) {
    const int N = 48;
    float2 delta = (in.uv - g.sunUV) * (g.density / float(N));
    float2 coord = in.uv;
    float illum = 1.0;
    float3 accum = float3(0.0);
    for (int i = 0; i < N; i++) {
        coord -= delta;
        float3 s = scene.sample(smp, coord).rgb;
        float lum = max(s.r, max(s.g, s.b));      // 只让很亮处(太阳核)产生光shaft,网格线不算
        accum += s * smoothstep(0.82, 1.0, lum) * illum;
        illum *= g.decay;
    }
    float3 base = scene.sample(smp, in.uv).rgb;
    return float4(base + accum * (g.weight * g.exposure), 1.0);
}
"""
