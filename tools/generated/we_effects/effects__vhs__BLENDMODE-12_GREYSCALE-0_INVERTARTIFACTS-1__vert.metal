#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4x4 g_ModelViewProjectionMatrix;
    float4 g_Texture0Resolution;
    float g_Time;
    float g_NoiseScale;
    float g_Chromatic;
    float g_ArtifactsScale;
    float g_NoiseAlpha;
};

struct main0_out
{
    float4 v_TexCoord [[user(locn0)]];
    float4 v_TexCoordGlitch [[user(locn1)]];
    float4 v_TexCoordNoise [[user(locn2)]];
    float4 v_TexCoordVHSNoise [[user(locn3)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant _Globals& _19 [[buffer(0)]])
{
    main0_out out = {};
    out.gl_Position = _19.g_ModelViewProjectionMatrix * float4(in.a_Position, 1.0);
    float aspect = _19.g_Texture0Resolution.z / _19.g_Texture0Resolution.w;
    float t = fract(_19.g_Time);
    out.v_TexCoord = in.a_TexCoord.xyxy;
    float2 _65 = (in.a_TexCoord + float2(t)) * _19.g_NoiseScale;
    out.v_TexCoordNoise.x = _65.x;
    out.v_TexCoordNoise.y = _65.y;
    float2 _82 = ((in.a_TexCoord - float2(t * 2.5)) * _19.g_NoiseScale) * 0.519999980926513671875;
    out.v_TexCoordNoise.z = _82.x;
    out.v_TexCoordNoise.w = _82.y;
    out.v_TexCoordNoise *= float4(aspect, 1.0, aspect, 1.0);
    float2 _98 = out.v_TexCoordNoise.xy * float2(0.100000001490116119384765625, 10.0);
    out.v_TexCoordVHSNoise.x = _98.x;
    out.v_TexCoordVHSNoise.y = _98.y;
    float2 _108 = out.v_TexCoordNoise.zw * float2(0.00999999977648258209228515625, 2.0);
    out.v_TexCoordVHSNoise.z = _108.x;
    out.v_TexCoordVHSNoise.w = _108.y;
    out.v_TexCoordGlitch = out.v_TexCoord.xyxy;
    float chromatic = fast::min(_19.g_Chromatic, 0.100000001490116119384765625);
    float3 glitchOffset = (smoothstep(float3(0.0), float3(2.0), float3(1.0) + (sin((float3(11.0, 7.0, 13.0) * _19.g_Time) * 2.0) * 0.5)) * chromatic) * float3(0.0019000000320374965667724609375, 0.00209999992512166500091552734375, 0.001700000022538006305694580078125);
    out.v_TexCoordGlitch.y += ((0.0040000001899898052215576171875 * chromatic) + glitchOffset.x);
    float4 _165 = out.v_TexCoordGlitch;
    float2 _167 = _165.xz + (glitchOffset.xy + (float2(0.004999999888241291046142578125, -0.0005000000237487256526947021484375) * chromatic));
    out.v_TexCoordGlitch.x = _167.x;
    out.v_TexCoordGlitch.z = _167.y;
    out.v_TexCoordGlitch.z -= (glitchOffset.z + (0.006000000052154064178466796875 * chromatic));
    out.v_TexCoordGlitch.w -= (0.00449999980628490447998046875 * chromatic);
    return out;
}

