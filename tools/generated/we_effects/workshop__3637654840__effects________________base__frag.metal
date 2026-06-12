#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float2 u_center;
    float u_size;
    float u_corner;
    float u_softness;
    float4 g_Texture0Resolution;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float2 v_TexCoord [[user(locn0)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _13 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float aspect = _13.g_Texture0Resolution.x / _13.g_Texture0Resolution.y;
    float2 p = (in.v_TexCoord - float2(0.5)) * 2.0;
    p.x *= aspect;
    float2 center = (_13.u_center - float2(0.5)) * 2.0;
    center.x *= aspect;
    float2 q = p - center;
    float halfSize = _13.u_size;
    float r = (fast::min(_13.u_corner, 0.5) * _13.u_size) * 2.0;
    r = fast::min(r, halfSize);
    float innerHalf = halfSize - r;
    float dx = abs(q.x) - innerHalf;
    float dy = abs(q.y) - innerHalf;
    float outsideDist = sqrt((fast::max(dx, 0.0) * fast::max(dx, 0.0)) + (fast::max(dy, 0.0) * fast::max(dy, 0.0)));
    float insideDist = fast::min(fast::max(dx, dy), 0.0);
    float dist = (outsideDist + insideDist) - r;
    float4 texColor = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float mask = 1.0 - smoothstep(-_13.u_softness, _13.u_softness, dist);
    out._fragColor = float4(texColor.xyz, texColor.w * mask);
    return out;
}

