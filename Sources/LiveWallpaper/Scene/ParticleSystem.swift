import Foundation
import simd

/// 一个粒子发射器的静态描述(从 particles/*.json 解析)。
struct ParticleEmitterDesc {
    var maxCount: Int
    var rate: Float                 // 每秒发射数
    var emitterOrigin: SIMD3<Float> // 发射器局部原点
    var directions: SIMD3<Float>    // 方向偏置
    var distanceMin: Float
    var distanceMax: Float
    var startTime: Float
    var sceneObjIndex: Int = .max   // scene.json objects 数组下标(粒子按场景序与图层交错绘制的锚点)

    // 发射器形状:boxrandom(盒内对称采样,沿 directions 喷)vs sphererandom(球面/圆盘散开)。
    var isBox: Bool = false
    // box/sphere 发射器的距离向量(WE distancemin/max,默认 max=(256,256,0))。
    // box:每轴 rand(distMin,distMax) 再 50% 翻负号(distMin>0 = 盒中心空洞);乘 directions(Y 翻转)。
    // sphere:用 .x 当标量半径(2D 圆盘 sqrt 面积均匀 / 3D 球壳 cbrt 体积均匀)。对照 CParticle.cpp:493-643。
    var distanceMinVec: SIMD3<Float> = .zero
    var distanceMaxVec: SIMD3<Float> = SIMD3(256, 256, 0)
    // directions 方向偏置(WE 默认 (1,1,0));box/sphere spawn 时乘进随机位移(box 额外翻 Y)。
    var directionsVec: SIMD3<Float> = SIMD3(1, 1, 0)
    // 顶层粒子 flags(非发射器 flags):bit 2 (==4) = 透视粒子系统。发射用 3D 球壳(置位)而非 2D 圆盘
    // (CParticle.cpp:599),且**渲染换透视投影**:perspective(fov,aspect,near0,far1000)·lookAt(eye(0,0,1000)→
    // 屏幕中心)替换正交 VP(CParticle.cpp:1883-1896),顶点在投影前扩展 → 近(z→1000)大且快、远小且慢
    // =「透视雪」景深(snowperspective 预设的本体)。等效 CPU 公式见 instances()。
    var particleFlags: UInt32 = 0
    // 画布像素尺寸 + 场景相机 fov(WallpaperParser.cpp:77 默认 50°):flags&4 透视换算屏幕居中坐标用。
    var canvasSize = SIMD2<Float>(1920, 1080)
    var cameraFov: Float = 50
    // emitter.sign(ivec3,默认 0):每轴强制正负。1→abs(只正)、-1→-abs(只负)、0→保持。
    // 仅 sphere spawn 用(照 CParticle.cpp:636-643)。
    var emitterSign: SIMD3<Int32> = .zero
    // 发射器 emitterSpeed(emitter.speedmin/max,默认 0):sphere 若设了则给沿外向的初速度。对照 CParticle.cpp:647-656。
    var emitterSpeedMin: Float = 0, emitterSpeedMax: Float = 0
    // 发射器节奏:delay(开喷前延迟秒)、duration(>0 时到期停喷)、instantaneous(诞生瞬间一次性爆发数)。
    // 对照 ObjectParser.cpp:818/825/826 + CParticle.cpp:424-479。
    var emitterDelay: Float = 0
    var emitterDuration: Float = 0
    var emitterInstantaneous: Int = 0
    // emitter.flags bit1(==2)= limitOnePerFrame:每帧至多发 1 个,防 rope 同点堆叠出畸变带。
    // 对照 CParticle.cpp:412/474/561/575。绳类发射器常置位,保证拖尾链每帧只推进一个节点。
    var emitterLimitOnePerFrame: Bool = false
    var sign: SIMD3<Float> = SIMD3(1, 1, 1)
    // 湍流/方向速度(turbulentvelocityrandom 的 speedmin/max)— 粒子主运动来源。
    var turbSpeedMin: Float = 0, turbSpeedMax: Float = 0

    // initializer 范围
    var lifetimeMin: Float = 2, lifetimeMax: Float = 5
    var sizeMin: Float = 50, sizeMax: Float = 50
    var sizeExponent: Float = 1            // sizerandom 的 pow(t,exponent) 非线性偏置(默认线性)
    // velocityrandom:WE 默认 min/max = ∓32(全轴)。spawn 时 vel = rand3(min,max)×speedOverride、再翻 Y、累加(+=)。
    // 对照 CParticle.cpp:790-792 + ObjectParser.cpp:878。
    var hasVelRandom = false
    var velMin: SIMD3<Float> = SIMD3(-32, -32, -32), velMax: SIMD3<Float> = SIMD3(32, 32, 32)
    // mapsequencearoundcontrolpoint 初始化器(CParticle.cpp:934-982 + ObjectParser.cpp:898-903):
    // 粒子诞生在控制点,按发射序号在圆周均匀分配径向初速度(扇形喷发)。WE 默认 speedmin (0,0,0) /
    // speedmax (0,0,100) / count 1。我们 Y-up 故**不翻 Y**(同 velocityrandom 约定,见上)。
    var hasMapSeq = false
    var mapSeqControlPoint = 0, mapSeqCount = 1
    var mapSeqSpeedMin: SIMD3<Float> = .zero, mapSeqSpeedMax: SIMD3<Float> = SIMD3(0, 0, 100)
    var colorMin: SIMD3<Float> = SIMD3(1,1,1), colorMax: SIMD3<Float> = SIMD3(1,1,1)
    var alphaMin: Float = 1, alphaMax: Float = 1
    // rotationrandom 初始化器(3 轴初始旋转,默认 max.z=2π);我们的精灵只有单轴 2D 旋转 → 取 .z 当初始角。
    // rotation = rand3(min,max).z × speedOverride。对照 CParticle.cpp:802 + ObjectParser.cpp:881-884。
    var hasRotRandom = false
    var rotMin: SIMD3<Float> = .zero, rotMax: SIMD3<Float> = SIMD3(0, 0, 6.2831853)
    // angularvelocityrandom:WE 3 轴 + exponent(pow(t,exp) 偏置);默认 min.z=-5/max.z=5/exp=1。
    // 我们精灵单轴自转 → 取 .z。angVel = (min.z + pow(rand,exp)·(max.z-min.z)) × speedOverride。
    // 对照 CParticle.cpp:812-828 + ObjectParser.cpp:886-889。
    var hasAngularVel = false
    var angVelMin: Float = -5, angVelMax: Float = 5
    var angVelExponent: Float = 1

    // operator
    var gravity: SIMD3<Float> = .zero
    var drag: Float = 0                    // movement 的速度阻力(vel *= 1-drag·dt);缺它则该减速的雪/灰持续加速
    var hasAlphaFade = false
    var fadeInTime: Float = 0, fadeOutTime: Float = 0
    var hasSizeChange = false
    var sizeChangeStart: Float = 1, sizeChangeEnd: Float = 1
    var sizeChangeStartTime: Float = 0, sizeChangeEndTime: Float = 1   // 窗口时间(lwe fadeValue 用,#4)
    // alphachange 算子(alpha 随归一化生命比窗口插值):alpha = initial.alpha × fadeValue(f, start,end, sv,ev)。
    // 与 alphafade/oscillatealpha 叠乘。默认 starttime 0 / endtime 1 / startvalue 1 / endvalue 0
    // (照 ObjectParser.cpp:928 → 默认整生命从 1 淡到 0)。对照 CParticle.cpp:1183-1212。
    var hasAlphaChange = false
    var alphaChangeStartTime: Float = 0, alphaChangeEndTime: Float = 1
    var alphaChangeStartValue: Float = 1, alphaChangeEndValue: Float = 0
    // colorchange 算子(逐通道窗口插值):color = initial.color × vec3(fadeValue 各通道)。
    // 默认 starttime 0 / endtime 1 / startvalue (1,1,1) / endvalue (1,1,1)(照 ObjectParser.cpp:933 →
    // 默认不变色)。对照 CParticle.cpp:1214-1245。
    var hasColorChange = false
    var colorChangeStartTime: Float = 0, colorChangeEndTime: Float = 1
    var colorChangeStartValue: SIMD3<Float> = SIMD3(1, 1, 1), colorChangeEndValue: SIMD3<Float> = SIMD3(1, 1, 1)
    // vortex 算子(绕 axis 的切向涡旋,标准模式 flags=0):切向力 vel += tangent·speed·dt·speedOverride,
    // speed 按到中心半径在 [distanceInner,distanceOuter] 间 mix(speedInner,speedOuter)。我们没有控制点数据,
    // 中心默认取发射器原点 emitterOrigin(WE 默认 controlpoint=0 + offset;我们用 emitterOrigin+offset 近似)。
    // 默认 axis (0,0,1) / offset 0 / distanceInner 500 / distanceOuter 650 / speedInner 2500 / speedOuter 0
    // / centerForce 1(照 ObjectParser.cpp:949)。对照 CParticle.cpp:1303-1460(只移植标准模式,不含 ring/audio)。
    var hasVortex = false
    var vortexAxis: SIMD3<Float> = SIMD3(0, 0, 1), vortexOffset: SIMD3<Float> = .zero
    var vortexDistanceInner: Float = 500, vortexDistanceOuter: Float = 650
    var vortexSpeedInner: Float = 2500, vortexSpeedOuter: Float = 0
    var vortexCenterForce: Float = 1
    var vortexMaintainDistance = false   // flags bit 2:开启时额外朝中心施加 centerForce
    // ring 子模式(flags bit 4,照 CParticle.cpp:1303-1432):环形速度场(空心中心→环内mix→环外拉回)。
    // infiniteAxis(flags bit 1):投影掉轴向分量,只在垂直 axis 的平面内算半径/切向。默认值照 ObjectParser.cpp:952-961。
    var vortexRingShape = false          // flags & 4
    var vortexInfiniteAxis = false       // flags & 1
    var vortexRingRadius: Float = 300, vortexRingWidth: Float = 50
    var vortexRingPullDistance: Float = 50, vortexRingPullForce: Float = 10
    // instanceoverride 块(粒子 json 顶层 instanceoverride,作为乘子):size 乘进精灵 size、
    // speed 乘进 turbulence/turbVelRand/vortex 的速度、count 乘进 maxCount。alpha 已由 layerAlpha 承载
    // (图层级 instanceoverride.alpha),此处不重复。默认全 1(照 ObjectParser.cpp:1097)。对照 Object.h:532。
    var ioSize: Float = 1
    var ioSpeed: Float = 1
    var ioLifetime: Float = 1   // instanceoverride.lifetime(乘进粒子寿命,WE CParticle.cpp:518/779);过去完全没读
    // turbulence 算子(curl-noise 流动力场):烟/雾/蒸汽的卷曲运动。speed/phase 每发射器随机一次
    // (照 CParticle.cpp:1265)。默认 scale 0.005 / speed 500-1000 / timescale 0.01 / mask (1,1,0)。
    var hasTurbulence = false
    var turbScale: Float = 0.005
    var turbFieldSpeed: Float = 0          // = rand(speedmin,speedmax),解析时随机一次
    var turbTimeScale: Float = 0.01
    var turbMask: SIMD3<Float> = SIMD3(1, 1, 0)
    var turbPhase: Float = 0               // = rand(phasemin,phasemax),解析时随机一次
    // oscillate 振荡算子(萤火虫闪烁/星星呼吸/位置抖动)。freq/phase 逐粒子随机一次;
    // multiplier = mix(scaleMin, scaleMax, (cos(freq·age+phase)+1)/2)。对照 CParticle.cpp:1509+。
    var hasOscAlpha = false
    var oscAFreqMin: Float = 0, oscAFreqMax: Float = 10, oscAScaleMin: Float = 0, oscAScaleMax: Float = 1, oscAPhaseMin: Float = 0, oscAPhaseMax: Float = 6.2831853
    var hasOscSize = false
    var oscSFreqMin: Float = 0, oscSFreqMax: Float = 10, oscSScaleMin: Float = 0.8, oscSScaleMax: Float = 1.2, oscSPhaseMin: Float = 0, oscSPhaseMax: Float = 6.2831853
    // oscillateposition:WE 把每个 operator 当独立条目逐个 apply(lwe setupOperators CParticle.cpp:971-1011
    // 遍历 m_particle.operators,每个 oscillateposition 在 :1001-1002 各自生成一个 OperatorFunc 压进 m_operators,
    // update 时全部执行 :1631-1641)。**同一 group 可声明多个 oscillateposition**(如雪的「双摆」:一个左右、
    // 一个上下),旧实现用单字段 → 后一个覆盖前一个,丢了主力摆动。改为**配置数组**,每个配置各自一套逐粒子
    // freq/scale/phase 状态,独立 apply(对齐 lwe 的 operator 列表逐个执行)。
    // 注:lwe 自身把逐粒子振荡状态存在单个 struct(CParticle.h:59-64),多个 oscillateposition 会**共享**该随机
    // 状态(lwe 已知局限);我们给每个配置独立状态,是更准的 WE 语义(每个 operator 独立随机),也正是用户要的
    // 「双摆各自摆动」。默认 freq 0-5 / scale 0-10 / phase 0-2π / mask (1,1,0)。
    struct OscPos {
        var freqMin: Float = 0, freqMax: Float = 5
        var scaleMin: Float = 0, scaleMax: Float = 10
        var phaseMin: Float = 0, phaseMax: Float = 6.2831853
        var mask: SIMD3<Float> = SIMD3(1, 1, 0)
    }
    var oscPositions: [OscPos] = []
    // controlpointattract 算子:阈值内朝控制点恒力吸引。threshold = thresholdRaw/2;
    // dist∈(0.001, threshold) 时 vel += (toCenter/dist)·scale·dt·speedOverride。scale<0 = 排斥。
    // ── 控制点语义(2026-06-11,Postscript 鸟群"贴顶飞"真因修复)──────────────────────────────
    //   cp flags&1 = linkMouse(位置=光标,运行期解析);flags&2 = worldSpace(offset 是**场景世界坐标**,
    //   lwe CParticle.cpp:152-163);scene 对象 instanceoverride 的 "controlpointN" = 该控制点的**世界坐标覆盖**
    //   (作者摆的飞行路径锚点;lwe 的 instanceOverride 结构根本没有 controlpointN 字段 = lwe 缺口)。
    //   优先级:io 覆盖 > worldSpace offset > 局部 offset。世界坐标 → 层局部:(world − layerOrigin)/layerScale。
    //   旧实现忽略 io+flags → 把斥力点(Bird cp2/3/4 offset 全 (0,-500))叠在出生点旁,鸟被推着贴顶飞;
    //   io 真值 (1032,1074)/(1754,1218)/(1644,99) = 封顶部+封右下 → 中部走廊 = WE 的鸟飞中间。
    //   对照 CParticle.cpp:1462-1505 + ObjectParser.cpp:962-966。
    struct CPAttract {
        var cpId: Int = 0
        var linkMouse: Bool = false
        var worldSpace: Bool = false          // cp flags&2:offset 为场景世界坐标
        var offset: SIMD3<Float> = .zero      // controlpoint[].offset(局部或世界,见 worldSpace)
        var ioWorld: SIMD3<Float>? = nil      // instanceoverride.controlpointN(场景世界坐标,优先)
        var originOff: SIMD3<Float> = .zero   // operator.origin(加到最终中心上)
        var scale: Float
        var threshold: Float
        var center: SIMD3<Float> = .zero      // 解析后的层局部中心(applyObjectLayer 求好;linkMouse 运行期用光标)
    }
    var cpAttracts: [CPAttract] = []
    // remapvalue 算子。**lwe 根本没有 remapvalue**(穷尽搜 src/WallpaperEngine:setupOperators 分发表无、
    // CParticle.cpp/.h/Data/Parsers 全无;唯一的 "remap" 命中是 TextureMap 与 External/spirv-remap,非粒子逻辑)。
    // 故此算子按**真 WE remapvalue 语义**移植(用户授权扣数据):用一个噪声场把粒子的某个标量 source 映射出
    // 噪声值 t∈[0,1],在 outputrangemin..outputrangemax(SIMD3)间 mix 成一个增量,加到 output 指向的量上。
    //   source(被采样/被映射的输入):
    //     • "velocity"(默认):用**粒子位置**驱动噪声(位置 → 噪声场 → 速度增量),屏幕雨的速度噪声驱动(rain_screen_*)。
    //     • "speed":用**粒子速度大小**(|vel|)驱动噪声相位 → 按速度快慢调制(Gouttes 玻璃水珠等按速度飘)。
    //   transformfunction(噪声类型):
    //     • "simplexnoise":单倍频噪声(我们用 perlin 近似 simplex,见下,可接受;标注)。
    //     • "fbmnoise":分形布朗噪声 = 多个 octave 的 perlin 按 amplitude/frequency 倍增叠加(lacunarity/gain 标准值)。
    //   output(增量加到何处):目前实现 "velocity"(加到速度);其余 output 暂不置位。
    // 输入坐标按 transforminputscale 缩放。
    //【WE 语义不确定处已显式标注】:source=speed 的「速度→噪声坐标」精确公式、fbm 的 octave 数/lacunarity/gain
    //  在 WE 中无公开规范 → 采用标准 fBm 约定(octaves=4, lacunarity=2, gain=0.5),并在使用处标注为假设。
    var hasRemap = false
    var remapSourceSpeed = false        // source=="speed"(否则按位置驱动,=velocity)
    var remapFbm = false                // transformfunction=="fbmnoise"(否则单倍频 simplex/perlin)
    var remapInputScale: Float = 1
    var remapOutputMin: SIMD3<Float> = .zero
    var remapOutputMax: SIMD3<Float> = .zero
    // angularmovement 算子:对**非定向**粒子施加 Z 角加速度(力)。读 op.force 的 .z;
    // step() 里 angVel += force.z·dt(在 rotation += angVel·dt 之前)。定向粒子(雨丝)angVel 恒 0,不受影响。
    // 实测仅 1 张壁纸有真实 force "0 0 0.1"。对照 WE angularmovement(force 作用于角速度)。
    var hasAngularMovement = false
    var angularForceZ: Float = 0
    var angularDragZ: Float = 0     // angularmovement op.drag(lwe `angularVelocity *= 1-drag*dt`,clamp≥0)
    // sprite renderer 的 orientation=="upright":精灵竖直站立,不随机翻滚、不自转(spawn rotation 强制 0)。
    // 用于水花(Rain_Splash orientation:"upright")。对照 WE sprite orientation upright。
    var orientationUpright: Bool = false
    // animationmode + sequencemultiplier(精灵表播放):默认 "sequence"(循环播放,fmod)/ "once"(播一遍)/
    // "randomframe"(每粒子固定随机帧)。sequenceMultiplier 是播放速度倍率(默认 1)。
    // 对照 CParticle.cpp:304-328 + ObjectParser.cpp:689/696。
    var animationMode: String = "sequence"
    var sequenceMultiplier: Float = 1
    // turbulentvelocityrandom 初始化器:spawn 时按 curl 噪声给**初始速度方向**(限制在 forward±scale/2 角内,
    // 可绕 right 轴 offset 倾斜,2D 投影到 XY)。speed 复用 turbSpeedMin/Max。对照 CParticle.cpp:875-931。
    var hasTurbVelRand = false
    var tvScale: Float = 1, tvOffset: Float = 0, tvTimeScale: Float = 1
    var tvForward: SIMD3<Float> = SIMD3(0, 1, 0), tvRight: SIMD3<Float> = SIMD3(0, 0, 1)
    var tvPhaseMin: Float = 0, tvPhaseMax: Float = 0.1

