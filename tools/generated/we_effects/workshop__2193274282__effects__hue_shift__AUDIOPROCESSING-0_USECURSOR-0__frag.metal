#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float2 g_PointerPosition;
    float g_Time;
    float u_HueShiftSpeed;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float4 v_TexCoord [[user(locn2)]];
};

static inline __attribute__((always_inline))
float3 rgb2hsv(thread const float3& RGB)
{
    float4 _67;
    if (RGB.y < RGB.z)
    {
        _67 = float4(RGB.zy, -1.0, 0.666666686534881591796875);
    }
    else
    {
        _67 = float4(RGB.yz, 0.0, -0.3333333432674407958984375);
    }
    float4 P = _67;
    float4 _92;
    if (RGB.x < P.x)
    {
        _92 = float4(P.xyw, RGB.x);
    }
    else
    {
        _92 = float4(RGB.x, P.yzx);
    }
    float4 Q = _92;
    float C = Q.x - fast::min(Q.w, Q.y);
    float H = abs(((Q.w - Q.y) / ((6.0 * C) + 1.0000000133514319600180897396058e-10)) + Q.z);
    float3 HCV = float3(H, C, Q.x);
    float S = HCV.y / (HCV.z + 1.0000000133514319600180897396058e-10);
    return float3(HCV.x, S, HCV.z);
}

static inline __attribute__((always_inline))
float3 hsv2rgb(thread const float3& c)
{
    float4 K = float4(1.0, 0.666666686534881591796875, 0.3333333432674407958984375, 3.0);
    float3 p = abs((fract(c.xxx + K.xyz) * 6.0) - K.www);
    return mix(K.xxx, fast::clamp(p - K.xxx, float3(0.0), float3(1.0)), float3(c.y)) * c.z;
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _186 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float mask = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord.zw).x;
    float3 param = albedo.xyz;
    float3 newAlbedo = rgb2hsv(param);
    newAlbedo.x = fract(newAlbedo.x + (_186.g_Time * _186.u_HueShiftSpeed));
    float3 param_1 = newAlbedo;
    newAlbedo = hsv2rgb(param_1);
    float4 _202 = albedo;
    float3 _207 = mix(_202.xyz, newAlbedo, float3(mask));
    albedo.x = _207.x;
    albedo.y = _207.y;
    albedo.z = _207.z;
    out._fragColor = albedo;
    return out;
}

