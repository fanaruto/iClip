import Foundation

/// 悬浮精灵全 GPU 单 Pass Metal 着色器（MSL 源码，兼容 macOS 14+ 与零外部 .metallib 编译）
///
/// 设计与性能原则：
/// 1. 0 顶点缓冲全屏三角形，1 个 Draw Call 完成全部 4 套材质与粒子/波纹/声波渲染；
/// 2. 全量解析式 SDF 柔影与抗锯齿，彻底消除 CPU 离屏高斯模糊 Pass 带来的 120Hz 掉帧；
/// 3. 严格预乘 Alpha（Premultiplied Porter-Duff）合成，保证浅/深色桌面壁纸零黑边。
enum SpriteOrbMetalShader {
    static let particleCapacity = 24

    static let source: String = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct SpriteOrbUniforms {
        float4 dims;          // x: panelSize(pt), y: orbCenterX, z: orbCenterY, w: breathScale
        float4 motion;        // x: time, y: tensionPull, z: tensionAngle, w: capillaryAmp
        float4 states;        // x: hoverBlend, y: pressBlend, z: vortexBlend, w: crownAngle
        float4 stretch;       // x: velAngle, y: stretchAmt, z: overallOpacity, w: dropHotPulse
        float4 accentRGB;     // xyz: active accent RGB, w: reserved
        float4 voiceAndNudge; // x: audioLevel, y: voiceActiveBlend, z: cancelSlideBlend, w: chargeProgress
        uint4  flags;         // x: style(0..3), y: isDark(0/1), z: matrixBits(0..24=glyph,25=hasGlyph,26=eq,27=blink), w: bit0=panelOpen, bit1=dragTarget, bit2=smartActive, bit3=nudgeActive
        float4 extra;         // x: breathWave, y: nudgeGlowAlpha, z: voicePulsePhase, w: unused
        float4 ripples[3];    // xy: center(pt), z: radius(pt), w: alpha (+accent, -emerald)
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VertexOut spriteOrbVertex(uint vid [[vertex_id]]) {
        VertexOut out;
        // 顶部朝 +Y 映射为 uv.y = 0，保持与 Swift 逻辑坐标（左上角原点，Y 向下）一致
        float2 pos;
        float2 uv;
        if (vid == 0u) {
            pos = float2(-1.0f, 1.0f);
            uv = float2(0.0f, 0.0f);
        } else if (vid == 1u) {
            pos = float2(3.0f, 1.0f);
            uv = float2(2.0f, 0.0f);
        } else {
            pos = float2(-1.0f, -3.0f);
            uv = float2(0.0f, 2.0f);
        }
        out.position = float4(pos, 0.0f, 1.0f);
        out.uv = uv;
        return out;
    }

    inline float4 blendOver(float4 dst, float3 srcRGB, float srcA) {
        float a = clamp(srcA, 0.0f, 1.0f);
        return float4(srcRGB * a + dst.rgb * (1.0f - a), a + dst.a * (1.0f - a));
    }

    inline float2 rotate2D(float2 v, float angle) {
        float c = cos(angle);
        float s = sin(angle);
        return float2(v.x * c - v.y * s, v.x * s + v.y * c);
    }

    inline float wrapAngleDiff(float a, float b) {
        float d = a - b;
        const float pi = 3.1415926535f;
        const float twoPi = 6.283185307f;
        d = fmod(d + pi, twoPi);
        if (d < 0.0f) d += twoPi;
        return d - pi;
    }

    // 风格 1 光学色散露珠解析轮廓 SDF
    inline float sdPrismDew(float2 q, float tensionAngle, float tensionPull, float time, float capillaryAmp) {
        float lenQ = length(q);
        float a = atan2(q.y, q.x);
        float da = wrapAngleDiff(a, tensionAngle);
        float pull = max(0.0f, cos(da));
        float bulge = pull * pull * pull * tensionPull * 5.2f;
        float cap = sin(a * 5.0f + time * 14.0f) * capillaryAmp * 1.8f;
        return lenQ - (25.0f + bulge + cap);
    }

    // 风格 3 活体有机软玉解析轮廓 SDF
    inline float sdOrganicJade(float2 q, float tensionAngle, float tensionPull, float time, float capillaryAmp) {
        float lenQ = length(q);
        float a = atan2(q.y, q.x);
        float organic =
            sin(2.0f * a + time * 1.25f) * 1.7f +
            cos(3.0f * a - time * 0.95f) * 1.25f +
            sin(4.0f * a + time * 0.7f) * 0.6f;
        float da = wrapAngleDiff(a, tensionAngle);
        float lean = max(0.0f, cos(da)) * tensionPull * 4.2f;
        float cap = sin(a * 3.0f + time * 10.0f) * capillaryAmp * 1.5f;
        return lenQ - (24.5f + organic + lean + cap);
    }

    // 梯度修正近似椭圆距离场（保持丝带等宽且无分段锯齿）
    inline float sdWavyEllipseStroke(float2 rq, float amp, float tiltY, float speedT, float rIdx) {
        float th = atan2(rq.y, rq.x);
        float wave = sin(th * 2.0f + speedT * 1.8f + rIdx) * 3.2f;
        float rx = max(2.0f, amp + wave);
        float ry = max(2.0f, amp * tiltY + wave * 0.5f);
        float2 nr = float2(rq.x / rx, rq.y / ry);
        float f = length(nr) - 1.0f;
        float2 grad = float2(rq.x / (rx * rx), rq.y / (ry * ry));
        float gLen = max(0.0001f, length(grad));
        return abs(f) / gLen;
    }

    inline float sdWavyEllipseFill(float2 rq, float amp, float tiltY, float speedT, float rIdx) {
        float th = atan2(rq.y, rq.x);
        float wave = sin(th * 2.0f + speedT * 1.8f + rIdx) * 3.2f;
        float rx = max(2.0f, amp + wave);
        float ry = max(2.0f, amp * tiltY + wave * 0.5f);
        float2 nr = float2(rq.x / rx, rq.y / ry);
        float f = length(nr) - 1.0f;
        float2 grad = float2(rq.x / (rx * rx), rq.y / (ry * ry));
        float gLen = max(0.0001f, length(grad));
        return f / gLen;
    }

    fragment float4 spriteOrbFragment(
        VertexOut in [[stage_in]],
        constant SpriteOrbUniforms& u [[buffer(0)]],
        constant float4* particles [[buffer(1)]]
    ) {
        float panelSize = u.dims.x;
        float2 p = in.uv * panelSize;
        float2 orbCenter = u.dims.yz;
        float breathScale = max(0.2f, u.dims.w);
        float time = u.motion.x;
        float tensionPull = u.motion.y;
        float tensionAngle = u.motion.z;
        float capillaryAmp = u.motion.w;

        float hoverBlend = u.states.x;
        float vortexBlend = u.states.z;
        float crownAngle = u.states.w;

        float velAngle = u.stretch.x;
        float stretchAmt = u.stretch.y;
        float overallOpacity = u.stretch.z;

        float audioLevel = u.voiceAndNudge.x;
        float voiceBlend = u.voiceAndNudge.y;
        float cancelBlend = u.voiceAndNudge.z;
        float chargeProgress = u.voiceAndNudge.w;

        uint styleIdx = u.flags.x;
        bool isDark = (u.flags.y != 0u);
        uint matrixBits = u.flags.z;
        bool panelOpen = (u.flags.w & 1u) != 0u;
        bool dragTarget = (u.flags.w & 2u) != 0u;
        bool smartActive = (u.flags.w & 4u) != 0u;
        bool nudgeActive = (u.flags.w & 8u) != 0u;

        float breathWave = u.extra.x;
        float nudgeGlowAlpha = u.extra.y;

        // 活跃主题色（在长按语音划出取消区时平滑染为珊瑚红）
        float3 coralRed = float3(0.957f, 0.247f, 0.369f);
        float3 emerald = float3(0.063f, 0.725f, 0.506f);
        float3 amber = float3(0.961f, 0.620f, 0.043f);
        float3 accent = mix(u.accentRGB.rgb, coralRed, cancelBlend);

        float aa = 0.62f;
        float4 dst = float4(0.0f);

        // 将像素映射回精灵本体的果冻变形 + 呼吸缩放坐标系
        float2 dPos = p - orbCenter;
        float2 q = dPos;
        if (stretchAmt > 0.008f && styleIdx != 1u) {
            float2 r = rotate2D(q, -velAngle);
            r.x /= (1.0f + stretchAmt);
            r.y /= max(0.45f, 1.0f - stretchAmt * 0.55f);
            q = rotate2D(r, velAngle);
        }
        q /= breathScale;

        // 0. 剪贴板展开态 / 智能建议 / 拟态待办推进 / 语音声波外圈（底层氛围光晕与环）
        float distOrbRaw = length(dPos);
        if (voiceBlend > 0.02f) {
            float vBase = (27.5f + audioLevel * 10.5f) * breathScale;
            float ring1 = abs(distOrbRaw - vBase);
            float ring2 = abs(distOrbRaw - (vBase + 6.5f + sin(time * 9.0f) * 2.0f));
            float a1 = (1.0f - smoothstep(0.0f, 2.2f, ring1)) * 0.78f * voiceBlend;
            float a2 = (1.0f - smoothstep(0.0f, 2.6f, ring2)) * (0.28f + audioLevel * 0.35f) * voiceBlend;
            float3 vColor = mix(accent, coralRed, cancelBlend);
            dst = blendOver(dst, vColor, max(a1, a2));
        } else if (nudgeActive || nudgeGlowAlpha > 0.02f) {
            float pulse = 0.5f + 0.5f * sin(time * 5.2f);
            float nR = (28.5f + pulse * 2.8f) * breathScale;
            float dRing = abs(distOrbRaw - nR);
            float aRing = (1.0f - smoothstep(0.0f, 2.2f, dRing)) * (0.42f + 0.25f * pulse) * max(nudgeGlowAlpha, nudgeActive ? 1.0f : 0.0f);
            dst = blendOver(dst, amber, aRing);
        } else if (panelOpen) {
            float dOpen = abs(distOrbRaw - 29.0f * breathScale);
            float aOpen = (1.0f - smoothstep(0.0f, 1.6f, dOpen)) * (isDark ? 0.70f : 0.54f);
            dst = blendOver(dst, float3(0.118f, 0.369f, 1.0f), aOpen);
        } else if (smartActive) {
            float pulse = 0.45f + 0.45f * sin(time * 4.2f);
            float sR = (28.5f + pulse * 2.0f) * breathScale;
            float dSmart = abs(distOrbRaw - sR);
            float aSmart = (1.0f - smoothstep(0.0f, 1.6f, dSmart)) * (0.30f + 0.28f * pulse);
            dst = blendOver(dst, accent, aSmart);
        }

        // 长按蓄力进语音的环形进度条（0.12s ~ 0.36s）
        if (chargeProgress > 0.005f && voiceBlend < 0.5f) {
            float cR = 29.2f * breathScale;
            float dArc = abs(distOrbRaw - cR);
            if (dArc < 3.0f) {
                float theta = atan2(dPos.y, dPos.x) + 1.5707963f; // 12 点钟为 0
                if (theta < 0.0f) theta += 6.2831853f;
                float prog = theta / 6.2831853f;
                float maskArc = 1.0f - smoothstep(chargeProgress - 0.03f, chargeProgress + 0.01f, prog);
                float aArc = (1.0f - smoothstep(0.0f, 1.8f, dArc)) * maskArc * 0.92f;
                dst = blendOver(dst, emerald, aArc);
            }
        }

        // 外部内容拖入磁吸旋转虚线环
        if (dragTarget) {
            float dMag = abs(distOrbRaw - 41.0f);
            if (dMag < 3.0f) {
                float theta = atan2(dPos.y, dPos.x) * 14.0f - time * 6.5f;
                float dashMask = smoothstep(-0.15f, 0.2f, sin(theta));
                float aMag = (1.0f - smoothstep(0.0f, 1.8f, dMag)) * dashMask * 0.92f;
                dst = blendOver(dst, emerald, aMag);
            }
        }

        // ============================================================
        // 主材质渲染：0 露珠 / 1 表冠 / 2 软玉 / 3 极光丝灵
        // ============================================================
        if (styleIdx == 0u) {
            // 1. 解析式透镜底影
            float2 shPos = q - float2(0.0f, 5.0f + breathWave * 1.2f);
            float dSh = sdPrismDew(shPos, tensionAngle, tensionPull, time, capillaryAmp);
            float shStrength = isDark ? 0.44f : 0.17f;
            float shFalloff = exp(-max(0.0f, dSh + 1.5f) * 0.19f) * (1.0f - smoothstep(-10.0f, 20.0f, dSh) * 0.1f);
            float shAlpha = smoothstep(14.0f, -6.0f, dSh) * shStrength * shFalloff;
            float3 shColor = isDark ? float3(0.0f) : float3(0.059f, 0.090f, 0.165f);
            dst = blendOver(dst, shColor, shAlpha);

            // 主体折射区域
            float dMain = sdPrismDew(q, tensionAngle, tensionPull, time, capillaryAmp);
            float fillMask = 1.0f - smoothstep(-aa, aa, dMain * breathScale);

            if (fillMask > 0.001f) {
                // 透镜淡底径向渐变 (-8, -9) r=2..30
                float gradT = clamp((length(q - float2(-8.0f, -9.0f)) - 2.0f) / 28.0f, 0.0f, 1.0f);
                float3 baseCol;
                float baseA;
                if (isDark) {
                    float3 c0 = float3(1.0f);
                    float3 c1 = float3(0.58f, 0.77f, 1.0f);
                    float3 c2 = float3(0.06f, 0.09f, 0.16f);
                    if (gradT < 0.55f) {
                        float k = gradT / 0.55f;
                        baseCol = mix(c0, c1, k);
                        baseA = mix(0.24f, 0.10f, k);
                    } else {
                        float k = (gradT - 0.55f) / 0.45f;
                        baseCol = mix(c1, c2, k);
                        baseA = mix(0.10f, 0.36f, k);
                    }
                } else {
                    float3 c0 = float3(1.0f);
                    float3 c1 = float3(0.88f, 0.95f, 1.0f);
                    float3 c2 = float3(0.73f, 0.90f, 0.99f);
                    if (gradT < 0.65f) {
                        float k = gradT / 0.65f;
                        baseCol = mix(c0, c1, k);
                        baseA = mix(0.92f, 0.42f, k);
                    } else {
                        float k = (gradT - 0.65f) / 0.35f;
                        baseCol = mix(c1, c2, k);
                        baseA = mix(0.42f, 0.58f, k);
                    }
                }

                // 内部游动焦散水光纹 + 语音响度驱动
                float2 c1 = float2(cos(time * 1.2f) * 8.0f, sin(time * 1.5f) * 6.0f);
                float cDist = clamp((length(q - c1) - 1.0f) / (16.0f + audioLevel * 6.0f), 0.0f, 1.0f);
                float3 skyBlue = float3(0.22f, 0.74f, 0.97f);
                float3 caustCol = (cDist < 0.6f) ? mix(accent, skyBlue, cDist / 0.6f) : skyBlue;
                float caustA = (cDist < 0.6f) ? mix(0.44f + audioLevel * 0.25f, 0.18f, cDist / 0.6f) : mix(0.18f, 0.0f, (cDist - 0.6f) / 0.4f);

                // 顶部斜置弯月高光 (-0.38 rad)
                float2 specQ = rotate2D(q - float2(-6.0f, -11.0f), 0.38f);
                float dSpec = length(float2(specQ.x / 13.0f, specQ.y / 5.5f)) - 1.0f;
                float specMask = (1.0f - smoothstep(-0.08f, 0.08f, dSpec)) * (isDark ? 0.34f : 0.92f);

                // 底部反光弧 (0.45 .. 2.2 rad, r=21)
                float ang = atan2(q.y, q.x);
                float arcMask = (ang > 0.45f && ang < 2.2f) ? (1.0f - smoothstep(0.0f, 1.8f, abs(length(q) - 21.0f))) : 0.0f;
                float capEndFade = smoothstep(0.45f, 0.55f, ang) * (1.0f - smoothstep(2.1f, 2.2f, ang));
                float arcA = arcMask * capEndFade * 0.35f;

                float4 inner = float4(baseCol * baseA, baseA);
                inner = blendOver(inner, caustCol, caustA);
                inner = blendOver(inner, float3(1.0f), specMask);
                inner = blendOver(inner, accent, arcA);
                dst = blendOver(dst, inner.rgb / max(0.001f, inner.a), inner.a * fillMask);
            }

            // Leica RGB 错位三层色散光边
            float dCyan = sdPrismDew(q - float2(-0.9f, -0.6f), tensionAngle, tensionPull, time, capillaryAmp);
            float dRose = sdPrismDew(q - float2(0.9f, 0.6f), tensionAngle, tensionPull, time, capillaryAmp);
            float rimCyan = (1.0f - smoothstep(0.0f, 1.15f, abs(dCyan) * breathScale)) * 0.54f;
            float rimRose = (1.0f - smoothstep(0.0f, 1.15f, abs(dRose) * breathScale)) * 0.42f;
            float rimWhite = (1.0f - smoothstep(0.0f, 1.1f, abs(dMain) * breathScale)) * (isDark ? 0.58f : 0.95f);

            dst = blendOver(dst, float3(0.024f, 0.714f, 0.831f), rimCyan);
            dst = blendOver(dst, float3(0.957f, 0.247f, 0.369f), rimRose);
            dst = blendOver(dst, float3(1.0f), rimWhite);

        } else if (styleIdx == 1u) {
            // 风格 2 · 精密点阵表冠 (24 齿刻度 + 追光点 + 深墨微凹视窗 + 5x5 LED 矩阵)
            float rDial = 25.0f;
            float2 shPos = q - float2(0.0f, 5.0f + breathWave * 1.0f);
            float dSh = length(shPos) - rDial;
            float shAlpha = smoothstep(13.0f, -5.0f, dSh) * (isDark ? 0.52f : 0.20f) * exp(-max(0.0f, dSh + 1.5f) * 0.20f);
            dst = blendOver(dst, isDark ? float3(0.0f) : float3(0.059f, 0.090f, 0.165f), shAlpha);

            float lenQ = length(q);
            float dDial = lenQ - rDial;
            float dialMask = 1.0f - smoothstep(-aa, aa, dDial * breathScale);

            if (dialMask > 0.001f) {
                float metalT = clamp(((q.x + q.y) + 50.0f) / 100.0f, 0.0f, 1.0f);
                float3 m0 = isDark ? float3(0.165f, 0.188f, 0.235f) : float3(1.0f);
                float3 m1 = isDark ? float3(0.078f, 0.090f, 0.114f) : float3(0.863f, 0.886f, 0.925f);
                dst = blendOver(dst, mix(m0, m1, metalT), dialMask);

                // 24 齿旋转精密刻度
                float2 rotQ = rotate2D(q, -crownAngle);
                float ang = atan2(rotQ.y, rotQ.x);
                if (ang < 0.0f) ang += 6.2831853f;
                float sector = 6.2831853f / 24.0f;
                float fIdx = round(ang / sector);
                int tickIdx = int(fmod(fIdx, 24.0f));
                float aLocal = wrapAngleDiff(ang, fIdx * sector);
                float tickDistArc = abs(aLocal) * max(1.0f, lenQ);
                bool isMajor = (tickIdx % 6 == 0);
                float rIn = isMajor ? 20.5f : 21.8f;
                float rOut = 23.6f;
                float radMask = smoothstep(rIn - 0.5f, rIn + 0.3f, lenQ) * (1.0f - smoothstep(rOut - 0.3f, rOut + 0.5f, lenQ));
                float halfW = isMajor ? 0.62f : 0.42f;
                float tickAlpha = (1.0f - smoothstep(halfW - 0.2f, halfW + 0.35f, tickDistArc)) * radMask * (isDark ? 0.24f : 0.26f);
                dst = blendOver(dst, isDark ? float3(1.0f) : float3(0.059f, 0.090f, 0.165f), tickAlpha * dialMask);

                // 追光信号指标圆点 (在局部角 0 处 r = 21.2)
                float dotDist = length(rotQ - float2(21.2f, 0.0f)) - 2.3f;
                float dotAlpha = 1.0f - smoothstep(-aa, aa, dotDist * breathScale);
                dst = blendOver(dst, accent, dotAlpha);
            }

            // 外盘细边框
            float dDialRim = abs(dDial) * breathScale;
            float dialRimA = (1.0f - smoothstep(0.0f, 1.1f, dDialRim)) * (isDark ? 0.18f : 0.85f);
            float3 dialRimCol = isDark ? float3(1.0f) : float3(0.773f, 0.808f, 0.859f);
            dst = blendOver(dst, dialRimCol, dialRimA);

            // 中心深墨微凹 OLED 视窗 r = 15.5
            float dOled = lenQ - 15.5f;
            float oledMask = 1.0f - smoothstep(-aa, aa, dOled * breathScale);
            if (oledMask > 0.001f) {
                float3 oledBg = isDark ? float3(0.039f, 0.047f, 0.063f) : float3(0.067f, 0.094f, 0.153f);
                dst = blendOver(dst, oledBg, oledMask);

                // 5×5 LED 矩阵：cell 间距 4.0pt
                float stepGrid = 4.0f;
                float2 cellF = clamp(round(q / stepGrid), float2(-2.0f), float2(2.0f));
                int col = int(cellF.x) + 2;
                int row = int(cellF.y) + 2;
                float2 cellCenter = cellF * stepGrid;
                float cellDist = length(q - cellCenter);

                bool eqMode = (matrixBits & (1u << 26u)) != 0u;
                bool blinkMode = (matrixBits & (1u << 27u)) != 0u;
                bool hasGlyph = (matrixBits & (1u << 25u)) != 0u;

                float dotRadius = 1.0f;
                float dotA = 0.0f;
                float3 dotCol = float3(0.973f, 0.980f, 0.988f);

                if (eqMode) {
                    // 语音 5 柱动态音阶均衡器
                    float waveCol = 0.35f + 0.65f * abs(sin(time * 10.5f + float(col) * 1.15f));
                    float levelNorm = clamp(0.18f + audioLevel * 1.05f * waveCol, 0.15f, 1.0f);
                    float litRows = levelNorm * 5.0f;
                    float rowFromBottom = float(4 - row) + 0.4f;
                    bool lit = (rowFromBottom < litRows);
                    dotRadius = lit ? 1.32f : 0.72f;
                    dotCol = lit ? accent : float3(1.0f);
                    dotA = lit ? 0.96f : 0.14f;
                } else if (blinkMode) {
                    // 拟态好奇眨眼微表情
                    float blinkCycle = fmod(time, 2.8f);
                    bool closed = (blinkCycle > 2.45f && blinkCycle < 2.62f);
                    bool isEyeCol = (col == 1 || col == 3);
                    bool litEye = closed ? (row == 2 && (col == 0 || col == 1 || col == 3 || col == 4)) : (isEyeCol && (row == 1 || row == 2));
                    bool smileBottom = (row == 3 && (col == 1 || col == 2 || col == 3));
                    bool lit = litEye || smileBottom;
                    dotRadius = lit ? 1.30f : 0.72f;
                    dotCol = lit ? amber : float3(1.0f);
                    dotA = lit ? 0.96f : 0.12f;
                } else if (hasGlyph) {
                    uint bitIndex = uint(row * 5 + col);
                    bool lit = ((matrixBits >> bitIndex) & 1u) != 0u;
                    float distFromCenter = length(cellF);
                    dotRadius = lit ? (1.28f + sin(time * 4.0f - distFromCenter) * 0.16f) : 0.75f;
                    dotCol = lit ? accent : float3(1.0f);
                    dotA = lit ? 0.95f : 0.12f;
                } else {
                    float distFromCenter = length(cellF);
                    float wave = sin(time * 2.5f - distFromCenter * 1.1f);
                    float lum = max(0.14f, 0.42f + wave * 0.42f);
                    dotRadius = 1.0f + max(0.0f, wave) * 0.45f;
                    bool isMid = (col == 2 && row == 2);
                    dotCol = isMid ? accent : float3(0.973f, 0.980f, 0.988f);
                    dotA = isMid ? 1.0f : lum;
                }

                float ledMask = (1.0f - smoothstep(-aa, aa, (cellDist - dotRadius) * breathScale)) * dotA * oledMask;
                dst = blendOver(dst, dotCol, ledMask);
            }
            float dOledRim = abs(dOled) * breathScale;
            float oledRimA = (1.0f - smoothstep(0.0f, 0.9f, dOledRim)) * (isDark ? 0.12f : 0.22f);
            dst = blendOver(dst, isDark ? float3(1.0f) : float3(0.059f, 0.090f, 0.165f), oledRimA);

        } else if (styleIdx == 2u) {
            // 风格 3 · 活体有机软玉
            float2 shPos = q - float2(0.0f, 4.5f + breathWave * 1.2f);
            float dSh = sdOrganicJade(shPos, tensionAngle, tensionPull, time, capillaryAmp);
            float shAlpha = smoothstep(13.0f, -5.0f, dSh) * (isDark ? 0.48f : 0.16f) * exp(-max(0.0f, dSh + 1.5f) * 0.18f);
            dst = blendOver(dst, isDark ? float3(0.0f) : float3(0.059f, 0.090f, 0.165f), shAlpha);

            float dJade = sdOrganicJade(q, tensionAngle, tensionPull, time, capillaryAmp);
            float jadeMask = 1.0f - smoothstep(-aa, aa, dJade * breathScale);

            if (jadeMask > 0.001f) {
                float gradT = clamp((length(q - float2(-8.0f, -8.0f)) - 2.0f) / 28.0f, 0.0f, 1.0f);
                float3 j0 = isDark ? float3(0.165f, 0.212f, 0.224f) : float3(1.0f);
                float3 j1 = isDark ? float3(0.067f, 0.090f, 0.098f) : float3(0.902f, 0.929f, 0.910f);
                float3 baseJade = mix(j0, j1, gradT);

                // 内蕴柔雾随呼吸慢游
                float2 mistPt = float2(cos(time * 0.9f) * 6.0f, sin(time * 1.1f) * 5.0f);
                float mistDist = clamp((length(q - mistPt) - 1.0f) / (19.0f + audioLevel * 5.0f), 0.0f, 1.0f);
                float3 defaultMist = isDark ? float3(0.204f, 0.827f, 0.600f) : emerald;
                float3 mistCol = (panelOpen || smartActive || nudgeActive || voiceBlend > 0.05f) ? accent : defaultMist;
                float mistA = (1.0f - mistDist) * (isDark ? 0.44f : 0.28f);

                // 柔哑陶瓷月牙光斑 (-0.35 rad)
                float2 specQ = rotate2D(q - float2(-6.0f, -12.0f), 0.35f);
                float dSpec = length(float2(specQ.x / 11.0f, specQ.y / 4.2f)) - 1.0f;
                float specA = (1.0f - smoothstep(-0.08f, 0.08f, dSpec)) * (isDark ? 0.16f : 0.88f);

                float4 inner = float4(baseJade, 1.0f);
                inner = blendOver(inner, mistCol, mistA);
                inner = blendOver(inner, float3(1.0f), specA);
                dst = blendOver(dst, inner.rgb / max(0.001f, inner.a), inner.a * jadeMask);
            }

            float dJadeRim = abs(dJade) * breathScale;
            float rimA = (1.0f - smoothstep(0.0f, 1.1f, dJadeRim)) * (isDark ? 0.18f : 0.92f);
            dst = blendOver(dst, float3(1.0f), rimA);

        } else {
            // 风格 4 · 无框极光丝灵 (4 层 3D 李萨如光绸丝带 + 半透光纱 + 6 颗星核微粒簇)
            float3 pal[4];
            if (isDark) {
                pal[0] = accent;
                pal[1] = float3(0.220f, 0.741f, 0.973f);
                pal[2] = float3(0.506f, 0.549f, 0.973f);
                pal[3] = float3(0.204f, 0.827f, 0.600f);
            } else {
                pal[0] = accent;
                pal[1] = float3(0.008f, 0.518f, 0.780f);
                pal[2] = float3(0.310f, 0.275f, 0.898f);
                pal[3] = float3(0.055f, 0.647f, 0.914f);
            }
            if (cancelBlend > 0.1f) {
                pal[1] = mix(pal[1], coralRed, cancelBlend);
                pal[2] = mix(pal[2], coralRed, cancelBlend * 0.8f);
            }

            // 极微底层氛围柔晕
            float auraR = 32.0f + breathWave * 4.0f + audioLevel * 8.0f;
            float auraDist = clamp((length(q) - 2.0f) / max(4.0f, auraR - 2.0f), 0.0f, 1.0f);
            float auraA = (1.0f - smoothstep(0.0f, 1.0f, auraDist)) * (isDark ? 0.22f : 0.14f);
            dst = blendOver(dst, accent, auraA);

            float amp = (19.0f + breathWave * 3.8f + hoverBlend * 3.5f + audioLevel * 5.2f) * (1.0f - vortexBlend * 0.25f);
            float speedBoost = 1.0f + hoverBlend * 0.7f + vortexBlend * 1.4f + voiceBlend * 0.9f;
            float speedT = time * 1.35f * speedBoost;

            for (int rIdx = 0; rIdx < 4; rIdx++) {
                float dir = (rIdx % 2 == 0) ? 0.42f : -0.34f;
                float rot = float(rIdx) * 0.78f + speedT * dir;
                float tiltY = 0.46f + 0.16f * sin(speedT * 0.9f + float(rIdx));
                float2 rq = rotate2D(q, -rot);

                float dFill = sdWavyEllipseFill(rq, amp, tiltY, speedT, float(rIdx));
                float fillMask = 1.0f - smoothstep(-aa, aa, dFill * breathScale);
                float fillA = (isDark ? 0.08f : 0.06f) * fillMask;
                dst = blendOver(dst, pal[rIdx], fillA);

                float dStroke = sdWavyEllipseStroke(rq, amp, tiltY, speedT, float(rIdx));
                float halfWidth = (rIdx == 0) ? 1.25f : 0.92f;
                float strokeMask = 1.0f - smoothstep(halfWidth - 0.35f, halfWidth + 0.65f, dStroke * breathScale);
                float softGlow = exp(-max(0.0f, dStroke * breathScale - halfWidth) * 0.55f) * 0.20f;
                float strokeOpacity = (isDark ? 0.70f : 0.74f) + float(rIdx) * 0.06f;
                dst = blendOver(dst, pal[rIdx], max(strokeMask * strokeOpacity, softGlow));
            }

            // 中央 6 颗错速星核微粒簇
            for (int d = 0; d < 6; d++) {
                float ang = time * (1.2f + float(d) * 0.25f) + float(d) * 1.05f;
                float dist = 5.0f + sin(time * 2.2f + float(d)) * 3.5f + audioLevel * 2.2f;
                float2 dotPt = float2(cos(ang) * dist, sin(ang) * dist);
                float dStar = length(q - dotPt) - 1.35f;
                float aStar = (1.0f - smoothstep(-aa, aa, dStar * breathScale)) * 0.88f;
                float3 sCol = (d % 2 == 0) ? float3(1.0f) : accent;
                dst = blendOver(dst, sCol, aStar);
            }
        }

        // ============================================================
        // 同 Pass 叠加：扩散波纹 + 吸入流光粒子 + 采纳火花
        // ============================================================
        for (int i = 0; i < 3; i++) {
            float4 rp = u.ripples[i];
            float rawA = rp.w;
            if (abs(rawA) > 0.01f) {
                float rDist = abs(length(p - rp.xy) - rp.z);
                float aRing = (1.0f - smoothstep(0.0f, 1.55f, rDist)) * clamp(abs(rawA) * 0.60f, 0.0f, 1.0f);
                float3 rCol = (rawA < 0.0f) ? emerald : accent;
                dst = blendOver(dst, rCol, aRing);
            }
        }

        for (int i = 0; i < 24; i++) {
            float4 pt = particles[i];
            float rawA = pt.w;
            if (abs(rawA) > 0.005f) {
                float dPt = length(p - pt.xy) - pt.z;
                float aPt = (1.0f - smoothstep(-0.5f, 0.7f, dPt)) * clamp(abs(rawA), 0.0f, 1.0f);
                float3 pCol;
                if (rawA < 0.0f) {
                    pCol = float3(1.0f);
                } else if (i >= 12) {
                    pCol = emerald;
                } else {
                    pCol = accent;
                }
                dst = blendOver(dst, pCol, aPt);
            }
        }

        return dst * overallOpacity;
    }
    """#
}