    // 来自场景层 + 材质
    var layerOrigin: SIMD2<Float> = .zero  // 粒子层在场景中的位置
    var layerScale: SIMD2<Float> = SIMD2(1, 1)  // 图层各轴独立缩放(各向异性层如雨水花 (0.848,0.10))
    var layerAngleZ: Float = 0             // 图层 Z 旋转(WE angles,弧度);雨层 -0.145 → 雨丝斜下
    var layerAlpha: Float = 1              // instanceoverride.alpha(图层级整体透明度)
    var parallaxDepth: SIMD2<Float> = SIMD2(1, 1)  // 鼠标视差深度(WE parallaxDepth);粒子层照图像层同公式平移投影
    var texturePath: String?    // pkg 内实际 .tex 路径(若存在)
    var textureName: String?    // 材质引用的纹理基名
    var normalTexturePath: String?  // 法线贴图 pkg 内路径(折射粒子 textures[1])
    var normalTextureName: String?  // 法线贴图引用名
    var blend: BlendMode = .additive
    // 材质 overbright(ui_editor_properties_overbright,默认 1,range[0,5])。WE genericparticle.frag:119
    // / genericropeparticle.frag:62 末尾 `color.rgb *= g_Overbright`。火焰/光点 >1 提亮、暗 halo <1 压暗。
    var overbright: Float = 1
    // 折射强度(ui_editor_properties_refract_amount,WE g_RefractAmount 默认 0.05,range[-1,1])。
    // 实库雨幕 -0.05~-0.44(负=反向)、magic_pulse 1。仅折射粒子用(common_particles.h:18)。
    var refractAmount: Float = 0.05

    // 精灵表(从 <tex>.tex-json 的 spritesheetsequences 读;无则单帧):
    var sheetFrames: Int = 1
    var sheetDuration: Float = 1            // 精灵表整轮秒数(侧车 duration);frameDuration = sheetDuration/frames
    var frameWidthPx: Float = 0   // 0 = 非精灵表(整张当一帧)
    var frameHeightPx: Float = 0

    // 鼠标拖尾:发射器原点跟随光标(controlpoint[0].flags==1 / rope renderer)。
    var followsCursor: Bool = false
    // spritetrail 渲染器:粒子按速度方向拉伸成拖尾带(genericparticle.vert TRAILRENDERER 分支)。
    // 长轴 = size·clamp(speed·trailLength, trailMinLength, trailMaxLength)·textureRatio,短轴 = size。
    // 默认值照 ObjectParser.cpp:1004-1006(length 0.05 / maxlength 10 / minlength 0)。
    var isSpriteTrail: Bool = false
    var trailLength: Float = 0.05
    var trailMaxLength: Float = 10
    var trailMinLength: Float = 0
    // 贴图原始高宽比 texH/texW(g_RenderVar1.w 的基),渲染建组时按真实贴图尺寸注入;
    // 每帧 textureRatio = (uvSc.y/uvSc.x)·trailTextureRatio(精灵表逐帧像素高宽比,CParticle.cpp:1936)。
    var trailTextureRatio: Float = 1
    // rope/ropetrail 渲染器(genericropeparticle):把按生成序连成链的粒子用 Catmull-Rom 样条插值
    // 成一条带状网格(而非散点精灵)。对照 CParticle.cpp:2098-2323 renderRope + genericropeparticle.geom。
    // subdivision = 每段细分数(默认 4,CParticle.h:240);uvScale 沿长度的 UV 重复;
    // uvScrolling = UV 随时间沿绳滚动;uvSmoothing = 按弧长分配 UV(需均匀寿命且不滚动)。
    // isRope 对应 lwe m_useRopeRenderer,**rope 与 ropetrail 都置位**(CParticle.cpp:36-48)。
    var isRope: Bool = false
    var ropeSubdivision: Int = 4
    var ropeUVScale: Float = 1
    var ropeUVScrolling: Bool = false
    var ropeUVSmoothing: Bool = true
    // ropetrail(renderer.name=="ropetrail")在 lwe 里与 rope **走完全相同的 renderRope 路径**——
    // 都把全部活粒子按生成序连成**一条**链(CParticle.cpp:36-48 m_useRopeRenderer 对两者都 true、
    // :182-186/:203-207 render 同调 renderRope)。lwe **没有**「逐粒子历史轨迹」这种实现:
    // m_ropeSegments 在 :47 赋值后全文再未被读取(grep 确认),m_trailLength 只作 renderVar0 透传(:1912)。
    // 故 isRopeTrail 仅是解析出的标记(给诊断用),**对删除/保序/渲染/UV 全部当 isRope 处理**;
    // ropeSegments / ropeTrailLength 同步仅作无害透传(对齐 lwe:不影响几何)。
    var isRopeTrail: Bool = false
    var ropeSegments: Int = 4        // lwe m_ropeSegments(:47 写入后未读取)— 仅透传,不影响几何
    var ropeTrailLength: Float = 2   // lwe m_trailLength(renderer.length;仅 renderVar0 透传 :1912)— 不影响几何
    // 折射粒子(combos.REFRACT=1,如玻璃上的雨滴):WE 里 albedo×屏幕底图,我们近似为
    // 低透明柔和扰动,不叠加 overbright(否则糊成白块)。
    var isRefract: Bool = false
    // animationmode==randomframe:精灵表每粒子固定随机帧(雨/雪),非逐帧播放。
    var randomFrame: Bool = false
    // 该粒子层是否排在 fullscreenlayer(后处理:bloom/filmgrain/localcontrast)**之上**。
    // WE 把 fullscreenlayer 当普通层:它只处理其**下方**已合成的画面;排在它上面的层(此雨屋的
    // 雨丝 idx9、水花 idx11-17)在后处理**之后**叠加,因此**不被 bloom**。我们的引擎原把后处理链
    // 放到全帧最后(把雨也 bloom 了),导致雨丝被辉光放大成又亮又硬的线(实测帧间 >20-motion 比真
    // WE 高 ~7×;视觉上雨丝清晰硬,而 WG 几乎柔到看不见)。按 WE 图层序:此类粒子后处理后再画。
    var aboveBloom: Bool = false
}

/// 单个活跃粒子。
private struct Particle {
    var pos: SIMD3<Float>
    var vel: SIMD3<Float>
    var color: SIMD3<Float>
    var alpha0: Float
    var size: Float
    var age: Float
    var life: Float
    var rotation: Float
    var angVel: Float
    var frame: Int          // 精灵表帧索引(单帧贴图恒为 0)
    var upright: Bool = false   // orientation=="upright"(水花竖立):rotation 锁 0、不自转、不受 angularmovement
    var spawnOrigin: SIMD2<Float> = .zero   // 拖尾粒子:诞生时的光标位置(画布像素)
    // oscillate 逐粒子状态(spawn 时随机一次;照 WE 的 per-particle frequency/phase)。
    var oscAFreq: Float = 0, oscAPhase: Float = 0
    var oscSFreq: Float = 0, oscSPhase: Float = 0
    // oscillateposition 逐粒子状态:**每个 oscPositions 配置一套**(支持多个 oscillateposition 各自独立摆动)。
    var oscPState: [OscPState] = []
    // ropetrail 逐粒子位置历史(world 画布像素,index 0=最新)。WE ropetrail 真义:每粒子保留若干历史点
    // 连成**自己的**独立拖尾(lwe Object.h:507「segments: number of history segments per particle」),
    // 而非把全部活粒子连成一条链。仅 isRopeTrail 维护;其余渲染器恒空。
    var hist: [SIMD2<Float>] = []
}

/// 单个 oscillateposition 配置的逐粒子随机状态(每个配置 spawn 时独立随机一次)。
private struct OscPState {
    var freq: SIMD3<Float> = .zero
    var scale: SIMD3<Float> = .zero
    var phase: SIMD3<Float> = .zero
}

/// CPU 粒子模拟器:发射 + 更新 + 输出渲染实例。
final class ParticleSimulator {
    var desc: ParticleEmitterDesc
    private var particles: [Particle] = []
    private var emitAccum: Float = 0
    private var rngState: UInt64
    // 发射器节奏状态(照 CParticle.cpp 的 lambda 捕获):delay 倒计时、duration 累积、instantaneous 单次爆发标志。
    private var delayTimer: Float = 0
    private var durationTimer: Float = 0
    private var instantaneousEmitted = false
    // mapsequence 的发射序号(跨该发射器所有粒子共享,到 count 回绕——形成圆周分布,CParticle.cpp:944/953)。
    private var mapSeqIndex = 0

    /// 鼠标拖尾:当前光标在画布像素中的位置(每帧由引擎更新)。nil = 不跟随。
    var cursorOrigin: SIMD2<Float>? = nil

    /// 当前活跃粒子数(诊断用)。
    var liveCount: Int { particles.count }

    // 精灵表(sprite sheet)参数:帧数、列数、每帧 UV 尺寸。单帧贴图 = (1,1,(1,1))。
    private let sheetFrames: Int
    private let sheetCols: Int
    private let sheetUVScale: SIMD2<Float>
    // TEXS 显式帧矩形 (u0,v0,uw,vh):非空则用它播放(优先于均匀网格)。
    private let frameRects: [SIMD4<Float>]
    private let frameDuration: Float        // 每帧秒数(动画速度)
    private var animTime: Float = 0          // 累积动画时间(驱动帧前进)
    var randomFrameMode = false              // animationmode==randomframe:每粒子固定随机帧(雨/雪)

    init(desc: ParticleEmitterDesc, seed: UInt64,
         sheetFrames: Int = 1, sheetCols: Int = 1, sheetUVScale: SIMD2<Float> = SIMD2(1, 1),
         frameRects: [SIMD4<Float>] = [], frameDuration: Float = 1.0/24) {
        self.desc = desc
        self.rngState = seed | 1
        self.delayTimer = desc.emitterDelay   // 发射器开喷前延迟(CParticle.cpp:416 delayTimer = emitter.delay)
        self.sheetFrames = max(1, sheetFrames)
        self.sheetCols = max(1, sheetCols)
        self.sheetUVScale = sheetUVScale
        self.frameRects = frameRects
        self.frameDuration = max(0.001, frameDuration)
        particles.reserveCapacity(desc.maxCount)
    }

    // 简单 xorshift,避免用被禁的 Math.random;确定性、可复现。
    private func rnd() -> Float {
        rngState ^= rngState << 13
        rngState ^= rngState >> 7
        rngState ^= rngState << 17
        return Float(rngState >> 40) / Float(1 << 24)   // [0,1)
    }
    private func rnd(_ a: Float, _ b: Float) -> Float { a + (b - a) * rnd() }
    private func rnd3(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(rnd(a.x,b.x), rnd(a.y,b.y), rnd(a.z,b.z))
    }
    /// 绕单位轴 k 旋转向量 v 角度 a(Rodrigues 公式,替代 glm::rotate)。
    private func rotate(_ v: SIMD3<Float>, _ k: SIMD3<Float>, _ a: Float) -> SIMD3<Float> {
        let c = cos(a), s = sin(a)
        return v * c + cross(k, v) * s + k * (dot(k, v) * (1 - c))
    }

    /// 分形布朗噪声(fBm):多个 octave 的 perlin 噪声按 amplitude(gain)/frequency(lacunarity)倍增叠加,
    /// 归一到 ~[-1,1]。供 remapvalue transformfunction=="fbmnoise" 用(lwe 无此算子,按真 WE 语义移植)。
    ///【WE 语义不确定:WE 的 fbm octave 数 / lacunarity / gain 无公开规范 → 取业界标准 fBm 约定:
    ///  octaves=4、lacunarity=2.0(每倍频频率 ×2)、gain=0.5(每倍频幅度 ×0.5);可接受近似,标为假设。】
    private static func fbm(_ p: SIMD3<Float>) -> Float {
        let octaves = 4
        let lacunarity: Double = 2.0
        let gain: Double = 0.5
        var freq: Double = 1.0
        var amp: Double = 0.5
        var sum: Double = 0.0
        var norm: Double = 0.0   // 累计幅度,末尾归一保持 ~[-1,1]
        let x = Double(p.x), y = Double(p.y), z = Double(p.z)
        for _ in 0..<octaves {
            sum += amp * WENoise.perlin(x * freq, y * freq, z * freq)
            norm += amp
            freq *= lacunarity
            amp *= gain
        }
        return norm > 0 ? Float(sum / norm) : 0
    }
    private var simTime: Float = 0   // 当前 sim 时间(turbVelRand 在 spawn 采 curl 用)

