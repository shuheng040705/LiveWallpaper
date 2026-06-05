#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float2 g_Point0;
    float2 g_Point1;
    float g_Size;
    float g_CenterPos;
    float g_Feather;
    float g_Amount;
    float g_Time;
    float g_NoiseSpeed;
    float g_NoiseAmount;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float4 v_TexCoord [[user(locn0)]];
    float2 v_TexCoordMask [[user(locn1)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _25 [[buffer(0)]], texture2d<float> g_Texture1 [[texture(0)]], texture2d<float> g_Texture0 [[texture(1)]], sampler g_Texture1Smplr [[sampler(0)]], sampler g_Texture0Smplr [[sampler(1)]])
{
    main0_out out = {};
    float2 texCoord = in.v_TexCoord.xy;
    float aspect = in.v_TexCoord.z;
    float2 p0 = _25.g_Point0;
    float2 p1 = _25.g_Point1;
    p0.x *= aspect;
    p1.x *= aspect;
    texCoord.x *= aspect;
    float2 axis = fast::normalize(p1 - p0);
    float2 center = p0 + ((p1 - p0) * _25.g_CenterPos);
    axis = fast::normalize(axis);
    float2 axisOrtho = float2(-axis.y, axis.x);
    float2 uvDelta = texCoord - center;
    float distanceAlongAxis = dot(axis, uvDelta);
    float distanceOrtho = dot(axisOrtho, uvDelta);
    float anim = in.v_TexCoord.w;
    float distortAmt = anim;
    float2 uvDistort = ((axis * distortAmt) * distanceOrtho) * distanceAlongAxis;
    uvDistort += (((axisOrtho * distortAmt) * anim) * distanceOrtho);
    texCoord += uvDistort;
    float mask = 1.0;
    float feather = fast::max(_25.g_Feather, 9.9999997473787516355514526367188e-06);
    float2 deltaRight = texCoord - p1;
    float2 deltaLeft = texCoord - p0;
    float distanceRight = dot(deltaRight, axis);
    float distanceLeft = dot(deltaLeft, axis);
    mask *= smoothstep(feather, 0.0, distanceRight);
    mask *= smoothstep(-feather, 0.0, distanceLeft);
    float sizeMod = _25.g_Size;
    sizeMod = _25.g_Size * (1.0 - ((abs(anim) * _25.g_Amount) * 0.5));
    mask *= smoothstep(sizeMod + feather, sizeMod - feather, distanceOrtho);
    mask *= step(0.0, distanceOrtho);
    mask *= g_Texture1.sample(g_Texture1Smplr, in.v_TexCoordMask).x;
    texCoord.x /= aspect;
    texCoord = mix(in.v_TexCoord.xy, texCoord, float2(mask));
    out._fragColor = g_Texture0.sample(g_Texture0Smplr, texCoord);
    return out;
}

