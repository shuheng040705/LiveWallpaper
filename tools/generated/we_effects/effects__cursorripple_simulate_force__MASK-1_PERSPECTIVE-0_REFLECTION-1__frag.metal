#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float g_Frametime;
    float4 g_Texture0Resolution;
    float g_RippleSpeed;
    float g_RippleDecay;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float2 v_TexCoord [[user(locn0)]];
};

static inline __attribute__((always_inline))
float4 sampleF(thread const float4& a, thread const float4& b, thread const float4& c)
{
    return fast::max(a, fast::max(b, c));
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _40 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]])
{
    main0_out out = {};
    float2 srcCoords = in.v_TexCoord;
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, srcCoords);
    float2 simTexel = float2(1.0) / _40.g_Texture0Resolution.xy;
    float2 rippleOffset = ((simTexel * 100.0) * _40.g_RippleSpeed) * fast::min(0.0333333350718021392822265625, _40.g_Frametime);
    float2 insideRipple = rippleOffset * 1.61000001430511474609375;
    float2 outsideRipple = rippleOffset;
    float reflectUp = 0.0;
    float reflectDown = 0.0;
    float reflectLeft = 0.0;
    float reflectRight = 0.0;
    reflectUp = step(1.0 - simTexel.y, srcCoords.y);
    reflectDown = step(srcCoords.y, simTexel.y);
    reflectLeft = step(1.0 - simTexel.x, srcCoords.x);
    reflectRight = step(srcCoords.x, simTexel.x);
    float2 maskCoords = srcCoords;
    float invMaskCenter = 1.0 - step(0.5, g_Texture1.sample(g_Texture1Smplr, maskCoords).x);
    float maskUp = 0.0;
    float maskDown = 0.0;
    float maskLeft = 0.0;
    float maskRight = 0.0;
    float2 maskOffset = insideRipple;
    maskUp = g_Texture1.sample(g_Texture1Smplr, (maskCoords + float2(0.0, -maskOffset.y))).x * invMaskCenter;
    maskDown = g_Texture1.sample(g_Texture1Smplr, (maskCoords + float2(0.0, maskOffset.y))).x * invMaskCenter;
    maskLeft = g_Texture1.sample(g_Texture1Smplr, (maskCoords + float2(-maskOffset.x, 0.0))).x * invMaskCenter;
    maskRight = g_Texture1.sample(g_Texture1Smplr, (maskCoords + float2(maskOffset.x, 0.0))).x * invMaskCenter;
    reflectDown = step(0.5, reflectDown + maskUp);
    reflectUp = step(0.5, reflectUp + maskDown);
    reflectRight = step(0.5, reflectRight + maskLeft);
    reflectLeft = step(0.5, reflectLeft + maskRight);
    float2 motionCoords = srcCoords;
    float4 uc = g_Texture0.sample(g_Texture0Smplr, (motionCoords + float2(0.0, -insideRipple.y)));
    float4 u00 = g_Texture0.sample(g_Texture0Smplr, (motionCoords + float2(-outsideRipple.x, -outsideRipple.y)));
    float4 u10 = g_Texture0.sample(g_Texture0Smplr, (motionCoords + float2(outsideRipple.x, -outsideRipple.y)));
    float4 dc = g_Texture0.sample(g_Texture0Smplr, (motionCoords + float2(0.0, insideRipple.y)));
    float4 d01 = g_Texture0.sample(g_Texture0Smplr, (motionCoords + float2(-outsideRipple.x, outsideRipple.y)));
    float4 d11 = g_Texture0.sample(g_Texture0Smplr, (motionCoords + float2(outsideRipple.x, outsideRipple.y)));
    float4 lc = g_Texture0.sample(g_Texture0Smplr, (motionCoords + float2(-insideRipple.x, 0.0)));
    float4 l00 = g_Texture0.sample(g_Texture0Smplr, (motionCoords + float2(-outsideRipple.x, -outsideRipple.y)));
    float4 l01 = g_Texture0.sample(g_Texture0Smplr, (motionCoords + float2(-outsideRipple.x, outsideRipple.y)));
    float4 rc = g_Texture0.sample(g_Texture0Smplr, (motionCoords + float2(insideRipple.x, 0.0)));
    float4 r10 = g_Texture0.sample(g_Texture0Smplr, (motionCoords + float2(outsideRipple.x, -outsideRipple.y)));
    float4 r11 = g_Texture0.sample(g_Texture0Smplr, (motionCoords + float2(outsideRipple.x, outsideRipple.y)));
    float4 param = uc;
    float4 param_1 = u00;
    float4 param_2 = u10;
    float4 up = sampleF(param, param_1, param_2);
    float4 param_3 = dc;
    float4 param_4 = d01;
    float4 param_5 = d11;
    float4 down = sampleF(param_3, param_4, param_5);
    float4 param_6 = lc;
    float4 param_7 = l00;
    float4 param_8 = l01;
    float4 left = sampleF(param_6, param_7, param_8);
    float4 param_9 = rc;
    float4 param_10 = r10;
    float4 param_11 = r11;
    float4 right = sampleF(param_9, param_10, param_11);
    float4 force = float4(0.0);
    float componentScale = 0.3333333432674407958984375;
    float4 _339 = force;
    float3 _341 = _339.xzy + up.xzy;
    force.x = _341.x;
    force.z = _341.y;
    force.y = _341.z;
    float4 _351 = force;
    float3 _353 = _351.xzw + down.xzw;
    force.x = _353.x;
    force.z = _353.y;
    force.w = _353.z;
    float4 _363 = force;
    float3 _365 = _363.xyw + left.xyw;
    force.x = _365.x;
    force.y = _365.y;
    force.w = _365.z;
    float4 _374 = force;
    float3 _376 = _374.zyw + right.zyw;
    force.z = _376.x;
    force.y = _376.y;
    force.w = _376.z;
    force *= componentScale;
    float4 forceCopy = force;
    float reflectionScale = 1.0;
    force.y = mix(force.y, forceCopy.w * reflectionScale, reflectDown);
    force.w = mix(force.w, forceCopy.y * reflectionScale, reflectUp);
    force.x = mix(force.x, forceCopy.z * reflectionScale, reflectRight);
    force.z = mix(force.z, forceCopy.x * reflectionScale, reflectLeft);
    float decay = 1.5;
    float drop = fast::max(0.003925490193068981170654296875, ((decay / 255.0) * (_40.g_Frametime / 0.0199999995529651641845703125)) * _40.g_RippleDecay);
    force -= float4(drop);
    force *= invMaskCenter;
    albedo = force;
    out._fragColor = albedo;
    return out;
}