    /// WE 的窗口插值 helper(CParticle.cpp:39-48):life≤start 返 startValue、≥end 返 endValue、
    /// 中间按 (life-start)/(end-start) 线性插值。alphachange/colorchange 用它随生命比演化。
    private func fadeValue(_ life: Float, _ startTime: Float, _ endTime: Float, _ startValue: Float, _ endValue: Float) -> Float {
        if life <= startTime { return startValue }
        if life >= endTime { return endValue }
        let t = (life - startTime) / (endTime - startTime)
        return startValue + t * (endValue - startValue)
    }

    /// 精灵表当前帧。f = age/life = lifetimePos。
    /// 【WE 真义(2026-06-11 shader 铁证)】帧 = floor(frac(生命比 × sequencemultiplier) × n):
    /// 精灵表在粒子**一生中恰好循环 sequencemultiplier 次**,与 .tex 帧时长/实时 Hz 无关。
    /// 证据:genericparticle.vert:94 `ComputeSpriteFrame(frac(in_ParticleLifeTime),…)` 对 lifetime 属性取
    /// **frac()**——若 CPU 喂普通 [0,1) 生命比则 frac 是空操作;frac 存在的唯一理由=喂入值会超 1,
    /// 即 生命比×seqMult(鸟:0→30),frac 逐圈回绕 → 整生命循环 30 次 = 25s/30 ≈ 1.2Hz 自然扇翅 ✓。
    /// 曾两版皆错:①lwe 实时 age×seqMult/frameDuration(CParticle.cpp:279)→ 30Hz,60fps 下每渲染帧跳
    /// 8 精灵帧=翅膀抖动(用户报「翅膀幅度不对」);②「原生帧率」忽略 seqMult(丢 pkg 字段,碰巧
    /// 1Hz≈1.2Hz 近似对)。seqMult 缺省 1 = 整生命播一遍(水花等一次性动画的自然语义)。
    /// WP_SEQ_LWE=1 退回 lwe 实时循环(A/B 诊断)。
    private func frameIndex(p: Particle, f: Float, n: Int) -> Int {
        if randomFrameMode || desc.animationMode == "randomframe" {
            return p.frame % n                      // spawn 时定的随机帧,整生命不变
        }
        let seqMult = desc.sequenceMultiplier > 0 ? desc.sequenceMultiplier : 1
        if ProcessInfo.processInfo.environment["WP_SEQ_LWE"] != nil {
            let frame = p.age * seqMult / frameDuration
            let idx = Int(frame.truncatingRemainder(dividingBy: Float(n)))
            return idx < 0 ? idx + n : idx
        }
        if desc.animationMode == "once" {
            return min(Int(f * Float(n) * seqMult), n - 1)   // 播一遍并停在末帧(用 lifetimePos)
        }
        let cycle = max(0, (f * seqMult).truncatingRemainder(dividingBy: 1))   // frac(生命比×seqMult)
        return min(Int(cycle * Float(n)), n - 1)
    }

    /// 推进 dt 秒。time = 自场景开始的总时间(turbVelRand 噪声相位用)。
    /// starttime ≠ 延迟:WE 语义是「跳进模拟」(加载即呈现已运行 starttime 秒的稳态,由 warmup 实现),
    /// 运行期不做任何延迟门控。曾在此 guard time>=startTime 提前 return → 雪(starttime=15)开局 15s 空屏
    /// + 预热粒子被冻结,与 WE 开局满屏稳态雪完全不同(伊蕾娜夜莺「雪跟原版不同」主因之一)。
    func step(dt: Float, time: Float) {
        simTime = time
        let d = min(dt, 0.1)   // 防卡顿大跳
        animTime += d          // 精灵表帧动画时间(鸟扇翅膀等)

        // 更新已有粒子
        // 【审计修复】到寿删除从 O(n²) 的中部 remove(at:) 改为 O(1) 的 swap-remove(与末尾交换再 removeLast)。
        // 但 rope/ropetrail 渲染按「生成序连成一条链」依赖粒子顺序(lwe update() 对所有 rope 渲染器都做
        // 保序压缩,renderRope 注释 CParticle.cpp:2103「Array is already in spawn order」),swap-remove
        // 会打乱链序 → 该类发射器走有序删除;其余散点精灵与顺序无关,用 swap-remove。
        // lwe rope 与 ropetrail 走同一条 renderRope 路径(CParticle.cpp:36-48/182-186/203-207,
        // m_useRopeRenderer 对两者都 true),故二者删除策略一致:desc.isRope(=ropetrail 也置位)即判据。
        let preserveOrder = desc.isRope
        var i = 0
        while i < particles.count {
            particles[i].age += d
            if particles[i].age >= particles[i].life {
                if preserveOrder {
                    particles.remove(at: i)        // 有序删除:保持 rope 链的生成序(O(n) 但仅此类用)
                    continue
                } else {
                    let last = particles.count - 1
                    if i != last { particles[i] = particles[last] }   // swap-remove:与末尾交换
                    particles.removeLast()
                    continue                       // i 不前进,复检换上来的粒子
                }
            }
            // 【审计修复 #1】半隐式积分顺序:lwe movement 先 `pos += vel*dt`(用上一帧速度),**再**受力
            //(gravity/drag/turbulence/vortex/attract…在 movement 之后)。即各力对位置的影响**滞后一帧**。
            //(旧实现先累加全部力再积分位置 → 轨迹每帧抢先一帧、涡旋/重力弧更紧,与原版不同。)
            particles[i].pos += particles[i].vel * d   // lwe CParticle.cpp:1051 先积分位置
            particles[i].vel += desc.gravity * d * desc.ioSpeed   // lwe CParticle.cpp:1054 gravity*dt*speed(speed=instanceoverride.speed)
            if desc.drag > 0 { particles[i].vel *= max(0, 1 - desc.drag * d) }   // 速度阻力(clamp≥0 防反向)
            if desc.hasTurbulence {
                // curl-noise 流动力场(照 CParticle.cpp:1281-1296):噪声坐标 = pos(x 叠相位+时间漂移)×(scale×2),
                // curl 方向归一化×场速度×mask 加进速度。这是烟/雾/蒸汽卷曲流动的来源(之前完全没有→只会直线掉)。
                var np = particles[i].pos
                np.x += desc.turbPhase + desc.turbTimeScale * time
                np *= (desc.turbScale * 2)
                var cd = WENoise.curl(np)
                let len = simd_length(cd)
                if len > 0.0001 { cd = (cd / len) * desc.turbFieldSpeed }
                particles[i].vel += cd * desc.turbMask * d * desc.ioSpeed   // ×speedOverride(CParticle.cpp:1298)
            }
            if desc.hasVortex {
                // 绕 axis 的切向涡旋(标准模式,照 CParticle.cpp:1375-1457)。中心默认取发射器原点+offset
                // (我们没有控制点数据)。radialVector = pos-center(标准模式不投影,用全 3D 距离);
                // tangent = normalize(cross(axis, radial));速度按半径在 [inner,outer] 间 mix(speedInner,speedOuter);
                // vel += tangent·speed·dt·speed(io)。maintainDistance(flags 2)时再朝中心加 centerForce。
                let center = desc.emitterOrigin + desc.vortexOffset
                let axisLen = simd_length(desc.vortexAxis)
                let axis = axisLen > 0 ? desc.vortexAxis / axisLen : SIMD3<Float>(0, 0, 1)
                let toParticle = particles[i].pos - center
                // infiniteAxis(flags 1):投影掉轴向分量,只在垂直 axis 平面算(照 CParticle.cpp:1388-1392);否则全 3D。
                let radial = desc.vortexInfiniteAxis ? (toParticle - axis * simd_dot(toParticle, axis)) : toParticle
                let dist = simd_length(radial)
                let tang = cross(axis, radial)
                let tangLen = simd_length(tang)
                if tangLen > 0.001 {   // 否则粒子在轴上,跳过(照 CParticle.cpp:1398-1402)
                    let tangent = tang / tangLen
                    var speed: Float = 0
                    var radialForce = SIMD3<Float>(repeating: 0)
                    if desc.vortexRingShape {
                        // 环形速度场(照 CParticle.cpp:1408-1432):空心中心→0;环内→mix(inner,outer);
                        // 环外拉回距离内→减速 + 向环径向拉回;更远→0。
                        let ringInner = desc.vortexRingRadius - desc.vortexRingWidth * 0.5
                        let ringOuter = desc.vortexRingRadius + desc.vortexRingWidth * 0.5
                        if dist < ringInner {
                            speed = 0
                        } else if dist <= ringOuter {
                            let t = desc.vortexRingWidth > 0 ? (dist - ringInner) / desc.vortexRingWidth : 0
                            speed = desc.vortexSpeedInner + (desc.vortexSpeedOuter - desc.vortexSpeedInner) * t
                        } else if dist <= ringOuter + desc.vortexRingPullDistance {
                            let pullT = desc.vortexRingPullDistance > 0 ? (dist - ringOuter) / desc.vortexRingPullDistance : 0
                            speed = desc.vortexSpeedOuter * (1 - pullT)
                            if dist > 0.001 { radialForce = (-radial / dist) * desc.vortexRingPullForce * pullT }
                        } else {
                            speed = 0
                        }
                    } else {
                        // 标准模式 speed:disMid = outer-inner+0.1;dist<inner→speedInner、dist>outer→speedOuter、
                        // 否则 mix(speedInner,speedOuter, (dist-inner)/disMid)。CParticle.cpp:1434-1444。
                        let disMid = desc.vortexDistanceOuter - desc.vortexDistanceInner + 0.1
                        if disMid < 0 || dist < desc.vortexDistanceInner {
                            speed = desc.vortexSpeedInner
                        } else if dist > desc.vortexDistanceOuter {
                            speed = desc.vortexSpeedOuter
                        } else {
                            let t = (dist - desc.vortexDistanceInner) / disMid
                            speed = desc.vortexSpeedInner + (desc.vortexSpeedOuter - desc.vortexSpeedInner) * t
                        }
                    }
                    particles[i].vel += tangent * speed * d * desc.ioSpeed
                    particles[i].vel += radialForce * d * desc.ioSpeed
                    if desc.vortexMaintainDistance && dist > 0.001 {
                        particles[i].vel += (-radial / dist) * desc.vortexCenterForce * d * desc.ioSpeed
                    }
                }
            }
            for attract in desc.cpAttracts {
                // controlpointattract:阈值内朝控制点恒力吸引(照 CParticle.cpp:1492-1503)。
                // center 已按 io/worldSpace 解析为层局部(见 CPAttract);linkMouse 控制点 = 光标(运行期,
                // lwe CParticle.cpp:152「Mouse-linked CPs will have their position updated in update()」)。
                // threshold 取一半(CParticle.cpp:1476)。dist∈(0.001, threshold) 时 vel += dir·scale·dt·speedOverride。
                // scale<0 = 排斥(Bird.json cp1=鼠标:鸟群避开光标;cp2/3/4=世界路径锚点)。
                var center = attract.center
                if attract.linkMouse {
                    guard let cur = cursorOrigin else { continue }   // 无光标(headless 未传)→ 该力不施加
                    center = SIMD3((cur.x - desc.layerOrigin.x), (cur.y - desc.layerOrigin.y), 0) + attract.originOff
                }
                let toCenter = center - particles[i].pos
                let dist = simd_length(toCenter)
                let threshold = attract.threshold / 2
                if dist > 0.001 && dist < threshold {
                    // 力 = scale·(1 − d/r)·dir:**线性衰减到边缘归零**,不是 lwe 的半径内恒力
                    // (CParticle.cpp:1492 恒力 = lwe 逆向只摸到半径减半、漏了衰减)。
                    // 证据(2026-06-11 Postscript 候鸟流,WE 实机观察「到最后聚成一条线」):
                    // 数值模拟四种剖面,恒力 σ 28→68→111 发散(鸟被泡壁轰散=旧症状);线性衰减(r=threshold/2)
                    // σ 29→28→16 末段**收敛**、出口高度 542 正中 WE 区间——上下斥力泡成"软弹簧墙",
                    // 陷入多深推回多少 → 漏斗收束成单列。WP_CPATTRACT_CONST=1 退回 lwe 恒力(A/B)。
                    let falloff = Self.cpAttractConstForce ? 1 : (1 - dist / threshold)
                    particles[i].vel += (toCenter / dist) * attract.scale * falloff * d * desc.ioSpeed
                }
            }
            if desc.hasRemap {
                // remapvalue → output velocity:噪声值 t∈[0,1] 在 outputrangemin..max 间 mix,加到速度。
                // 噪声坐标按 source 选择(velocity=位置驱动 / speed=速度大小驱动),按 transforminputscale 缩放。
                // 噪声标量 ∈ ~[-1,1] → (n+1)/2 归一到 [0,1]。
                var np: SIMD3<Float>
                if desc.remapSourceSpeed {
                    // source=speed:用粒子速度大小 |vel| 作主驱动维,叠时间漂移。
                    //【WE 语义不确定:speed→噪声坐标的精确映射无公开规范,此处取 |vel|×inputScale 为 x 维 + 位置微扰为 y/z + 时间为 z 漂移,标为假设】
                    let spd = simd_length(particles[i].vel)
                    np = SIMD3(spd * desc.remapInputScale,
                               particles[i].pos.y * desc.remapInputScale,
                               particles[i].pos.z * desc.remapInputScale + simTime)
                } else {
                    // source=velocity(默认):位置驱动噪声场。
                    let p = particles[i].pos * desc.remapInputScale
                    np = SIMD3(p.x, p.y, p.z + simTime)
                }
                // transformfunction:fbmnoise=分形布朗(多倍频叠加)/ 否则单倍频 perlin(simplex 的 perlin 近似)。
                let n: Float = desc.remapFbm
                    ? ParticleSimulator.fbm(np)
                    : Float(WENoise.perlin(Double(np.x), Double(np.y), Double(np.z)))
                let t = max(0, min(1, (n + 1) * 0.5))
                let remapped = desc.remapOutputMin + (desc.remapOutputMax - desc.remapOutputMin) * t
                particles[i].vel += remapped * d * desc.ioSpeed
            }
            // (位置积分已在受力之前完成,见上方 #1;此处不再重复积分。)
            // oscillateposition:**多个配置各自独立 apply**(对齐 lwe operator 列表逐个执行,CParticle.cpp:1001-1002)。
            // 每个配置:位置振荡(cos 摆动的导数 = -sin × dt,逐轴 freq/scale/phase × mask)。对照 CParticle.cpp:1625-1634。
            if !desc.oscPositions.isEmpty {
                let t = particles[i].age
                for (ci, cfg) in desc.oscPositions.enumerated() where ci < particles[i].oscPState.count {
                    let st = particles[i].oscPState[ci]
                    let w = st.freq
                    let sn = SIMD3(sin(w.x*t + st.phase.x),
                                   sin(w.y*t + st.phase.y),
                                   sin(w.z*t + st.phase.z))
                    particles[i].pos += (-st.scale * w * sn * d) * cfg.mask
                }
            }
            // 【审计修复 #2/#3】angularmovement:lwe CParticle.cpp:1088-1100 顺序 = 先积分 rotation(用上一帧角速度)、
            // 再受力、再角阻力;且 rotation **仅在 angularmovement 算子存在时**积分(lwe 全文唯一的 rotation+= 在此算子内,
            // 没有该算子 → 角度恒为 spawn 时的 rotationrandom 值)。旧实现顺序反了 + 无条件积分。
            if desc.hasAngularMovement && !particles[i].upright {
                particles[i].rotation += particles[i].angVel * d * desc.ioSpeed
                particles[i].angVel += desc.angularForceZ * d * desc.ioSpeed
                if desc.angularDragZ != 0 { particles[i].angVel *= max(0, 1 - desc.angularDragZ * d) }
            }
            // ropetrail:逐粒子位置历史(WE 真义,lwe Object.h:507「segments = number of history segments
            // per particle」)。每帧把当前 world 推入 hist 头部,保留最近 ropeSegments+1 个点 → 渲染期每粒子
            // 用自己的 hist 连成**独立**短拖尾(雨=每滴一条雨丝)。lwe 把 rope/ropetrail 都退化成「全部活粒子
            // 连一条链」(m_ropeSegments 写入后从未读取 CParticle.cpp:47),对 1000 个独立雨滴 → 全屏网格乱线;
            // 故此处按 WE 真义维护逐粒子历史。纯 rope(非 trail)仍走全局连链,见 ropeVertices()。
            if desc.isRopeTrail {
                particles[i].hist.insert(visualState(particles[i]).world, at: 0)
                let cap = max(2, desc.ropeSegments + 1)
                if particles[i].hist.count > cap { particles[i].hist.removeLast(particles[i].hist.count - cap) }
            }
            i += 1
        }

        // 发射新粒子。拖尾粒子只在光标已知时发射(没光标位置就不喷)。
        if desc.followsCursor && cursorOrigin == nil { return }

        // 发射器节奏(照 CParticle.cpp:424-479):先 delay 倒计时,再 duration 到期停喷;
        // instantaneous 诞生瞬间一次性爆发;之后才是 rate 持续喷。
        if delayTimer > 0 {
            delayTimer -= d
            return
        }
        if desc.emitterDuration > 0 {
            durationTimer += d
            if durationTimer >= desc.emitterDuration { return }
        }

        // instantaneous:第一帧(delay 结束后)一次性补发 N 个。
        var toEmit = 0
        if desc.emitterInstantaneous > 0 && !instantaneousEmitted {
            toEmit = desc.emitterInstantaneous
            instantaneousEmitted = true
        }
        // rate 持续发射(累加器)。
        if desc.rate > 0 {
            emitAccum += desc.rate * d
            let rateEmit = Int(emitAccum)
            emitAccum -= Float(rateEmit)
            toEmit += rateEmit
        }

        // limitOnePerFrame(emitter flags&2):每次发射至多 1 个,防绳类同点堆叠。CParticle.cpp:474/575。
        if desc.emitterLimitOnePerFrame { toEmit = min(toEmit, 1) }
        var n = toEmit
        while n > 0, particles.count < desc.maxCount {
            n -= 1
            particles.append(spawn())
        }
    }

