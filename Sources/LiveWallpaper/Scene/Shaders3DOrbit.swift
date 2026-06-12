// 自动生成:shaders/effects/guidao.frag(WE 太阳系内行星 P1-P4 轨道 shader)→ Metal。改 shader 重跑 /tmp/gen_orbit.py。
import Foundation

let orbitShaderSource = """
#include <metal_stdlib>
#include <simd/simd.h>
using namespace metal;

template<typename Tx, typename Ty>
inline Tx mod(Tx x, Ty y) { return x - y * floor(x / y); }

struct OrbitU {
    float u_lineOpacity;
    float u_globalScale;
    float u_trailEnable;
    float u_maxAB;
    float3 u_rotation;
    float u_originX;
    float u_originY;
    float u_originZ;
    float3 u_p1_orbitA; float3 u_p1_orbitB;
    float3 u_p2_orbitA; float3 u_p2_orbitB;
    float3 u_p3_orbitA; float3 u_p3_orbitB;
    float3 u_p4_orbitA; float3 u_p4_orbitB;
    float4 g_Texture0Resolution;
};

struct main0_out { float4 _fragColor [[color(0)]]; };
struct main0_in { float2 v_TexCoord [[user(locn0)]]; };
struct VOut { float4 pos [[position]]; float2 v_TexCoord [[user(locn0)]]; };

vertex VOut orbit_vertex(uint vid [[vertex_id]]) {
    float2 uv = float2(float((vid << 1) & 2), float(vid & 2));
    VOut o;
    o.pos = float4(uv * 2.0 - 1.0, 0.0, 1.0);
    o.v_TexCoord = float2(uv.x, 1.0 - uv.y);
    return o;
}

static inline __attribute__((always_inline))
float3 rotY3D(thread const float3& pt, thread const float& c, thread const float& s)
{
    return float3((pt.x * c) + (pt.z * s), pt.y, ((-pt.x) * s) + (pt.z * c));
}

static inline __attribute__((always_inline))
float3 rotX3D(thread const float3& pt, thread const float& c, thread const float& s)
{
    return float3(pt.x, (pt.y * c) - (pt.z * s), (pt.y * s) + (pt.z * c));
}

static inline __attribute__((always_inline))
void calcCombinedRotation(thread const float& cO, thread const float& sO, thread const float& cI, thread const float& sI, thread const float& cN, thread const float& sN, thread const float& cS, thread const float& sS, thread const float& cVY, thread const float& sVY, thread const float& cVX, thread const float& sVX, thread float3& row0, thread float3& row1, thread float3& row2)
{
    float3 bx = float3(1.0, 0.0, 0.0);
    float3 param = bx;
    float param_1 = cO;
    float param_2 = sO;
    bx = rotY3D(param, param_1, param_2);
    float3 param_3 = bx;
    float param_4 = cI;
    float param_5 = sI;
    bx = rotX3D(param_3, param_4, param_5);
    float3 param_6 = bx;
    float param_7 = cN;
    float param_8 = sN;
    bx = rotY3D(param_6, param_7, param_8);
    float3 param_9 = bx;
    float param_10 = cS;
    float param_11 = sS;
    bx = rotY3D(param_9, param_10, param_11);
    float3 param_12 = bx;
    float param_13 = cVY;
    float param_14 = sVY;
    bx = rotY3D(param_12, param_13, param_14);
    float3 param_15 = bx;
    float param_16 = cVX;
    float param_17 = sVX;
    bx = rotX3D(param_15, param_16, param_17);
    float3 by = float3(0.0, 1.0, 0.0);
    float3 param_18 = by;
    float param_19 = cO;
    float param_20 = sO;
    by = rotY3D(param_18, param_19, param_20);
    float3 param_21 = by;
    float param_22 = cI;
    float param_23 = sI;
    by = rotX3D(param_21, param_22, param_23);
    float3 param_24 = by;
    float param_25 = cN;
    float param_26 = sN;
    by = rotY3D(param_24, param_25, param_26);
    float3 param_27 = by;
    float param_28 = cS;
    float param_29 = sS;
    by = rotY3D(param_27, param_28, param_29);
    float3 param_30 = by;
    float param_31 = cVY;
    float param_32 = sVY;
    by = rotY3D(param_30, param_31, param_32);
    float3 param_33 = by;
    float param_34 = cVX;
    float param_35 = sVX;
    by = rotX3D(param_33, param_34, param_35);
    float3 bz = float3(0.0, 0.0, 1.0);
    float3 param_36 = bz;
    float param_37 = cO;
    float param_38 = sO;
    bz = rotY3D(param_36, param_37, param_38);
    float3 param_39 = bz;
    float param_40 = cI;
    float param_41 = sI;
    bz = rotX3D(param_39, param_40, param_41);
    float3 param_42 = bz;
    float param_43 = cN;
    float param_44 = sN;
    bz = rotY3D(param_42, param_43, param_44);
    float3 param_45 = bz;
    float param_46 = cS;
    float param_47 = sS;
    bz = rotY3D(param_45, param_46, param_47);
    float3 param_48 = bz;
    float param_49 = cVY;
    float param_50 = sVY;
    bz = rotY3D(param_48, param_49, param_50);
    float3 param_51 = bz;
    float param_52 = cVX;
    float param_53 = sVX;
    bz = rotX3D(param_51, param_52, param_53);
    row0 = float3(bx.x, by.x, bz.x);
    row1 = float3(bx.y, by.y, bz.y);
    row2 = float3(bx.z, by.z, bz.z);
}

static inline __attribute__((always_inline))
float2 computeOrbitPoint(thread const float& cosT, thread const float& sinT, thread const float& e, thread const float& semiLatus, thread const float3& row0, thread const float3& row1, thread const float3& row2, thread const float3& origin, thread const float& globalScale)
{
    float r = semiLatus / fast::max(1.0 + (e * cosT), 9.9999997473787516355514526367188e-05);
    float3 localPt = float3(r * cosT, 0.0, r * sinT);
    float3 pt = float3(dot(row0, localPt), dot(row1, localPt), dot(row2, localPt));
    pt = (pt - origin) * globalScale;
    float z_cam = fast::max((-pt.z) + 4.53999996185302734375, 9.9999997473787516355514526367188e-05);
    float scale = 0.3079729974269866943359375 / z_cam;
    return float2(pt.x * scale, pt.y * scale);
}

static inline __attribute__((always_inline))
float2 calcOrbitDistAndThetaTrail(thread const float2& screenPos, thread const float& e, thread const float& semiLatus, thread const float3& row0, thread const float3& row1, thread const float3& row2, thread const float3& origin, thread const float& globalScale, thread const float& planetTheta)
{
    float trailAngle = 2.19911479949951171875;
    float startTheta = planetTheta;
    float _step = trailAngle / 14.0;
    float cosStep = cos(_step);
    float sinStep = sin(_step);
    float cosT = cos(startTheta);
    float sinT = sin(startTheta);
    float param = cosT;
    float param_1 = sinT;
    float param_2 = e;
    float param_3 = semiLatus;
    float3 param_4 = row0;
    float3 param_5 = row1;
    float3 param_6 = row2;
    float3 param_7 = origin;
    float param_8 = globalScale;
    float2 firstPt = computeOrbitPoint(param, param_1, param_2, param_3, param_4, param_5, param_6, param_7, param_8);
    float2 prevPt = firstPt;
    float minDSq = 100000002004087734272.0;
    float closestTheta = startTheta;
    float _494;
    for (int i = 1; i <= 14; i++)
    {
        float newCos = (cosT * cosStep) - (sinT * sinStep);
        float newSin = (sinT * cosStep) + (cosT * sinStep);
        cosT = newCos;
        sinT = newSin;
        float param_9 = cosT;
        float param_10 = sinT;
        float param_11 = e;
        float param_12 = semiLatus;
        float3 param_13 = row0;
        float3 param_14 = row1;
        float3 param_15 = row2;
        float3 param_16 = origin;
        float param_17 = globalScale;
        float2 currPt = computeOrbitPoint(param_9, param_10, param_11, param_12, param_13, param_14, param_15, param_16, param_17);
        float2 ab = currPt - prevPt;
        float len2 = dot(ab, ab);
        if (len2 > 1.0000000133514319600180897396058e-10)
        {
            _494 = fast::clamp(dot(screenPos - prevPt, ab) / len2, 0.0, 1.0);
        }
        else
        {
            _494 = 0.0;
        }
        float t = _494;
        float2 d = screenPos - (prevPt + (ab * t));
        float dSq = dot(d, d);
        if (dSq < minDSq)
        {
            minDSq = dSq;
            closestTheta = startTheta + ((float(i - 1) + t) * _step);
        }
        prevPt = currPt;
    }
    closestTheta = mod(closestTheta, 6.283185482025146484375);
    return float2(sqrt(minDSq), closestTheta);
}

static inline __attribute__((always_inline))
float2 calcOrbitDistAndThetaFull(thread const float2& screenPos, thread const float& e, thread const float& semiLatus, thread const float3& row0, thread const float3& row1, thread const float3& row2, thread const float3& origin, thread const float& globalScale)
{
    float _step = 0.448798954486846923828125;
    float cosStep = cos(_step);
    float sinStep = sin(_step);
    float cosT = 1.0;
    float sinT = 0.0;
    float param = cosT;
    float param_1 = sinT;
    float param_2 = e;
    float param_3 = semiLatus;
    float3 param_4 = row0;
    float3 param_5 = row1;
    float3 param_6 = row2;
    float3 param_7 = origin;
    float param_8 = globalScale;
    float2 firstPt = computeOrbitPoint(param, param_1, param_2, param_3, param_4, param_5, param_6, param_7, param_8);
    float2 prevPt = firstPt;
    float minDSq = 100000002004087734272.0;
    float closestTheta = 0.0;
    float _636;
    for (int i = 1; i <= 14; i++)
    {
        float newCos = (cosT * cosStep) - (sinT * sinStep);
        float newSin = (sinT * cosStep) + (cosT * sinStep);
        cosT = newCos;
        sinT = newSin;
        float param_9 = cosT;
        float param_10 = sinT;
        float param_11 = e;
        float param_12 = semiLatus;
        float3 param_13 = row0;
        float3 param_14 = row1;
        float3 param_15 = row2;
        float3 param_16 = origin;
        float param_17 = globalScale;
        float2 currPt = computeOrbitPoint(param_9, param_10, param_11, param_12, param_13, param_14, param_15, param_16, param_17);
        float2 ab = currPt - prevPt;
        float len2 = dot(ab, ab);
        if (len2 > 1.0000000133514319600180897396058e-10)
        {
            _636 = fast::clamp(dot(screenPos - prevPt, ab) / len2, 0.0, 1.0);
        }
        else
        {
            _636 = 0.0;
        }
        float t = _636;
        float2 d = screenPos - (prevPt + (ab * t));
        float dSq = dot(d, d);
        if (dSq < minDSq)
        {
            minDSq = dSq;
            closestTheta = (float(i - 1) + t) * _step;
        }
        prevPt = currPt;
    }
    float2 ab_1 = firstPt - prevPt;
    float len2_1 = dot(ab_1, ab_1);
    float _688;
    if (len2_1 > 1.0000000133514319600180897396058e-10)
    {
        _688 = fast::clamp(dot(screenPos - prevPt, ab_1) / len2_1, 0.0, 1.0);
    }
    else
    {
        _688 = 0.0;
    }
    float t_1 = _688;
    float2 d_1 = screenPos - (prevPt + (ab_1 * t_1));
    float dSq_1 = dot(d_1, d_1);
    if (dSq_1 < minDSq)
    {
        minDSq = dSq_1;
        closestTheta = (14.0 + t_1) * _step;
        if (closestTheta >= 6.283185482025146484375)
        {
            closestTheta -= 6.283185482025146484375;
        }
    }
    return float2(sqrt(minDSq), closestTheta);
}

static inline __attribute__((always_inline))
float calcTrailAlpha(thread const float& planetTheta, thread const float& pointTheta)
{
    float delta = mod(pointTheta - planetTheta, 6.283185482025146484375);
    float trailAngle = 2.19911479949951171875;
    if (delta > trailAngle)
    {
        return 0.0;
    }
    return powr(1.0 - (delta / trailAngle), 1.0);
}

static inline __attribute__((always_inline))
void drawOrbit(thread const float3& orbitA, thread const float3& orbitB, thread const float3& planetColor, thread const float& maxAB, thread const float2& p, thread const float& edge, thread const float& aa, thread const float& cS, thread const float& sS, thread const float& cVX, thread const float& sVX, thread const float& cVY, thread const float& sVY, thread const float3& origin, thread const float& globalScale, thread const bool& trailEnabled, thread const float& opacity, thread float3& col, thread float& alpha)
{
    float p_a = orbitA.x * maxAB;
    if (p_a < 0.001000000047497451305389404296875)
    {
        return;
    }
    float p_b = orbitA.y * maxAB;
    float p_node = orbitA.z * 360.0;
    float p_inc = orbitB.x * 180.0;
    float p_omega = orbitB.y * 360.0;
    float p_theta = orbitB.z * 360.0;
    float a2 = p_a * p_a;
    float b2 = p_b * p_b;
    float _781;
    if (a2 > b2)
    {
        _781 = sqrt(1.0 - (b2 / a2));
    }
    else
    {
        _781 = 0.0;
    }
    float e = _781;
    float semiLatus = p_a * (1.0 - (e * e));
    float rN = p_node * 0.01745329238474369049072265625;
    float rI = p_inc * 0.01745329238474369049072265625;
    float rO = p_omega * 0.01745329238474369049072265625;
    float cN = cos(rN);
    float sN = sin(rN);
    float cI = cos(rI);
    float sI = sin(rI);
    float cO = cos(rO);
    float sO = sin(rO);
    float param = cO;
    float param_1 = sO;
    float param_2 = cI;
    float param_3 = sI;
    float param_4 = cN;
    float param_5 = sN;
    float param_6 = cS;
    float param_7 = sS;
    float param_8 = cVY;
    float param_9 = sVY;
    float param_10 = cVX;
    float param_11 = sVX;
    float3 param_12;
    float3 param_13;
    float3 param_14;
    calcCombinedRotation(param, param_1, param_2, param_3, param_4, param_5, param_6, param_7, param_8, param_9, param_10, param_11, param_12, param_13, param_14);
    float3 row0 = param_12;
    float3 row1 = param_13;
    float3 row2 = param_14;
    float planetTheta = p_theta * 0.01745329238474369049072265625;
    float2 result;
    if (trailEnabled)
    {
        float2 param_15 = p;
        float param_16 = e;
        float param_17 = semiLatus;
        float3 param_18 = row0;
        float3 param_19 = row1;
        float3 param_20 = row2;
        float3 param_21 = origin;
        float param_22 = globalScale;
        float param_23 = planetTheta;
        result = calcOrbitDistAndThetaTrail(param_15, param_16, param_17, param_18, param_19, param_20, param_21, param_22, param_23);
    }
    else
    {
        float2 param_24 = p;
        float param_25 = e;
        float param_26 = semiLatus;
        float3 param_27 = row0;
        float3 param_28 = row1;
        float3 param_29 = row2;
        float3 param_30 = origin;
        float param_31 = globalScale;
        result = calcOrbitDistAndThetaFull(param_24, param_25, param_26, param_27, param_28, param_29, param_30, param_31);
    }
    float dist = result.x;
    if (dist > (edge + aa))
    {
        return;
    }
    float pointTheta = result.y;
    float stroke = 1.0 - smoothstep(edge - aa, edge + aa, dist);
    float _930;
    if (trailEnabled)
    {
        float param_32 = planetTheta;
        float param_33 = pointTheta;
        _930 = calcTrailAlpha(param_32, param_33);
    }
    else
    {
        _930 = 1.0;
    }
    float trailAlpha = _930;
    float finalAlpha = (stroke * opacity) * trailAlpha;
    col = mix(col, planetColor, float3(finalAlpha));
    alpha = fast::max(alpha, finalAlpha);
}

fragment main0_out orbit_fragment(main0_in in [[stage_in]], constant OrbitU& u [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 origColor = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float3 col = origColor.xyz;
    float alpha = origColor.w;
    float2 centerOffset = abs(in.v_TexCoord - float2(0.5));
    bool _983 = centerOffset.x <= 0.95;
    bool _990;
    if (_983)
    {
        _990 = centerOffset.y <= 0.95;
    }
    else
    {
        _990 = _983;
    }
    bool inRenderArea = _990;
    bool shouldDraw = (u.u_lineOpacity >= 0.0199999995529651641845703125) && inRenderArea;
    if (shouldDraw)
    {
        float aspect = u.g_Texture0Resolution.x / u.g_Texture0Resolution.y;
        // WE 原值 edge=0.00015/aa=2/res/1000 在任何分辨率都是亚像素=不可见;改随分辨率自适应(~1.5px 线 + 1px 抗锯齿)。
        float aa = 2.0 / u.g_Texture0Resolution.y;
        float2 p = (in.v_TexCoord - float2(0.5)) * 2.0;
        p.x *= aspect;
        p.y = -p.y;
        float edge = 3.0 / u.g_Texture0Resolution.y;
        float3 origin = float3(u.u_originX, u.u_originY, u.u_originZ);
        float globalScale = u.u_globalScale;
        float maxAB = u.u_maxAB;
        float rotX = (u.u_rotation[0u] - 0.5) * 180.0;
        float rotY = (u.u_rotation[1u] - 0.5) * 360.0;
        float sceneRotY = (u.u_rotation[2u] - 0.5) * 360.0;
        float rS = sceneRotY * 0.01745329238474369049072265625;
        float rVX = rotX * 0.01745329238474369049072265625;
        float rVY = rotY * 0.01745329238474369049072265625;
        float cS = cos(rS);
        float sS = sin(rS);
        float cVX = cos(rVX);
        float sVX = sin(rVX);
        float cVY = cos(rVY);
        float sVY = sin(rVY);
        bool trailEnabled = u.u_trailEnable > 0.5;
        float3 param = u.u_p1_orbitA;
        float3 param_1 = u.u_p1_orbitB;
        float3 param_2 = float3(0.699999988079071044921875);
        float param_3 = maxAB;
        float2 param_4 = p;
        float param_5 = edge;
        float param_6 = aa;
        float param_7 = cS;
        float param_8 = sS;
        float param_9 = cVX;
        float param_10 = sVX;
        float param_11 = cVY;
        float param_12 = sVY;
        float3 param_13 = origin;
        float param_14 = globalScale;
        bool param_15 = trailEnabled;
        float param_16 = u.u_lineOpacity;
        float3 param_17 = col;
        float param_18 = alpha;
        drawOrbit(param, param_1, param_2, param_3, param_4, param_5, param_6, param_7, param_8, param_9, param_10, param_11, param_12, param_13, param_14, param_15, param_16, param_17, param_18);
        col = param_17;
        alpha = param_18;
        float3 param_19 = u.u_p2_orbitA;
        float3 param_20 = u.u_p2_orbitB;
        float3 param_21 = float3(0.89999997615814208984375, 0.75, 0.5);
        float param_22 = maxAB;
        float2 param_23 = p;
        float param_24 = edge;
        float param_25 = aa;
        float param_26 = cS;
        float param_27 = sS;
        float param_28 = cVX;
        float param_29 = sVX;
        float param_30 = cVY;
        float param_31 = sVY;
        float3 param_32 = origin;
        float param_33 = globalScale;
        bool param_34 = trailEnabled;
        float param_35 = u.u_lineOpacity;
        float3 param_36 = col;
        float param_37 = alpha;
        drawOrbit(param_19, param_20, param_21, param_22, param_23, param_24, param_25, param_26, param_27, param_28, param_29, param_30, param_31, param_32, param_33, param_34, param_35, param_36, param_37);
        col = param_36;
        alpha = param_37;
        float3 param_38 = u.u_p3_orbitA;
        float3 param_39 = u.u_p3_orbitB;
        float3 param_40 = float3(0.20000000298023223876953125, 0.5, 1.0);
        float param_41 = maxAB;
        float2 param_42 = p;
        float param_43 = edge;
        float param_44 = aa;
        float param_45 = cS;
        float param_46 = sS;
        float param_47 = cVX;
        float param_48 = sVX;
        float param_49 = cVY;
        float param_50 = sVY;
        float3 param_51 = origin;
        float param_52 = globalScale;
        bool param_53 = trailEnabled;
        float param_54 = u.u_lineOpacity;
        float3 param_55 = col;
        float param_56 = alpha;
        drawOrbit(param_38, param_39, param_40, param_41, param_42, param_43, param_44, param_45, param_46, param_47, param_48, param_49, param_50, param_51, param_52, param_53, param_54, param_55, param_56);
        col = param_55;
        alpha = param_56;
        float3 param_57 = u.u_p4_orbitA;
        float3 param_58 = u.u_p4_orbitB;
        float3 param_59 = float3(1.0, 0.100000001490116119384765625, 0.0500000007450580596923828125);
        float param_60 = maxAB;
        float2 param_61 = p;
        float param_62 = edge;
        float param_63 = aa;
        float param_64 = cS;
        float param_65 = sS;
        float param_66 = cVX;
        float param_67 = sVX;
        float param_68 = cVY;
        float param_69 = sVY;
        float3 param_70 = origin;
        float param_71 = globalScale;
        bool param_72 = trailEnabled;
        float param_73 = u.u_lineOpacity;
        float3 param_74 = col;
        float param_75 = alpha;
        drawOrbit(param_57, param_58, param_59, param_60, param_61, param_62, param_63, param_64, param_65, param_66, param_67, param_68, param_69, param_70, param_71, param_72, param_73, param_74, param_75);
        col = param_74;
        alpha = param_75;
    }
    out._fragColor = float4(col, alpha);
    return out;
}



"""
