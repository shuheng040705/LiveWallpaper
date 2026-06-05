#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float u_alpha;
    float u_strength;
    float u_iterations;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float2 v_SizeMultiplier [[user(locn0)]];
    float2 v_TexCoord [[user(locn1)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _15 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 albedo = float4(0.0);
    bool _22 = _15.u_strength > 0.001000000047497451305389404296875;
    bool _29;
    if (_22)
    {
        _29 = _15.u_alpha > 0.001000000047497451305389404296875;
    }
    else
    {
        _29 = _22;
    }
    if (_29)
    {
        float2 offset = float2(0.0);
        float divisor = 0.0;
        int iterations = int(_15.u_iterations);
        int _46 = -iterations;
        for (int i = _46; i <= iterations; i++)
        {
            float n = float(i);
            offset.x = n * in.v_SizeMultiplier.x;
            float weight = exp((-abs(n)) * 0.100000001490116119384765625);
            divisor += weight;
            albedo += (g_Texture0.sample(g_Texture0Smplr, (in.v_TexCoord + offset)) * weight);
        }
        albedo = (albedo * _15.u_strength) / float4(divisor);
    }
    out._fragColor = albedo;
    return out;
}