    /// 预热:让粒子系统达到稳态(避免开场空屏),模拟 warmup 秒。
    /// **步数上限 300(=10s)**:某些壁纸的 lifetimeMax 异常大(如上百秒),seconds×30 会爆成几万~几十万步,
    /// 每步还 spawn/age 大量粒子 → 加载时 100% CPU 卡死(实测某工坊壁纸 emitter)。10s 预热对绝大多数已足够。
    /// seconds 非有限(NaN/Inf)时跳过(否则 Int(NaN) 直接 trap 崩溃)。
    func warmup(seconds: Float) {
        guard seconds.isFinite, seconds > 0 else { return }
        // starttime>0(雪15/雾2/雨1 等天气预设)= WE「跳进模拟」:加载即呈现已运行 starttime 秒的稳态。
        // 作者用它跳过填充期:snowperspective rate=25 × maxcount=360 填满恰需 ≈14.4s ≈ starttime 15。
        // 此前误解为「延迟 15s 发射」并禁预热 → 开雪 15s 空屏再 15s 慢慢变密,与 WE 截然不同。
        // lwe 解析了 starttime 但完全未用(Object.h:561),此处按 WE 真义实现(调用方保证 seconds ≥ startTime)。
        // 步数上限 900(=30s):防 lifetimeMax 异常大的壁纸把加载拖死;真实预设(≤15s)足够。
        let step: Float = 1.0 / 30
        var t: Float = 0
        var n = min(900, Int((seconds / step).rounded()))
        while n > 0 { self.step(dt: step, time: t); t += step; n -= 1 }
    }

    private func spawn() -> Particle {
        // 发射初速度(累加式:emitter 给一份,velocityrandom/turbVelRand 再 += 上去,照 WE)。
        var vel = SIMD3<Float>(0, 0, 0)
        var pos: SIMD3<Float>
        if desc.isBox {
            // boxrandom 对称采样(照 CParticle.cpp:493-506):每轴 rand(distMin,distMax),50% 翻负号
            // (distMin>0 → 盒中心空洞),再乘 directions(Y 翻转)。emitter 不设速度,由 initializer 给。
            let flippedDirs = SIMD3(desc.directionsVec.x, -desc.directionsVec.y, desc.directionsVec.z)
            var randomPos = SIMD3<Float>(0, 0, 0)
            for axis in 0..<3 {
                var dv = rnd(desc.distanceMinVec[axis], desc.distanceMaxVec[axis])
                if rnd() < 0.5 { dv = -dv }   // 随机翻负号居中
                randomPos[axis] = dv
            }
            randomPos *= flippedDirs
            pos = desc.emitterOrigin + randomPos
        } else {
            // sphererandom(照 CParticle.cpp:599-643):flags&4==0 → 2D 圆盘(面积均匀 sqrt),
            // 置位 → 3D 球壳(体积均匀 cbrt)。distancemin/max 用 .x 当标量半径,乘 directions,再按 sign 强制正负。
            // 【审计修复】半径区间 NaN 兜底:规整为非负且 lo≤hi,避免 minR>maxR 或为负时
            // sqrt(rnd(minR²,maxR²))/cbrt(...) 取到负值开方/立方根出 NaN,污染整个位置。
            let r0 = max(0, desc.distanceMinVec.x)
            let r1 = max(0, desc.distanceMaxVec.x)
            let minR = min(r0, r1)
            let maxR = max(r0, r1)
            var randomPos: SIMD3<Float>
            if (desc.particleFlags & 4) == 0 {
                // 2D 圆盘 + 随机 Z 偏移;sqrt(rand(minR², maxR²)) 保证环面面积均匀。
                let angle = rnd(0, 2 * .pi)
                let radiusXY = (rnd(minR * minR, maxR * maxR)).squareRoot()
                randomPos = SIMD3(radiusXY * cos(angle), radiusXY * sin(angle), rnd(-maxR, maxR))
                randomPos *= desc.directionsVec
            } else {
                // 3D 球壳:cosTheta 均匀 → 方向均匀;cbrt(rand(minR³,maxR³)) 体积均匀。
                let theta = rnd(0, 2 * .pi)
                let cosT = rnd(-1, 1)
                let sinT = (1 - cosT * cosT).squareRoot()
                randomPos = SIMD3(sinT * cos(theta), sinT * sin(theta), cosT)
                let radius = cbrtf(rnd(minR * minR * minR, maxR * maxR * maxR))
                randomPos *= radius
                randomPos *= desc.directionsVec
            }
            // sign(emitter.sign,ivec3):每轴强制正负。1→abs、-1→-abs、0→保持(CParticle.cpp:636-643)。
            for i in 0..<3 {
                if desc.emitterSign[i] == 1 { randomPos[i] = abs(randomPos[i]) }
                else if desc.emitterSign[i] == -1 { randomPos[i] = -abs(randomPos[i]) }
            }
            pos = desc.emitterOrigin + randomPos
            // emitter 自带速度(emitter.speedmin/max):沿外向 normalize(randomPos)·rand(speedMin,speedMax)。
            // 仅当设了 speed 才用,否则交给 initializer。对照 CParticle.cpp:647-656。
            if desc.emitterSpeedMax > 0 || desc.emitterSpeedMin != 0 {
                let len = simd_length(randomPos)
                let dir = len > 0 ? randomPos / len : SIMD3<Float>(0, 1, 0)
                vel += dir * rnd(desc.emitterSpeedMin, desc.emitterSpeedMax)
            }
        }
        // 【审计修复】位置 NaN 兜底:无论 box/sphere 哪条采样路径,若 distance 数据病态导致 pos 出现
        // 非有限分量(NaN/Inf),回退到发射器原点,避免 NaN 位置传播到 trail / rope 顶点。
        if !pos.x.isFinite || !pos.y.isFinite || !pos.z.isFinite { pos = desc.emitterOrigin }
        // velocityrandom 初始化器(CParticle.cpp:790-792):vel = rand3(min,max)×speedOverride,累加。
        // **不翻 Y**:lwe 的 v.y=-v.y 是它 y 向下模拟空间的坐标补偿,我们 matOrtho 是 y 向上,照搬会把
        // 雨(authored y=-5000=下落)变成 +5000 上升,且与 gravity(不翻 Y)矛盾。同「角度符号照搬 lwe 取负→反」教训。
        if desc.hasVelRandom {
            vel += rnd3(desc.velMin, desc.velMax) * desc.ioSpeed
        }
        // mapsequencearoundcontrolpoint(CParticle.cpp:946-981):**覆盖** pos/vel——粒子诞生在控制点
        // (followsCursor 时控制点=光标,由 spawnOrigin 在渲染期叠加,故 local pos = emitterOrigin),
        // 速度按发射序号在圆周均匀分配方向(扇形径向喷发)×speedOverride。不翻 Y(我们 Y-up,同上)。
        if desc.hasMapSeq {
            let count = max(1, desc.mapSeqCount)
            let angle = (Float(mapSeqIndex) / Float(count)) * 2 * .pi
            mapSeqIndex = (mapSeqIndex + 1) % count
            pos = desc.emitterOrigin
            let s = rnd3(desc.mapSeqSpeedMin, desc.mapSeqSpeedMax)
            let ca = cos(angle), sa = sin(angle)
            vel = SIMD3<Float>(ca * s.x - sa * s.y, sa * s.x + ca * s.y, s.z) * desc.ioSpeed
        }
        // 图层 Z 旋转(WE 的 layer angles,弧度)**不在此处转速度**。
        // 核实参考引擎 CParticle.cpp:1839-1855:layer angles 是装进 m_modelMatrix(平移到层原点→
        // rotate(-angles.z)→scale),再 m_mvpMatrix = viewProj × modelMatrix 整层应用;粒子 position 是
        // 在层局部系积分(velocity 不单独转)后整片随 modelMatrix 绕层原点旋转。即 WE「旋转整层」。
        // 旧实现只转速度 → 给雨加恒定向左分量(vy≈-4250 × sin(-0.145) ⇒ vx 多 -614),粒子整体左漂,
        // 而水平线状发射区(directions="1 0 0")没跟着转 → 右边掏空。
        // 改为忠实 WE:速度保持层局部(直下),位置在 visualState 里绕层原点旋转 layerAngleZ,精灵朝向也加该角。
        if desc.hasTurbVelRand {
            // curl 噪声给**初始速度方向**(空间相干:邻近粒子同向流);限制在 forward±scale/2 角内,
            // 可绕 right 轴 offset 倾斜,2D 粒子投影到 XY。照 CParticle.cpp:875-931。
            var np = pos * 0.1
            np += SIMD3(repeating: simTime * desc.tvTimeScale)
            let phase = rnd(desc.tvPhaseMin, desc.tvPhaseMax)
            var result = WENoise.curl(np + SIMD3(phase, phase * 0.7, phase * 1.3))
            let fwd = normalize(desc.tvForward)
            let len = length(result)
            result = len < 0.0001 ? fwd : result / len
            // 湍流方向:默认 lwe 钳制(scale 当 ±scale/2 锥角)。曾试 blend=normalize(forward+curl)(指标更接近
            // WE 采集真值 H262 vs 钳制105/WE~200)但用户实机否决("乱飘"=逐粒子方向散导致 rope 抖动),已回滚。
            // WP_TURB_BLEND=1 / WP_TURB_FREECONE=1 仅作诊断。眼焰形态与 WE 的残差(焰羽高度)留观。
            let useBlend = ProcessInfo.processInfo.environment["WP_TURB_BLEND"] != nil
            let freeCone = ProcessInfo.processInfo.environment["WP_TURB_FREECONE"] != nil
            if useBlend {
                let bl = fwd + result
                let bln = length(bl)
                if bln > 0.0001 { result = bl / bln }
            }
            if !useBlend && !freeCone, desc.tvScale < 2 {
                let ang = acos(max(-1, min(1, dot(result, fwd)))) / .pi
                let maxAng = desc.tvScale / 2
                if ang > maxAng && maxAng > 0.0001 {
                    let ax = cross(result, fwd); let axLen = length(ax)
                    if axLen > 0.0001 { result = rotate(result, ax / axLen, (ang - maxAng) * .pi) }
                }
            }
            if abs(desc.tvOffset) > 0.0001 { result = rotate(result, normalize(desc.tvRight), -desc.tvOffset) }
            result.z = 0                                  // 2D 粒子投影到 XY 平面
            let l2 = length(result); if l2 > 0.0001 { result /= l2 }
            // ⭐湍流初速**默认不乘** instanceoverride.speed(2026-06-10,御剑眼焰实测定):
            //   lwe 乘(CParticle.cpp:928)→ 眼焰 0.6×250=150px/s,亮区缩在内眼角(用户报"偏左");
            //   不乘(全速 250)→ 焰延伸 X[2166,2430] 亮区落眼尾、射向右上 = WE 实况(用户:"从右眼尾射向右上")。
            //   判定 lwe 此处 ≠ 真 WE(同 ropetrail 先例:lwe 实现≠WE 真义)。WP_TURB_IOSPEED=1 退回 lwe 行为(A/B)。
            //   ⚠️库级影响:所有 turbulentvelocityrandom + speed override 的粒子(烟/光等)初速回到 pkg 原值。
            let turbSpeedScale = ProcessInfo.processInfo.environment["WP_TURB_IOSPEED"] != nil ? desc.ioSpeed : 1
            vel += result * rnd(desc.turbSpeedMin, desc.turbSpeedMax) * turbSpeedScale
        }
        // 精灵朝向(WE ComputeParticleTangents,common_particles.h:21):普通精灵恒用 **rotation**
        // (rotationrandom 初始角 + angularvelocity 演化),**不对齐速度**。速度对齐只属 TRAILRENDERER
        // (rope/ropetrail,走 ropeVertices 单独路径)。已删除原 `speed>500` 臆造的「定向粒子对齐速度」近似
        // ——那会把高速的雪/尘误判成雨丝对齐速度,非 WE 判据。
        // rotationrandom 初始角:WE 3 轴随机 × speedOverride,精灵单轴取 .z;**无 rotationrandom → 0**
        // (WE 真值:rotation 默认 0,不随机。旧代码退 rnd(0,2π) 会让无 rotationrandom 的雨/条纹乱指,非 WE)。
        let rotRandomZ = desc.hasRotRandom
            ? rnd3(desc.rotMin, desc.rotMax).z * desc.ioSpeed
            : 0
        // orientation=="upright"(水花):精灵竖直站立 → rotation=0、不自转、跳过 angularmovement。
        let rot: Float = desc.orientationUpright ? 0 : rotRandomZ
        // angularvelocityrandom:取 .z,带 exponent 偏置(pow(t,exp)),× speedOverride。CParticle.cpp:822-828。
        let angVelInit: Float = desc.hasAngularVel
            ? (desc.angVelMin + pow(rnd(), desc.angVelExponent) * (desc.angVelMax - desc.angVelMin)) * desc.ioSpeed
            : 0
        // colorrandom:WE 真义 = 单个随机 t 在 min→max 两色**连线**上取一点(同乘三通道)。
        // lwe 逐通道独立随机(Maths::randomVec3)→ 雪 white(255,255,255)↔灰蓝(95,98,100) 会随机出
        // 绿/紫/红「彩虹碎屑」,与 WE 白雪截然不同(伊蕾娜夜莺雪天实证)。两色同色相时两种算法无差;
        // 异色时单参数=色带、逐通道=色立方体角,设计者语义是前者。lwe≠真WE 又一处(同 ropetrail 先例)。
        // WP_COLORRAND_PERCH=1 退回 lwe 逐通道(A/B 诊断)。
        let spawnColor: SIMD3<Float>
        if ProcessInfo.processInfo.environment["WP_COLORRAND_PERCH"] != nil {
            spawnColor = rnd3(desc.colorMin, desc.colorMax)
        } else {
            let t = rnd(); spawnColor = desc.colorMin + (desc.colorMax - desc.colorMin) * t
        }
        var p = Particle(
            pos: pos,
            vel: vel,
            color: spawnColor,
            alpha0: rnd(desc.alphaMin, desc.alphaMax),
            // WE:size=(min+pow(t,exponent)·(max-min))·sizeOverride/2(照 lwe CParticle.cpp:738)。
            // 此值即精灵 quad 全宽(WE 实测,见 instances() spriteHalfLegacy 注释);rope 带按 ±size 展开。
            size: (desc.sizeMin + pow(rnd(), desc.sizeExponent) * (desc.sizeMax - desc.sizeMin)) * desc.ioSize / 2,
            age: 0,
            // 【审计修复】life NaN 兜底:若 pkg 数据给 0(lifetimeMin=max=0),后续 age/life=NaN 会污染
            // size/alpha/frame。钳到极小正值,保证除法有限。
            life: max(0.0001, rnd(desc.lifetimeMin, desc.lifetimeMax) * desc.ioLifetime),
            rotation: rot,
            // upright(水花竖立):禁用自转(angVel=0)且被 angularmovement 跳过。
            angVel: desc.orientationUpright ? 0 : angVelInit,
            frame: sheetFrames > 1 ? Int(rnd(0, Float(sheetFrames))) % sheetFrames : 0,
            upright: desc.orientationUpright,
            // 拖尾粒子:诞生瞬间记下光标位置;之后粒子在此处独立漂移/淡出。
            spawnOrigin: cursorOrigin ?? .zero
        )
        // oscillate 逐粒子随机一次(照 CParticle.cpp:1531;phase = rand(phaseMin, phaseMax+2π))。
        let tau = 2 * Float.pi
        if desc.hasOscAlpha {
            p.oscAFreq = rnd(desc.oscAFreqMin, desc.oscAFreqMax)
            p.oscAPhase = rnd(desc.oscAPhaseMin, desc.oscAPhaseMax + tau)
        }
        if desc.hasOscSize {
            p.oscSFreq = rnd(desc.oscSFreqMin, desc.oscSFreqMax)
            p.oscSPhase = rnd(desc.oscSPhaseMin, desc.oscSPhaseMax + tau)
        }
        // 每个 oscillateposition 配置各自随机一套逐粒子 freq/scale/phase(对齐 lwe 逐 operator 独立初始化,
        // CParticle.cpp:1611-1618;phase = rand(phaseMin, phaseMax+2π))。
        if !desc.oscPositions.isEmpty {
            p.oscPState = desc.oscPositions.map { cfg in
                OscPState(
                    freq:  rnd3(SIMD3(repeating: cfg.freqMin),  SIMD3(repeating: cfg.freqMax)),
                    scale: rnd3(SIMD3(repeating: cfg.scaleMin), SIMD3(repeating: cfg.scaleMax)),
                    phase: rnd3(SIMD3(repeating: cfg.phaseMin), SIMD3(repeating: cfg.phaseMax + tau)))
            }
        }
        return p
    }

    /// 单个粒子的可见状态:世界像素位置 + 当前 size + 颜色 + alpha,应用全部 size/alpha/color 算子。
    /// instances()(精灵散点)与 ropeVertices()(rope 带状)共用同一份算子,避免两条渲染路径漂移。
    private func visualState(_ p: Particle) -> (world: SIMD2<Float>, size: Float, col: SIMD3<Float>, alpha: Float) {
        let f = p.age / p.life
        var a = p.alpha0
        // alpha 只用 pkg 里的真实数据:alphafade operator(fadeintime/fadeouttime)+ instanceoverride.alpha。
        // 不自造任何凭感觉凑的全局系数。WE 不过曝靠真实 maxcount/size/alpha/贴图亮度(都已从 pkg 读入照用)。
        if desc.hasAlphaFade {
            // WE alphafade:fadeintime/fadeouttime 是**归一化生命比** [0,1](默认 0.5/0.5)。
            // [0,fadeIn] 线性淡入 0→1、(fadeIn,fadeOut] 满、(fadeOut,1] 线性淡出 1→0。CParticle.cpp:1134-1144。
            if desc.fadeInTime > 0, f <= desc.fadeInTime {
                a *= f / desc.fadeInTime
            } else if desc.fadeOutTime < 1, f > desc.fadeOutTime {
                a *= max(0, 1 - (f - desc.fadeOutTime) / (1 - desc.fadeOutTime))
            }
        }
        if desc.hasAlphaChange {
            // alphachange:alpha = initial.alpha × fadeValue(归一化生命比窗口插值)。CParticle.cpp:1204-1206。
            a *= fadeValue(f, desc.alphaChangeStartTime, desc.alphaChangeEndTime,
                           desc.alphaChangeStartValue, desc.alphaChangeEndValue)
        }
        if desc.hasOscAlpha {
            // 透明度振荡(萤火虫闪烁):× mix(scaleMin,scaleMax,(cos+1)/2)。CParticle.cpp:1542。
            let cosv = (cos(p.oscAFreq * p.age + p.oscAPhase) + 1) * 0.5
            a *= desc.oscAScaleMin + (desc.oscAScaleMax - desc.oscAScaleMin) * cosv
        }
        a *= desc.layerAlpha   // 图层级整体透明度(instanceoverride.alpha)
        var col = p.color
        if desc.hasColorChange {
            // colorchange:逐通道窗口插值,color = initial.color × vec3(各通道 fadeValue)。CParticle.cpp:1238-1242。
            col = col * SIMD3(
                fadeValue(f, desc.colorChangeStartTime, desc.colorChangeEndTime, desc.colorChangeStartValue.x, desc.colorChangeEndValue.x),
                fadeValue(f, desc.colorChangeStartTime, desc.colorChangeEndTime, desc.colorChangeStartValue.y, desc.colorChangeEndValue.y),
                fadeValue(f, desc.colorChangeStartTime, desc.colorChangeEndTime, desc.colorChangeStartValue.z, desc.colorChangeEndValue.z))
        }
        var s = p.size
        // 【审计修复 #4】sizechange = 初始 size × 窗口 fadeValue(含 start/end time 钳制),非全寿命线性 ramp。
        // 对照 lwe CParticle.cpp:1172-1178(size = initial × fadeValue(lifePos, startTime, endTime, startVal, endVal))。
        if desc.hasSizeChange {
            s *= fadeValue(f, desc.sizeChangeStartTime, desc.sizeChangeEndTime, desc.sizeChangeStart, desc.sizeChangeEnd)
        }
        if desc.hasOscSize {
            // 尺寸振荡(星星呼吸):size × mix(scaleMin,scaleMax,(cos+1)/2)。CParticle.cpp:1582。
            let cosv = (cos(p.oscSFreq * p.age + p.oscSPhase) + 1) * 0.5
            s *= desc.oscSScaleMin + (desc.oscSScaleMax - desc.oscSScaleMin) * cosv
        }
        // 图层 scale 只缩放**粒子模拟域**(发射器原点/喷洒半径/位移轨迹),**不**缩放 size(WE billboard 世界像素直径)。
        // 逐轴各向异性:WE modelMatrix 用完整 vec3 glm::scale 各轴独立缩 p.position(CParticle.cpp:1840/1851),
        // 雨水花层 scale=(0.848,0.10) 本该是贴地扁椭圆(垂直半幅 ×0.10),取标量同乘会被错渲成圆球。
        let posScale = desc.layerScale
        let base = desc.followsCursor ? p.spawnOrigin : desc.layerOrigin   // 拖尾以诞生时光标为基,其余用图层原点
        // 图层 Z 旋转(WE m_modelMatrix 绕层原点旋转整层,CParticle.cpp:1844-1851):把粒子的层局部偏移
        // (p.pos 逐轴×posScale)绕 base 旋转 layerAngleZ,再加回 base。粒子速度保持层局部(直下),整片随层倾斜
        // 但绕原点对称 → 斜雨帘左右覆盖一致(不再右边掏空)。符号用 +angleZ CCW,与 matModel(SceneRenderEngine
        // 对图层贴图同样直接用 +弧度,非 lwe 的 -angles.z;两者坐标系 Y 朝向不同)一致。
        // 顺序:先逐轴 scale → 再绕原点旋转 +layerAngleZ → 加 base(scale 在 rotate 内层,匹配 WE translate×rotate×scale)。
        var off = SIMD2(p.pos.x * posScale.x, p.pos.y * posScale.y)
        if desc.layerAngleZ != 0 {
            let ca = cos(desc.layerAngleZ), sa = sin(desc.layerAngleZ)
            off = SIMD2(off.x * ca - off.y * sa, off.x * sa + off.y * ca)
        }
        let world = SIMD2(base.x + off.x, base.y + off.y)
        // WE 末尾 `color.rgb *= g_Overbright`(genericparticle.frag:119/genericropeparticle.frag:62)。
        // col 即 v_Color(rgb);折进 col 等价 `tex × col × overbright`,sprite/rope 两路共用此函数一处生效。
        return (world, s, col * desc.overbright, a)
    }

    /// rope/ropetrail 带状网格(照 CParticle.cpp:2098-2323 renderRope + genericropeparticle.geom)。
    /// 返回三角形列表(每子段 6 顶点),坐标已在画布像素世界系。
    /// lwe 对 **rope 与 ropetrail 走同一条 renderRope 路径**(CParticle.cpp:36-48 m_useRopeRenderer
    /// 对两者都 true、:182-186/:203-207 render dispatch 同调 renderRope):把**全部活粒子按生成序**
    /// (index 0=最老,update() 保序压缩,见 :2103-2105)连成**一条**链——并没有「逐粒子历史轨迹」
    /// 这种东西(m_ropeSegments 写入后全文未再读取 :47/grep 确认,m_trailLength 仅 renderVar0 透传 :1912)。
    /// 走 appendRibbon:Catmull-Rom 细分 + 每子段两端 right=normalize(rot90(central-diff 切向))×size
    /// 居中展带(geometry-shader 真路径 start/end±trailRight)。切向退化(节点重合)时 right=0,带塌成零面积(无 NaN)。
    func ropeVertices() -> [RopeVertex] {
        var out: [RopeVertex] = []
        if desc.isRopeTrail {
            // ropetrail:**每粒子**用自己的位置历史连成一条独立拖尾(WE 真义,lwe Object.h:507 segments=每粒子
            // 历史段数)。1000 个独立雨滴 → 1000 条独立短雨丝(而非把它们连成一条全屏乱线)。
            // 沿 trail 各点用粒子当前 size/color;UV 沿长度由 appendRibbon + 纹理(halo)决定渐隐。
            for p in particles {
                let h = p.hist
                guard h.count >= 2 else { continue }   // 刚 spawn(<2 历史点)不画,等积累
                let vs = visualState(p)
                let nodeSize = [Float](repeating: vs.size, count: h.count)
                let nodeCol = [SIMD4<Float>](repeating: SIMD4(vs.col, vs.alpha), count: h.count)
                appendRibbon(into: &out, nodePos: h, nodeSize: nodeSize, nodeCol: nodeCol)
            }
            return out
        }
        // 纯 rope(闪电/绳索类,常配 controlpoints):全部活粒子按生成序连成**一条**链
        // (lwe renderRope,CParticle.cpp:2105/2120/2139-2160)。
        guard particles.count >= 2 else { return [] }
        let n = particles.count
        var nodePos = [SIMD2<Float>](repeating: .zero, count: n)
        var nodeSize = [Float](repeating: 0, count: n)
        var nodeCol = [SIMD4<Float>](repeating: .zero, count: n)
        for i in 0..<n {
            let vs = visualState(particles[i])
            nodePos[i] = vs.world; nodeSize[i] = vs.size; nodeCol[i] = SIMD4(vs.col, vs.alpha)
        }
        appendRibbon(into: &out, nodePos: nodePos, nodeSize: nodeSize, nodeCol: nodeCol)
        return out
    }

    /// 把一条节点链(已在画布像素世界系)用 Catmull-Rom 细分 + 切向法展成居中带,追加到 out。
    /// 照 CParticle.cpp:2109 renderRope(样条 :2135-2171、UV :2173-2203)+ genericropeparticle 着色器
    /// (right = normalize(cross(eyeDir=+Z, 切向)) × size,即 rot90(tangent),:200-256)。
    private func appendRibbon(into out: inout [RopeVertex],
                              nodePos: [SIMD2<Float>], nodeSize: [Float], nodeCol: [SIMD4<Float>]) {
        let n = nodePos.count
        guard n >= 2 else { return }
        let numSegments = n - 1
        let subdivision = max(1, desc.ropeSubdivision)

        func catmullRom(_ p0: SIMD2<Float>, _ p1: SIMD2<Float>, _ p2: SIMD2<Float>, _ p3: SIMD2<Float>, _ t: Float) -> SIMD2<Float> {
            let t2 = t * t, t3 = t2 * t
            let a: SIMD2<Float> = p1 * 2
            let b: SIMD2<Float> = (p2 - p0) * t
            let cVec: SIMD2<Float> = (p0 * 2) - (p1 * 5) + (p2 * 4) - p3
            let c: SIMD2<Float> = cVec * t2
            let dVec: SIMD2<Float> = (p1 * 3) - (p2 * 3) + p3 - p0
            let d: SIMD2<Float> = dVec * t3
            return (a + b + c + d) * 0.5
        }
        let totalPoints = numSegments * subdivision + 1
        var sp = [SIMD2<Float>](repeating: .zero, count: totalPoints)
        var ss = [Float](repeating: 0, count: totalPoints)
        var sc = [SIMD4<Float>](repeating: .zero, count: totalPoints)
        for i in 0..<numSegments {
            let p1 = nodePos[i], p2 = nodePos[i + 1]
            let p0 = i > 0 ? nodePos[i - 1] : p1
            let p3 = i + 2 < n ? nodePos[i + 2] : p2
            for k in 0..<subdivision {
                let t = Float(k) / Float(subdivision)
                let idx = i * subdivision + k
                sp[idx] = catmullRom(p0, p1, p2, p3, t)
                ss[idx] = nodeSize[i] + (nodeSize[i + 1] - nodeSize[i]) * t
                sc[idx] = nodeCol[i] + (nodeCol[i + 1] - nodeCol[i]) * t
            }
        }
        sp[totalPoints - 1] = nodePos[n - 1]
        ss[totalPoints - 1] = nodeSize[n - 1]
        sc[totalPoints - 1] = nodeCol[n - 1]

        // UV 沿长度:usableLength = totalSubSegments / uvScale;点 i 的纹理 v = 1 - i/usableLength。CParticle.cpp:2173-2183。
        let totalSub = totalPoints - 1
        let uvScale = desc.ropeUVScale > 0 ? desc.ropeUVScale : 1
        let usableLength = Float(totalSub) / uvScale
        // lwe CParticle.cpp:2187:仅当 smoothing 开、**所有粒子寿命一致**(min==max)、且未滚动时才按弧长分配 UV。
        let uniformLifetimes = desc.lifetimeMin == desc.lifetimeMax
        let useSmoothing = desc.ropeUVSmoothing && uniformLifetimes && !desc.ropeUVScrolling
        var cumArc = [Float](repeating: 0, count: totalPoints)
        var totalArc: Float = 0
        if useSmoothing {
            for i in 1..<totalPoints { totalArc += simd_distance(sp[i], sp[i - 1]); cumArc[i] = totalArc }
        }
        // UV 滚动:lwe CParticle.cpp:2203 真值 = fmod(g_Time,10000) × usableLength(注释「1 UV cycle per second」)。
        // ∵ trailPos 后续 += scrollOffset 再 /usableLength,故每秒恰好平移 1 个完整 UV 周期。
        // (撤回上一轮误把 ×usableLength 当「量纲错误」改成 ×0.5 的改动——原式本就是 lwe 真值。)
        let scrollOffset: Float = (desc.ropeUVScrolling && usableLength > 0)
            ? simTime.truncatingRemainder(dividingBy: 10000) * usableLength : 0
        func vAt(_ i: Int) -> Float {
            var trailPos: Float
            if useSmoothing && totalArc > 0 { trailPos = cumArc[i] / totalArc * Float(totalSub) }
            else { trailPos = Float(i) }
            trailPos += scrollOffset
            return usableLength > 0 ? 1 - trailPos / usableLength : 0
        }

        // right = rot90(central-difference 切向) 归一 × size;rot90(x,y)=(-y,x)=cross((0,0,1),(x,y,0)).xy。
        func rightAt(_ point: Int, _ size: Float) -> SIMD2<Float> {
            let prev = point > 0 ? sp[point - 1] : sp[point]
            let next = point + 1 < totalPoints ? sp[point + 1] : sp[point]
            let tan = next - prev
            let len = simd_length(tan)
            if len < 1e-4 { return .zero }              // 退化(节点重合)→ 零宽,塌成零面积,无 NaN
            let dir = tan / len
            return SIMD2(-dir.y, dir.x) * size
        }
        out.reserveCapacity(out.count + totalSub * 6)
        for s in 0..<totalSub {
            let pA = sp[s], pB = sp[s + 1]
            let rA = rightAt(s, ss[s]), rB = rightAt(s + 1, ss[s + 1])
            let cA = sc[s], cB = sc[s + 1]
            let vA = vAt(s), vB = vAt(s + 1)
            let lA = RopeVertex(pos: pA - rA, uv: SIMD2(0, vA), color: cA)
            let riA = RopeVertex(pos: pA + rA, uv: SIMD2(1, vA), color: cA)
            let riB = RopeVertex(pos: pB + rB, uv: SIMD2(1, vB), color: cB)
            let lB = RopeVertex(pos: pB - rB, uv: SIMD2(0, vB), color: cB)
            out.append(lA); out.append(riA); out.append(riB)
            out.append(riB); out.append(lB); out.append(lA)
        }
    }

    /// 输出当前所有粒子的渲染实例(世界像素坐标 + 当前 alpha/size/旋转/颜色)。
    // controlpointattract 力学剖面退路:WP_CPATTRACT_CONST=1 退回 lwe 半径内恒力(无衰减)。
    static let cpAttractConstForce = ProcessInfo.processInfo.environment["WP_CPATTRACT_CONST"] != nil

    // 精灵宽度语义【2026-06-11 WE 实机截图裁决】:全宽 = pkg/2(= p.size 半径值直接当 quad 宽)。
    // 曾推断「lwe /2 + shader ±0.5 两头减半=半大」并 ×2,但 Postscript 鸟 WE 实测(画布≈1:1 截图)
    // 暗斑宽中位 ~6/主体 3-12px,半幅版中位 8/4-11 吻合、×2 版中位 17 恰好大一倍 → ×2 证伪回滚。
    // 即 WE 的 CPU 喂给 shader 的 size 属性本身就是 pkg/2(lwe CParticle.cpp:738 是对的)。
    // WP_SPRITE_FULL=1 = 诊断用全宽(pkg 值)。
    static let spriteHalfLegacy = ProcessInfo.processInfo.environment["WP_SPRITE_FULL"] == nil

    func instances() -> [ParticleInstance] {
        particles.map { p in
            let f = p.age / p.life                  // 归一化生命比(精灵表帧索引用)
            let vs = visualState(p)
            let world = vs.world, s = vs.size, a = vs.alpha, col = vs.col
            // p.size 是 pkg/2(lwe 存法 = WE CPU 喂 shader 的 size 属性;quad 全宽即此值,**不**再 ×2)。
            // Postscript 鸟 WE 实机截图实测裁决(见 spriteHalfLegacy 注释):半幅吻合、×2 恰好大一倍。
            var sFull = Self.spriteHalfLegacy ? abs(s) : abs(s) * 2
            var center = world
            if desc.particleFlags & 4 != 0 {
                // flags&4 透视粒子:等效 lwe 的 perspective·lookAt——屏幕居中坐标与 size 同乘
                // k(z) = cot(fov/2)·(H/2)/(1000−z)。z 由 3D 球壳发射给定(directions/sign 的 z 分量),
                // z→1000(贴近相机)大且快、z→0 远小慢。z≥1000 在眼后,lwe 由 GPU w≤0 裁掉 → 置 0 跳过。
                let denom = 1000 - p.pos.z
                if denom > 0.001 {
                    let half = desc.cameraFov * Float.pi / 360
                    let k = (1 / tan(half)) * desc.canvasSize.y * 0.5 / denom
                    let cx = world.x - desc.canvasSize.x * 0.5
                    let cy = world.y - desc.canvasSize.y * 0.5
                    center = SIMD2(cx * k + desc.canvasSize.x * 0.5, cy * k + desc.canvasSize.y * 0.5)
                    sFull *= k
                } else {
                    sFull = 0
                }
            }
            // 精灵表 UV:
            let uvOffset: SIMD2<Float>
            let uvSc: SIMD2<Float>
            if !frameRects.isEmpty {
                let n = frameRects.count
                let idx = frameIndex(p: p, f: f, n: n)
                let r = frameRects[idx]
                uvOffset = SIMD2(r.x, r.y)
                uvSc = SIMD2(r.z, r.w)
            } else {
                let frame = sheetFrames > 1 ? frameIndex(p: p, f: f, n: sheetFrames) : p.frame
                let col = frame % sheetCols
                let row = frame / sheetCols
                uvOffset = SIMD2(Float(col) * sheetUVScale.x, Float(row) * sheetUVScale.y)
                uvSc = sheetUVScale
            }
            // 单帧贴图宽高比可能非 1:1,修正 quad 让贴图不变形。**每帧像素宽高比** = 帧UV比 × 贴图高宽比的倒数
            //   = (uvSc.x/uvSc.y) / trailTextureRatio(=(uvSc.x·atlasW)/(uvSc.y·atlasH) = frameW/frameH 像素比)。
            //   shader 把此 aspect 乘到 quad 的 X(width)→ 宽:高 = aspect:1 = 真实帧像素比。对齐 lwe CParticle.cpp:1936。
            //   之前只用 uvSc.x/uvSc.y(=网格 cols 比,忽略 atlas 非方形)→ rosepetals(512×128横排5)算成 0.2,花瓣压成
            //   5:1 竖条;正确应 0.8。方形贴图(trailTextureRatio=1)不变 → 零回归。
            let tr = desc.trailTextureRatio
            let aspect = (uvSc.x > 0 && uvSc.y > 0 && tr > 0) ? (uvSc.x / uvSc.y) / tr : 1
            var instSize = sFull
            var instRot = p.rotation
            var instAspect = aspect
            if desc.isSpriteTrail {
                // genericparticle.vert TRAILRENDERER:quad 按速度方向定向并拉伸成拖尾带。
                // ComputeParticleTrailTangents:up = normalize(vel)·clamp(speed·length, min, max);right = ⊥vel(归一)。
                // ComputeParticlePosition:沿 up 长轴 = size·trailLen·textureRatio,沿 right 短轴 = size。
                let vx = p.vel.x, vy = p.vel.y
                let speed = (vx * vx + vy * vy).squareRoot()
                let trailLen = max(desc.trailMinLength, min(speed * desc.trailLength, desc.trailMaxLength))
                // 每帧 textureRatio = (uvSc.y/uvSc.x)·(texH/texW);单帧 uvSc=(1,1) ⇒ 即 texH/texW。
                let texRatio = (uvSc.x > 0 ? uvSc.y / uvSc.x : 1) * desc.trailTextureRatio
                let lenAxis = sFull * trailLen * texRatio         // 我们 local-y(长轴)的世界像素长度(全宽语义,同精灵)
                instSize = lenAxis
                // aspect = 短轴/长轴;lenAxis→0(速度≈0)时塌缩为 0(x 轴=lenAxis·aspect=size 不变,y=0 ⇒ 零面积、无 NaN),与 WE 退化一致。
                instAspect = lenAxis > 1e-3 ? sFull / lenAxis : 0
                // local +y 轴对齐速度方向:rotated(0,1)=(−sinθ,cosθ)=normalize(vel) ⇒ θ=atan2(−vx, vy)。
                instRot = atan2(-vx, vy)
            }
            // 图层 Z 旋转随整层应用(见 visualState:位置已绕层原点转 layerAngleZ)。精灵 quad 自身朝向也加该角,
            // 使定向雨丝/拖尾沿「随层倾斜后的世界速度」对齐;非定向粒子(雪/尘/雾,随机/0 朝向)同样整体旋转,
            // 与 WE m_modelMatrix 把 quad 一并旋转一致。orientation=="upright"(水花)精灵 rotation 强制 0:
            // WE upright 精灵不随 modelMatrix 自旋(始终竖直),故此类不叠加层角。
            if desc.layerAngleZ != 0 && !desc.orientationUpright { instRot += desc.layerAngleZ }
            return ParticleInstance(center: center,
                                    size: instSize,
                                    rotation: instRot,
                                    color: SIMD4(col, a),
                                    uvOffset: uvOffset,
                                    uvScale: uvSc,
                                    aspect: instAspect)
        }
    }
}

/// GPU 渲染用的粒子实例数据(与 Metal struct 对齐)。
struct ParticleInstance {
    var center: SIMD2<Float>
    var size: Float
    var rotation: Float
    var color: SIMD4<Float>
    var uvOffset: SIMD2<Float>   // 精灵表该帧在贴图中的左上角 UV
    var uvScale: SIMD2<Float>    // 该帧占整张贴图的 UV 比例(单帧=(1,1))
    var aspect: Float            // 帧宽高比(quad x 方向乘它,避免非方形帧被拉变形)
}

/// rope 带状网格的单个顶点(与 Metal rope_vertex 对齐):位置已在画布像素世界系,
/// 直接过 proj×ndcScale。uv = (沿宽 0..1, 沿长纹理 v),color = 该点 rgba。
struct RopeVertex {
    var pos: SIMD2<Float>
    var uv: SIMD2<Float>
    var color: SIMD4<Float>
}

/// 从场景的 particle 图层 + particles/*.json 解析出发射器描述。
enum ParticleParser {

    /// 解析 scene.json 里所有 particle 图层。effectiveVisible:按对象 id 求"有效可见性"(自身 AND 父组链),
    /// 由 SceneModel 传入——否则挂在父组(如 Rain Puddles)开关上的发射器(7 个溅水)控制不了 → 雨开关失效。
    static func parseLayers(scene: [String: Any], source: SceneSource,
                            effectiveVisible: (Int) -> Bool = { _ in true },
                            absoluteOrigin: (Int) -> SIMD3<Float> = { _ in .zero },
                            absoluteScale: (Int) -> SIMD3<Float> = { _ in SIMD3(1, 1, 1) }) -> [ParticleEmitterDesc] {
        let objects = scene["objects"] as? [[String: Any]] ?? []
        // 后处理层(fullscreenlayer:bloom/filmgrain/...)在场景对象序列中的下标(可见且带 effect 的)。
        // 排在它**之后**的粒子层不被后处理(见 ParticleEmitterDesc.aboveBloom)。无则为 Int.max(都在其下)。
        var postLayerIndex = Int.max
        for (i, obj) in objects.enumerated() {
            if let ref = obj["image"] as? String, ref.contains("fullscreenlayer"),
               VecParse.parseVisibleBool(obj["visible"]),
               let effs = obj["effects"] as? [Any], !effs.isEmpty {
                postLayerIndex = i; break
            }
        }
        var result: [ParticleEmitterDesc] = []
        for (objIndex, obj) in objects.enumerated() {
            guard let pPath = obj["particle"] as? String else { continue }
            // 有效可见性:有 id 走 effectiveVisible(含父组链),否则退自身 visible。
            let objId = (obj["id"] as? NSNumber)?.intValue ?? -1
            if objId >= 0 ? !effectiveVisible(objId) : !VecParse.parseVisibleBool(obj["visible"]) { continue }
            guard let pj = source.json(for: pPath) else { continue }
            // 跳过鼠标拖尾粒子(controlpoint 绑定光标):它本该沿光标发射,
            // 不实现就别当静止发射器,否则在原点喷一团亮斑(过曝)。
            guard pj["emitter"] != nil else { continue }  // 只有 passes 的是材质,不是粒子定义
            // 发射器是否跟随光标:由控制点 0 的 linkMouse 位决定(与 renderer 类型无关)。
            // 环境粒子(雾/雨/雪)cp flags=0、origin 固定;鼠标拖尾/绳 cp0 flags&1 置位。
            let followsCursor = cursorLinked(pj)
            // 用绝对原点/缩放(含父组链),与图层渲染一致;否则挂容器(雨的 Rain Effects 在 (1920,1080))下的
            // 发射器丢父偏移 → 粒子全跑画布外(实测雨 g1 center.y=6918、水花 center.y<0)。objId<0 退回本地。
            let layerOrigin = objId >= 0 ? absoluteOrigin(objId) : VecParse.f3(obj["origin"])
            let layerScale = objId >= 0 ? absoluteScale(objId) : VecParse.f3(obj["scale"], default: SIMD3(1, 1, 1))
            // 把该 scene 对象的图层变换 + 实例染色应用到一个发射器 desc(父发射器与各 child 共用这套对象级属性)。
            func applyObjectLayer(_ desc: inout ParticleEmitterDesc) {
                desc.followsCursor = followsCursor
                desc.layerOrigin = SIMD2(layerOrigin.x, layerOrigin.y)
                desc.layerScale = SIMD2(layerScale.x, layerScale.y)  // 逐轴各向异性缩放
                desc.layerAngleZ = VecParse.f3(obj["angles"]).z   // 图层倾斜(雨丝斜下,WE 弧度)
                // 鼠标视差深度:图像/文字层已做、粒子层原来漏了(眼焰 vapor 粒子 parallaxDepth=1.3 → 鼠标移动时
                //   脸图层跟着视差移、眼焰粒子不动 → 火焰脱离眼睛偏移)。照图像层同 parallaxOffset 公式在 encode 平移投影。
                let pd = VecParse.f3(obj["parallaxDepth"], default: SIMD3(1, 1, 1))
                desc.parallaxDepth = SIMD2(pd.x, pd.y)
                // instanceoverride:alpha(图层级整体透明度)+ colorn/color(实例染色乘子,乘进每粒子色;
                // 如 2B 壁纸把玫瑰花瓣染暗红配红花田。漏掉 colorn → 花瓣显基色粉白被误认成"樱花")。
                // controlpointattract 中心解析(见 CPAttract 注释):io "controlpointN"(世界)> worldSpace offset(世界)> 局部 offset。
                // 世界 → 层局部:(world − layerOrigin) / layerScale(粒子 pos 是层局部,visualState 再乘回)。
                let ioCP = obj["instanceoverride"] as? [String: Any]
                for i in desc.cpAttracts.indices {
                    var world: SIMD3<Float>? = nil
                    if let v = ioCP?["controlpoint\(desc.cpAttracts[i].cpId)"] {
                        let w = VecParse.f3(VecParse.unwrap(v) ?? v)
                        desc.cpAttracts[i].ioWorld = w; world = w
                    } else if desc.cpAttracts[i].worldSpace {
                        world = desc.cpAttracts[i].offset
                    }
                    if let w = world {
                        let sx = layerScale.x != 0 ? layerScale.x : 1, sy = layerScale.y != 0 ? layerScale.y : 1
                        desc.cpAttracts[i].center = SIMD3((w.x - layerOrigin.x) / sx,
                                                          (w.y - layerOrigin.y) / sy, 0) + desc.cpAttracts[i].originOff
                    }
                }
                if let io = obj["instanceoverride"] as? [String: Any] {
                    if let a = VecParse.unwrap(io["alpha"]) as? NSNumber { desc.layerAlpha = a.floatValue }
                    // 【关键修复】场景**对象级** instanceoverride 的 count/size/speed/rate 乘子,过去只在粒子预设 JSON
                    // 顶层(build 里 L1103)读过,对象级这里漏读 → 像雾林 halo_2(对象级 count 0.41/size 0.44)被按
                    // 全尺寸全数量渲染 → 又大又多的折射 halo 透出暗青雾 = 满屏青碎片。WE 把对象级覆盖作乘子叠加,
                    // 此处补齐(乘进 build 已设的预设级值)。对照 ObjectParser.cpp:1097 + Object.h:532。
                    if let v = VecParse.unwrap(io["count"])    as? NSNumber { desc.maxCount = max(0, Int(Float(desc.maxCount) * v.floatValue)) }
                    if let v = VecParse.unwrap(io["size"])     as? NSNumber { desc.ioSize     *= v.floatValue }
                    if let v = VecParse.unwrap(io["speed"])    as? NSNumber { desc.ioSpeed    *= v.floatValue }
                    if let v = VecParse.unwrap(io["rate"])     as? NSNumber { desc.rate       *= v.floatValue }
                    if let v = VecParse.unwrap(io["lifetime"]) as? NSNumber { desc.ioLifetime *= v.floatValue }
                    var tint: SIMD3<Float>? = nil
                    if let s = VecParse.unwrap(io["colorn"]) as? String {           // 归一化 0-1
                        let v = VecParse.floats(s); if v.count >= 3 { tint = SIMD3(v[0], v[1], v[2]) }
                    } else if let s = VecParse.unwrap(io["color"]) as? String {     // 0-255
                        let v = VecParse.floats(s); if v.count >= 3 { tint = SIMD3(v[0]/255, v[1]/255, v[2]/255) }
                    }
                    if let t = tint { desc.colorMin *= t; desc.colorMax *= t }
                }
                if let c = obj["color"], let arr = (VecParse.unwrap(c) as? String).map(VecParse.floats), arr.count >= 3 {
                    let tint = SIMD3(arr[0], arr[1], arr[2]); desc.colorMin = tint; desc.colorMax = tint  // 对象级整体染色
                }
                desc.aboveBloom = objIndex > postLayerIndex   // 排在后处理层之上 → 不被 bloom
                desc.sceneObjIndex = objIndex   // 场景对象序(粒子在图层间插画的锚点;WE 按对象序绘制一切)
            }
            if var desc = build(from: pj, source: source) {
                applyObjectLayer(&desc); result.append(desc)
            }
            // 子粒子发射器(children):WE 把第二个/更多发射器放在 children(如落叶的第二种叶贴图、火上的烟),
            // 当独立粒子系统、继承父图层变换。漏加 → 粒子稀疏单一(枫叶"劣质"主因:只渲 10 片单贴图而非 60 片双贴图)。
            // 对照 ObjectParser.cpp:621-626 + parseParticleChild。
            if let children = pj["children"] as? [[String: Any]] {
                for child in children {
                    let cPath = (child["particle"] as? String) ?? (child["name"] as? String)
                    guard let cPath, let cpj = source.json(for: cPath), cpj["emitter"] != nil,
                          var cdesc = build(from: cpj, source: source) else { continue }
                    applyObjectLayer(&cdesc); result.append(cdesc)
                }
            }
        }
        return result
    }

    /// 发射器是否跟随光标:控制点 0 的 flags bit0(linkMouse)置位。
    /// 对照 CParticle.cpp:176-177(linkMouse = cp.flags & 1)+ 556(自动检测 cp0 linkMouse)。
    private static func cursorLinked(_ pj: [String: Any]) -> Bool {
        if let cps = pj["controlpoint"] as? [[String: Any]],
           let first = cps.first, ((first["flags"] as? NSNumber)?.intValue ?? 0) & 1 != 0 {
            return true
        }
        return false
    }

    static func build(from pj: [String: Any], source: SceneSource) -> ParticleEmitterDesc? {
        let emitters = pj["emitter"] as? [[String: Any]] ?? []
        guard let em = emitters.first else { return nil }

        let emName = (em["name"] as? String) ?? "sphererandom"
        let isBox = emName.contains("box")
        var d = ParticleEmitterDesc(
            maxCount: (pj["maxcount"] as? NSNumber)?.intValue ?? 100,   // WE 默认 100(ObjectParser.cpp:697)
            // WE emitter.rate 默认 10(ObjectParser.cpp:821)。
            rate: (em["rate"] as? NSNumber)?.floatValue ?? 10,
            emitterOrigin: VecParse.f3(em["origin"]),   // y 向上(与 absoluteOrigin/matOrtho 一致)
            directions: VecParse.f3(em["directions"], default: SIMD3(1, 1, 0)),  // WE 默认 (1,1,0)
            // 标量半径(向后兼容旧字段);box/sphere 实际用下面的向量字段 distanceMinVec/MaxVec。
            distanceMin: (em["distancemin"] as? NSNumber)?.floatValue ?? 0,
            distanceMax: (em["distancemax"] as? NSNumber)?.floatValue ?? 0,
            startTime: (pj["starttime"] as? NSNumber)?.floatValue ?? 0
        )
        d.isBox = isBox
        // distancemin/max 向量(WE 默认 min=(0,0,0) / max=(256,256,0));box 用全 3 轴对称采样,
        // sphere 用 .x 当标量半径。directions 向量(默认 (1,1,0))与 sign(ivec3,默认 0)。
        d.distanceMinVec = VecParse.f3(em["distancemin"], default: SIMD3(0, 0, 0))
        d.distanceMaxVec = VecParse.f3(em["distancemax"], default: SIMD3(256, 256, 0))
        // 标量 distancemin/max(如雨 distancemax=800,是数字不是 "x y z" 字符串)→ 灌进 Vec 当半径。
        // 否则 f3 拿不到 3 分量退默认 256 → sphere 半径太小,雨只挤在画布中间一条(用户报「雨只有中间」)。
        if let n = em["distancemin"] as? NSNumber { let v = n.floatValue; d.distanceMinVec = SIMD3(v, v, 0) }
        if let n = em["distancemax"] as? NSNumber { let v = n.floatValue; d.distanceMaxVec = SIMD3(v, v, 0) }
        d.directionsVec = VecParse.f3(em["directions"], default: SIMD3(1, 1, 0))
        d.particleFlags = UInt32((pj["flags"] as? NSNumber)?.intValue ?? 0)   // 顶层 flags:bit2 → sphere 3D 球壳
        let sgn = VecParse.f3(em["sign"], default: .zero)
        d.emitterSign = SIMD3(Int32(sgn.x), Int32(sgn.y), Int32(sgn.z))
        // emitter 自带速度 / 节奏(WE 默认全 0;ObjectParser.cpp:818-826)。
        d.emitterSpeedMin = num(em["speedmin"], 0); d.emitterSpeedMax = num(em["speedmax"], 0)
        d.emitterDelay = num(em["delay"], 0)
        d.emitterDuration = num(em["duration"], 0)
        d.emitterInstantaneous = (em["instantaneous"] as? NSNumber)?.intValue ?? 0
        d.emitterLimitOnePerFrame = (((em["flags"] as? NSNumber)?.intValue ?? 0) & 2) != 0

        // 粒子 json 顶层 instanceoverride 块(size/speed/count 乘子,默认全 1;Object.h:532 / ObjectParser.cpp:1097)。
        // alpha 由场景图层级 instanceoverride.alpha → layerAlpha 承载(parseLayers 里读),此处不重复。
        // count 立即乘进 maxCount(WE 是 maxCount × countMultiplier,见 CParticle.cpp:84-85)。
        if let io = pj["instanceoverride"] as? [String: Any] {
            d.ioSize = num(io["size"], 1)
            d.ioSpeed = num(io["speed"], 1)
            d.ioLifetime = num(io["lifetime"], 1)
            if let r = (VecParse.unwrap(io["rate"]) as? NSNumber)?.floatValue { d.rate *= r }
            let countMul = num(io["count"], 1)
            d.maxCount = Int(Float(d.maxCount) * countMul)
        }

        for ini in pj["initializer"] as? [[String: Any]] ?? [] {
            switch ini["name"] as? String {
            case "lifetimerandom":
                d.lifetimeMin = num(ini["min"], 2); d.lifetimeMax = num(ini["max"], 5)
            case "sizerandom":
                d.sizeMin = num(ini["min"], 50); d.sizeMax = num(ini["max"], 50)
                d.sizeExponent = num(ini["exponent"], 1)
            case "velocityrandom":
                // WE 默认 min/max = ∓32(全轴);spawn 时翻 Y + ×speedOverride + 累加(CParticle.cpp:790)。
                d.hasVelRandom = true
                d.velMin = VecParse.f3(ini["min"], default: SIMD3(-32, -32, -32))
                d.velMax = VecParse.f3(ini["max"], default: SIMD3(32, 32, 32))
            case "mapsequencearoundcontrolpoint":
                // 控制点圆周扇形发射(CParticle.cpp:934-982)。WE 默认 speedmin (0,0,0)/speedmax (0,0,100)/count 1。
                d.hasMapSeq = true
                d.mapSeqControlPoint = (ini["controlpoint"] as? NSNumber)?.intValue ?? 0
                d.mapSeqCount = max(1, (ini["count"] as? NSNumber)?.intValue ?? 1)
                d.mapSeqSpeedMin = VecParse.f3(ini["speedmin"], default: .zero)
                d.mapSeqSpeedMax = VecParse.f3(ini["speedmax"], default: SIMD3(0, 0, 100))
            case "rotationrandom":
                // 3 轴初始旋转;WE 默认 min (0,0,0) / max (0,0,2π)(ObjectParser.cpp:881-884)。我们取 .z。
                d.hasRotRandom = true
                d.rotMin = VecParse.f3(ini["min"], default: .zero)
                d.rotMax = VecParse.f3(ini["max"], default: SIMD3(0, 0, 6.2831853))
            case "colorrandom":
                d.colorMin = VecParse.f3(ini["min"], default: SIMD3(255,255,255)) / 255
                d.colorMax = VecParse.f3(ini["max"], default: SIMD3(255,255,255)) / 255
            case "alpharandom":
                // WE 默认 min 0.05 / max 1(ObjectParser.cpp:870)。
                d.alphaMin = num(ini["min"], 0.05); d.alphaMax = num(ini["max"], 1)
            case "angularvelocityrandom":
                // WE 3 轴 + exponent;默认 min (0,0,-5) / max (0,0,5) / exp 1(ObjectParser.cpp:886-889)。取 .z。
                d.hasAngularVel = true
                d.angVelMin = VecParse.f3(ini["min"], default: SIMD3(0, 0, -5)).z
                d.angVelMax = VecParse.f3(ini["max"], default: SIMD3(0, 0, 5)).z
                d.angVelExponent = num(ini["exponent"], 1)
            case "turbulentvelocityrandom":
                d.hasTurbVelRand = true
                d.turbSpeedMin = num(ini["speedmin"], 100); d.turbSpeedMax = num(ini["speedmax"], 250)
                d.tvScale = num(ini["scale"], 1); d.tvOffset = num(ini["offset"], 0)
                d.tvForward = VecParse.f3(ini["forward"], default: SIMD3(0, 1, 0))
                d.tvRight = VecParse.f3(ini["right"], default: SIMD3(0, 0, 1))
                d.tvTimeScale = num(ini["timescale"], 1)
                d.tvPhaseMin = num(ini["phasemin"], 0); d.tvPhaseMax = num(ini["phasemax"], 0.1)
            default: break
            }
        }

        for op in pj["operator"] as? [[String: Any]] ?? [] {
            switch op["name"] as? String {
            case "movement":
                d.gravity = VecParse.f3(op["gravity"])   // 注:不翻 Y——我们坐标系雨已正常下落,翻了反而往上飞
                d.drag = num(op["drag"], 0)
            case "alphafade":
                d.hasAlphaFade = true
                // WE 默认 0.5/0.5(归一化生命比),不是 0。对照 ObjectParser.cpp:921。
                d.fadeInTime = num(op["fadeintime"], 0.5); d.fadeOutTime = num(op["fadeouttime"], 0.5)
            case "sizechange":
                d.hasSizeChange = true
                d.sizeChangeStart = num(op["startvalue"], 1); d.sizeChangeEnd = num(op["endvalue"], 1)
                d.sizeChangeStartTime = num(op["starttime"], 0); d.sizeChangeEndTime = num(op["endtime"], 1)  // #4 窗口
            case "alphachange":
                // 默认 starttime 0 / endtime 1 / startvalue 1 / endvalue 0(ObjectParser.cpp:928)。
                d.hasAlphaChange = true
                d.alphaChangeStartTime = num(op["starttime"], 0); d.alphaChangeEndTime = num(op["endtime"], 1)
                d.alphaChangeStartValue = num(op["startvalue"], 1); d.alphaChangeEndValue = num(op["endvalue"], 0)
            case "colorchange":
                // startvalue/endvalue 是颜色**乘子**(默认 (1,1,1) 不变色),非 0-255 颜色,不除 255。ObjectParser.cpp:933。
                d.hasColorChange = true
                d.colorChangeStartTime = num(op["starttime"], 0); d.colorChangeEndTime = num(op["endtime"], 1)
                d.colorChangeStartValue = VecParse.f3(op["startvalue"], default: SIMD3(1, 1, 1))
                d.colorChangeEndValue = VecParse.f3(op["endvalue"], default: SIMD3(1, 1, 1))
            case "vortex", "vortex_v2":
                // 标准模式涡旋。默认 axis (0,0,1) / distanceinner 500 / distanceouter 650 / speedinner 2500
                // / speedouter 0 / centerforce 1(ObjectParser.cpp:949)。flags 位 2 = maintain distance。
                d.hasVortex = true
                d.vortexAxis = VecParse.f3(op["axis"], default: SIMD3(0, 0, 1))
                d.vortexOffset = VecParse.f3(op["offset"], default: SIMD3(0, 0, 0))
                d.vortexDistanceInner = num(op["distanceinner"], 500); d.vortexDistanceOuter = num(op["distanceouter"], 650)
                d.vortexSpeedInner = num(op["speedinner"], 2500); d.vortexSpeedOuter = num(op["speedouter"], 0)
                d.vortexCenterForce = num(op["centerforce"], 1)
                let vflags = (op["flags"] as? NSNumber)?.intValue ?? 0
                d.vortexMaintainDistance = (vflags & 2) != 0
                d.vortexInfiniteAxis = (vflags & 1) != 0
                d.vortexRingShape = (vflags & 4) != 0
                d.vortexRingRadius = num(op["ringradius"], 300); d.vortexRingWidth = num(op["ringwidth"], 50)
                d.vortexRingPullDistance = num(op["ringpulldistance"], 50); d.vortexRingPullForce = num(op["ringpullforce"], 10)
            case "controlpointattract":
                // 朝控制点恒力吸引(阈值内)。WE 默认 origin (0,0,0) / scale 100 / threshold 1000(ObjectParser.cpp:962-966)。
                // 中心 = controlpoint[op.controlpoint].offset + op.origin:operator 的整数 `controlpoint` 字段
                // 指向粒子层 controlpoint[] 数组里某项的 offset(birds:cp1="1500 0 0"/cp2="123 0 0";
                // Bird:cp2="0 -500 0" 等)。一层可有多个 attract → 累进数组。
                let cpIndex = (op["controlpoint"] as? NSNumber)?.intValue ?? 0
                var cpOffset = SIMD3<Float>.zero
                var cpFlags = 0
                if let cps = pj["controlpoint"] as? [[String: Any]] {
                    let cp = cps.first(where: { ($0["id"] as? NSNumber)?.intValue == cpIndex })
                        ?? ((cpIndex >= 0 && cpIndex < cps.count) ? cps[cpIndex] : nil)   // 退化:按下标取
                    if let cp {
                        cpOffset = VecParse.f3(cp["offset"])
                        cpFlags = (cp["flags"] as? NSNumber)?.intValue ?? 0
                    }
                }
                let originOff = VecParse.f3(op["origin"], default: .zero)
                d.cpAttracts.append(ParticleEmitterDesc.CPAttract(
                    cpId: cpIndex,
                    linkMouse: (cpFlags & 1) != 0,
                    worldSpace: (cpFlags & 2) != 0,
                    offset: cpOffset,
                    ioWorld: nil,
                    originOff: originOff,
                    scale: num(op["scale"], 100),
                    // threshold 缺省 1000(ObjectParser.cpp:966)。曾一度改 0(判"缺失=不生效"),被 WE 实机
                    // 「鸟末段**收敛**成一条线」推翻:正解=缺省 1000 照常生效 + 力**线性衰减**(见 step() 的
                    // falloff 注释)——衰减软墙才能既不轰散又收束;恒力下 1000 默认确实会轰散(当时误归因于默认值)。
                    threshold: num(op["threshold"], 1000),
                    center: cpOffset + originOff))   // 局部兜底(=旧行为;applyObjectLayer 再按 io/world 解析)
            case "turbulence":
                // curl-noise 流动力场。speed/phase 每发射器随机一次(照 CParticle.cpp:1265-1266 用 m_rng)。
                d.hasTurbulence = true
                d.turbScale = num(op["scale"], 0.005)
                d.turbTimeScale = num(op["timescale"], 0.01)
                d.turbMask = VecParse.f3(op["mask"], default: SIMD3(1, 1, 0))
                let sMin = num(op["speedmin"], 500), sMax = num(op["speedmax"], 1000)
                let pMin = num(op["phasemin"], 0), pMax = num(op["phasemax"], 0)
                // 【审计修复】turbulence speed/phase 原用系统 Float.random(in:) → 破坏确定性/可复现。
                // 改用同文件确定性 xorshift(rndDet),种子由数值范围导出,保证每次解析结果一致。
                var rngSeed = detSeed(sMin, sMax, pMin, pMax)
                d.turbFieldSpeed = sMax > sMin ? sMin + (sMax - sMin) * rndDet(&rngSeed) : sMin
                d.turbPhase = pMax > pMin ? pMin + (pMax - pMin) * rndDet(&rngSeed) : pMin
            case "oscillatealpha":
                d.hasOscAlpha = true
                d.oscAFreqMin = num(op["frequencymin"], 0); d.oscAFreqMax = num(op["frequencymax"], 10)
                d.oscAScaleMin = num(op["scalemin"], 0); d.oscAScaleMax = num(op["scalemax"], 1)
                d.oscAPhaseMin = num(op["phasemin"], 0); d.oscAPhaseMax = num(op["phasemax"], 6.2831853)
            case "oscillatesize":
                d.hasOscSize = true
                d.oscSFreqMin = num(op["frequencymin"], 0); d.oscSFreqMax = num(op["frequencymax"], 10)
                d.oscSScaleMin = num(op["scalemin"], 0.8); d.oscSScaleMax = num(op["scalemax"], 1.2)
                d.oscSPhaseMin = num(op["phasemin"], 0); d.oscSPhaseMax = num(op["phasemax"], 6.2831853)
            case "oscillateposition":
                // **每个 oscillateposition 各自 append 一个配置**(不再覆盖单字段)——同一 group 的多个
                // oscillateposition(雪「双摆」:一个 mask(1,0,0) 左右、一个 mask(0,1,0) 上下)各自独立 apply,
                // 对齐 lwe operator 列表逐个执行(setupOperators CParticle.cpp:971-1011 / :1001-1002)。
                d.oscPositions.append(ParticleEmitterDesc.OscPos(
                    freqMin: num(op["frequencymin"], 0),  freqMax: num(op["frequencymax"], 5),
                    scaleMin: num(op["scalemin"], 0),     scaleMax: num(op["scalemax"], 10),
                    phaseMin: num(op["phasemin"], 0),     phaseMax: num(op["phasemax"], 6.2831853),
                    mask: VecParse.f3(op["mask"], default: SIMD3(1, 1, 0))))
            case "remapvalue":
                // lwe 无此算子(穷尽搜确认)→ 按真 WE remapvalue 语义移植。
                // output 指增量加到何处,目前实现 "velocity"(加到速度);source/transformfunction 决定输入与噪声类型。
                //   source: "velocity"(默认,位置驱动) / "speed"(速度大小驱动)。
                //   transformfunction: "simplexnoise"(单倍频,perlin 近似) / "fbmnoise"(分形布朗,多倍频叠加)。
                if (op["output"] as? String) == "velocity" {
                    let src = (op["source"] as? String) ?? "velocity"
                    let tf = (op["transformfunction"] as? String) ?? "simplexnoise"
                    d.hasRemap = true
                    d.remapSourceSpeed = (src == "speed")
                    d.remapFbm = (tf == "fbmnoise")
                    d.remapInputScale = num(op["transforminputscale"], 1)
                    d.remapOutputMin = VecParse.f3(op["outputrangemin"], default: .zero)
                    d.remapOutputMax = VecParse.f3(op["outputrangemax"], default: .zero)
                }
            case "angularmovement":
                // Z 角加速度(力);读 op.force 的 .z。step() 里对非定向粒子 angVel += force.z·dt。
                d.hasAngularMovement = true
                d.angularForceZ = VecParse.f3(op["force"], default: .zero).z
                d.angularDragZ = (VecParse.unwrap(op["drag"]) as? NSNumber)?.floatValue ?? 0
            default: break
            }
        }

        // 材质 → 纹理
        if let matPath = pj["material"] as? String,
           let mat = source.json(for: matPath),
           let passes = mat["passes"] as? [[String: Any]],
           let pass0 = passes.first {
            // 照 pkg 材质真实 blending。全库实测:60 additive / 25 translucent / 0 normal。
            // 解析不到 blending 时退到 translucent(标准 alpha-over),不强转 additive
            // ——强转 additive 正是过曝的源头。
            d.blend = BlendMode(raw: pass0["blending"] as? String)
            if d.blend == .normal { d.blend = .translucent }
            // 材质常量:overbright(g_Overbright,折进实例 col.rgb 见 visualState)+ refract_amount
            // (g_RefractAmount,折射顶点切基乘子,见 encodeRefract/particle_refract_vertex)。读真值,缺省取 WE 默认。
            if let csv = pass0["constantshadervalues"] as? [String: Any] {
                if let ob = (csv["ui_editor_properties_overbright"] as? NSNumber)?.floatValue { d.overbright = ob }
                if let ra = (csv["ui_editor_properties_refract_amount"] as? NSNumber)?.floatValue { d.refractAmount = ra }
            }
            // REFRACT combo:折射粒子(玻璃雨滴)。WE 用屏幕底图折射(见下渲染管线)。
            if let combos = pass0["combos"] as? [String: Any],
               let r = combos["REFRACT"] as? NSNumber, r.intValue == 1 {
                d.isRefract = true
                // 不强转 blend:尊重材质真实 blending(玻璃雨滴 translucent / 雨水花 halo additive)。
                // 曾强转 translucent → additive 折射(albedo×暗底图=暗)被 alpha 盖住场景 = 黑斑
                //(3174556087 七组水花 halo 的根因)。additive 折射暗输出叠加=不显形,不糊黑。
            }
            if let texs = pass0["textures"] as? [Any],
               let base = texs.compactMap({ $0 as? String }).first, !base.isEmpty {
                d.textureName = base
                d.texturePath = resolveTex(base, source)
                // 折射粒子的 textures[1] 是法线贴图(玻璃雨滴的表面起伏,用于屏幕折射偏移)。
                if d.isRefract {
                    let strs = texs.map { $0 as? String }   // 保留 null 占位,索引 1 才是法线
                    if strs.count > 1, let n = strs[1], !n.isEmpty {
                        d.normalTextureName = n
                        d.normalTexturePath = resolveTex(n, source)
                    }
                }
                // 读精灵表边车:<base>.tex-json 的 spritesheetsequences[0]。
                if let sheet = readSheet(base: base, source: source) {
                    d.sheetFrames = sheet.frames
                    d.frameWidthPx = sheet.w
                    d.frameHeightPx = sheet.h
                    d.sheetDuration = sheet.duration
                }
            }
        }
        // animationmode(WE 默认 "sequence" 循环)+ sequencemultiplier(播放速度,默认 1)。ObjectParser.cpp:689/696。
        d.animationMode = (pj["animationmode"] as? String) ?? "sequence"
        d.sequenceMultiplier = num(pj["sequencemultiplier"], 1)
        d.randomFrame = d.animationMode == "randomframe"
        // 渲染器分派:lwe **只看 renderers[0]**(CParticle.cpp:34-56 `const auto& renderer = m_particle.renderers[0]`),
        // 据它的 name 决定 rope/ropetrail/spritetrail/(否则)sprite。pkg 里一个粒子可带多个 renderer
        // (如 snowperspective.json renderer=[sprite, spritetrail]),WE/lwe 取第一个 = sprite(圆 bokeh 雪点),
        // **不是** spritetrail(拖尾)。旧实现用 `first(where: name=="spritetrail")` 在整列里搜——会把第二个
        // spritetrail 误当渲染模式,把本该圆点的 chromaticdot 雪渲成「彩色小条」(Misty Valley 雨束彩色 bug 真因)。
        // 改为严格取 renderers[0],与 lwe 一致,全库通用、零硬编码。
        let r0 = (pj["renderer"] as? [[String: Any]])?.first
        let r0name = (r0?["name"] as? String) ?? ""
        if r0name == "spritetrail" {
            // spritetrail:照 renderer.length/maxlength/minlength(ObjectParser.cpp:1004-1006 默认)。
            // 字段名小写(实测 pkg:{"maxlength":6,"name":"spritetrail"})。粒子将按速度拉伸成拖尾。
            d.isSpriteTrail = true
            d.trailLength = num(r0?["length"], 0.05)
            d.trailMaxLength = num(r0?["maxlength"], 10)
            d.trailMinLength = num(r0?["minlength"], 0)
        } else if r0name == "rope" || r0name == "ropetrail" {
            // rope/ropetrail 渲染器(genericropeparticle):粒子连成 Catmull-Rom 样条带。
            // subdivision 默认 4(CParticle.h:240);uvscale/uvscrolling/uvsmoothing 取 renderer 字段(默认 1/false/true)。
            d.isRope = true
            d.ropeSubdivision = max(1, (r0?["subdivision"] as? NSNumber)?.intValue ?? 4)
            d.ropeUVScale = num(r0?["uvscale"], 1)
            d.ropeUVScrolling = ((r0?["uvscrolling"] as? NSNumber)?.boolValue) ?? false
            d.ropeUVSmoothing = ((r0?["uvsmoothing"] as? NSNumber)?.boolValue) ?? true
            // ropetrail:在 lwe 里与 rope 走同一条 renderRope(CParticle.cpp:36-48 m_useRopeRenderer 都 true)。
            // 仅记录标记 + 透传 segments/length(均不影响几何,见 ParticleEmitterDesc.isRopeTrail 注释)。
            if r0name == "ropetrail" {
                d.isRopeTrail = true
                d.ropeSegments = max(2, (r0?["segments"] as? NSNumber)?.intValue ?? 4)
                d.ropeTrailLength = num(r0?["length"], 2)
            }
        }
        // sprite 渲染器的 orientation=="upright"(水花):精灵竖直站立,spawn 强制 rotation=0、禁用自转。
        // 实测 Rain_Splash_copy2.json:{"name":"sprite","orientation":"upright"}。仅 renderers[0]=sprite 时判定。
        if r0name == "sprite", (r0?["orientation"] as? String) == "upright" {
            d.orientationUpright = true
        }
        return d
    }

    /// 读取纹理的精灵表边车(pkg 内或 WE 内置)。返回 (帧数, 帧宽px, 帧高px)。
    private static func readSheet(base: String, source: SceneSource) -> (frames: Int, w: Float, h: Float, duration: Float)? {
        // 候选边车路径(.tex-json 紧挨 .tex)。
        let names = ["materials/\(base).tex-json", "\(base).tex-json"]
        var data: Data? = nil
        for n in names { if let d = source.data(for: n) { data = d; break } }
        if data == nil { data = BuiltinAssets.shared.textureSidecar(forReference: base) }
        guard let d = data,
              let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let seqs = json["spritesheetsequences"] as? [[String: Any]],
              let s0 = seqs.first else { return nil }
        let frames = (s0["frames"] as? NSNumber)?.intValue ?? 1
        let w = (s0["width"] as? NSNumber)?.floatValue ?? 0
        let h = (s0["height"] as? NSNumber)?.floatValue ?? 0
        // duration = 整张精灵表播一遍的秒数(驱动固定实时循环;缺省按 frames/30 ≈ 30fps)。
        let duration = (s0["duration"] as? NSNumber)?.floatValue ?? (Float(frames) / 30)
        return frames > 1 ? (frames, w, h, duration > 0 ? duration : Float(frames) / 30) : nil
    }

    private static func num(_ v: Any?, _ def: Float) -> Float {
        (v as? NSNumber)?.floatValue ?? def
    }

    // 【审计修复】确定性 RNG 辅助(替代 turbulence 里的系统 Float.random)。与 ParticleSimulator.rnd()
    // 同款 xorshift,种子由解析到的数值范围导出 → 同一壁纸每次解析得到一致的 speed/phase,可复现。
    private static func detSeed(_ vals: Float...) -> UInt64 {
        var s: UInt64 = 0x9E3779B97F4A7C15
        for v in vals { s = (s ^ UInt64(v.bitPattern)) &* 0x100000001B3 }
        return s | 1
    }
    private static func rndDet(_ state: inout UInt64) -> Float {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Float(state >> 40) / Float(1 << 24)   // [0,1)
    }

    private static func resolveTex(_ base: String, _ source: SceneSource) -> String? {
        for c in ["materials/\(base).tex", "\(base).tex"] where source.data(for: c) != nil { return c }
        let target = (base as NSString).lastPathComponent + ".tex"
        return source.allPaths.first { ($0 as NSString).lastPathComponent == target }
    }
}
