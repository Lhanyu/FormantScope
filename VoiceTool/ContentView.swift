//
//  ContentView.swift
//  VoiceTool
//
//  Created by Hanyu on 2026/4/25.
//

import SwiftUI
import AVFoundation
import Charts

struct ContentView: View {

    @StateObject private var analyzer = AudioAnalyzer()
    @State private var isRunning = false
    /// 主区卡片在屏幕坐标系（命名 "rootSpace"）下的 frame，由前景 placeholder 通过
    /// PreferenceKey 上报给后景全屏图表。后景图表据此把 [0,1] Y 域精准对齐到这块区域，
    /// 超出 [0,1] 的部分自然往整屏上下溢出（曲线越界变"探出主区"的 geek 效果）。
    @State private var cardFrame: CGRect = .zero

    var body: some View {
        ZStack {
            // ===== Layer 0：后景全屏图表 =====
            // 把 [0,1] Y 域精确贴合 cardFrame 在屏幕中的位置；
            // 曲线超出 [0,1] 的部分会自然伸到屏幕顶/底，越过读数和能量条所在 Y 区间。
            // 在 z 序上它处在最底层，所有其他组件都在它之上，不会"挡住"这些组件。
            GeometryReader { geo in
                BackgroundVoiceChart(
                    pitchHistory: analyzer.pitchHistory,
                    f2History:    analyzer.f2History,
                    cardFrame:    cardFrame,
                    rootSize:     geo.size
                )
            }

            // ===== Layer 1：主区卡片底色 =====
            // 与 cardFrame 对齐的圆角矩形浅底色，半透明，让后景曲线在主区里也能看见
            // 但视觉上有一个"主舞台"边界。处于图表线条之上、前景文本之下。
            if cardFrame.height > 1 {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.secondary.opacity(0.06))
                    .frame(width: cardFrame.width, height: cardFrame.height)
                    .position(x: cardFrame.midX, y: cardFrame.midY)
                    .allowsHitTesting(false)
            }

            // ===== Layer 2：前景 UI =====
            // 读数 / 主区 placeholder / 能量条 / 按钮，全部在 ZStack 顶层。
            // placeholder 用 Color.clear 占位 320pt，并把自身 frame 通过 PreferenceKey
            // 暴露给后景图表，确保 [0,1] Y 域和这块区域 1:1 对齐。
            VStack(spacing: 0) {
                Spacer()

                // 频率数字显示区：F0 + F2 并排
                HStack(spacing: 32) {
                    FrequencyReadout(
                        label: "F0 Fundamental",
                        value: analyzer.pitch,
                        color: .red
                    )

                    Divider().frame(height: 60)

                    FrequencyReadout(
                        label: "F2 Formant",
                        value: analyzer.f2,
                        color: .green
                    )
                }

                Spacer().frame(height: 40)

                // 主区 placeholder：透明占位 + 上报 frame
                // 注意：.background 在 .padding 之前 —— 这样上报的 frame 是
                // padding 内侧的实际可视主区（width = parent - 48），而不是带 padding
                // 的外框，跟卡片底色和图表 [0,1] 视觉上才能对齐。
                Color.clear
                    .frame(height: 320)
                    .background(
                        GeometryReader { cardGeo in
                            Color.clear.preference(
                                key: CardFrameKey.self,
                                value: cardGeo.frame(in: .named("rootSpace"))
                            )
                        }
                    )
                    .padding(.horizontal, 24)

                Spacer().frame(height: 12)

                // 幅度指示条（辅助确认麦克风信号）
                AmplitudeBar(amplitude: analyzer.amplitude)
                    .frame(height: 8)
                    .padding(.horizontal, 48)

                Spacer()

                // 启停按钮
                Button {
                    if isRunning {
                        analyzer.stop()
                        isRunning = false
                    } else {
                        isRunning = analyzer.start()
                    }
                } label: {
                    Label(
                        isRunning ? "Stop Listening" : "Start Listening",
                        systemImage: isRunning ? "stop.circle.fill" : "mic.circle.fill"
                    )
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
                .buttonStyle(.borderedProminent)
                .tint(isRunning ? .red : .accentColor)
                .padding(.horizontal, 32)
                .padding(.bottom, 48)
                .animation(.easeInOut(duration: 0.2), value: isRunning)
            }
        }
        .coordinateSpace(name: "rootSpace")
        .onPreferenceChange(CardFrameKey.self) { rect in
            cardFrame = rect
        }
        .onAppear {
            requestMicrophonePermission()
        }
    }

    // MARK: - Helpers

    private func requestMicrophonePermission() {
#if os(iOS)
        AVAudioApplication.requestRecordPermission { _ in }
#elseif os(macOS)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        default:
            break
        }
#endif
    }
}

// MARK: - CardFrameKey

/// 把前景"主区 placeholder"的 frame（屏幕坐标系）上报给后景图表用于对齐。
///
/// reduce 只接受非空值——SwiftUI 在 reduce 整棵子树的偏好时，没有显式调用
/// `.preference(...)` 的视图也会贡献一个默认值（CGRect.zero）；如果 reduce
/// 简单写成 `value = nextValue()`，最后一个被遍历到的视图（通常是没设值的那种）
/// 就会把真正的 placeholder frame 覆盖回 .zero，导致 cardFrame 永远拿不到。
private struct CardFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.width > 0 && next.height > 0 {
            value = next
        }
    }
}

// MARK: - FrequencyReadout

/// 单个频率参数的数字显示组件（标签 + 数值 + 单位）。
private struct FrequencyReadout: View {
    let label: LocalizedStringKey
    let value: Float
    let color: Color

    private var displayText: String {
        value > 0 ? String(format: "%.0f", value) : "---"
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            Text(displayText)
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(value > 0 ? color : .secondary)
                .contentTransition(.numericText())
                .animation(.spring(duration: 0.2), value: value)

            Text("Hz")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - AmplitudeBar

/// 轻量幅度条，用于肉眼确认麦克风是否在接收信号。
///
/// 设计要点：
/// - 噪声地板门控：amplitude < 0.075 → 不显示，避免静音时有残余
/// - 渐变固定于全宽，用 mask 裁剪到当前电平位置，红色始终对应满量程右端
private struct AmplitudeBar: View {
    let amplitude: Float

    private var fraction: CGFloat {
        // 与 PitchTap 使用同一门限：低于 amplitudeThreshold 视为静音，直接归零
        let gate = AudioAnalyzer.amplitudeThreshold   // 0.15
        guard amplitude >= gate else { return 0 }
        // 映射：gate → 0，gate+0.50 → 1.0
        // 正常说话 0.20–0.35 时填到 ~10–40%；大声 0.40–0.50 时到 ~50–70%；喊叫才接近顶满。
        // （原系数 5.0 意味着 gate+0.20 就顶满，太容易"撞顶"，改为 2.0 留足头室。）
        return CGFloat(min(Double(amplitude - gate) * 2.0, 1.0))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // 背景轨道
                Capsule()
                    .fill(Color.secondary.opacity(0.15))

                // 渐变始终覆盖全宽，用 mask 裁剪到当前电平 —— 红色永远在满量程右端
                LinearGradient(
                    colors: [.green, .yellow, .red],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .clipShape(Capsule())
                .mask(alignment: .leading) {
                    Rectangle()
                        .frame(width: geo.size.width * fraction)
                        .animation(.easeOut(duration: 0.08), value: fraction)
                }
            }
        }
    }
}

// MARK: - BackgroundVoiceChart
//
// 全屏背景图表：F0（红实线）/ F2（绿虚线）双轨；以归一化坐标系工作，
// 但 chartYScale 的域并非固定 [0,1]，而是动态扩展到屏幕顶/底，使得
// [0,1] 在屏幕上恰好对应前景 placeholder（"主区卡片"）的位置。
// 数据值不再在主区边界 clamp，越界的曲线会自然延伸到屏幕上方/下方，
// 由前景 UI 的 z 序覆盖来确保不"反向遮挡"读数 / 能量条 / 按钮。
private struct BackgroundVoiceChart: View {

    let pitchHistory: [Float?]
    let f2History:    [Float?]
    /// 主区卡片在 "rootSpace" 坐标系的 frame；高度 0 表示尚未完成首次布局
    let cardFrame: CGRect
    /// ZStack 根容器尺寸，用来计算 Y 域上下沿对应屏幕顶/底的归一化值
    let rootSize:  CGSize

    // MARK: - 频率范围（与原 VoiceChart 一致）
    private static let f0Min: Double = 50,   f0Max: Double = 600
    private static let f2Min: Double = 500,  f2Max: Double = 3_500

    private static func normF0(_ hz: Double) -> Double { (hz - f0Min) / (f0Max - f0Min) }
    private static func normF2(_ hz: Double) -> Double { (hz - f2Min) / (f2Max - f2Min) }

    private static let f0NormTicks: [Double] = [100, 200, 300, 400, 500].map(normF0)
    private static let f0Labels:    [String] = ["100", "200", "300", "400", "500"]

    private static let f2NormTicks: [Double] = [700, 1_000, 1_500, 2_000, 2_500, 3_000].map(normF2)
    private static let f2Labels:    [String] = ["700", "1k", "1.5k", "2k", "2.5k", "3k"]

    private struct DataPoint: Identifiable {
        let id: Int
        let index: Int
        let norm: Double
        let segment: Int
    }

    /// 构造数据点：保持原有的 nil 分段逻辑，但不再把 norm clamp 到 [0,1]，
    /// 而是 clamp 到当前扩展 Y 域，让超量程值仍可见且不会被裁出图表 frame。
    private func makePoints(_ history: [Float?],
                            norm: @escaping (Double) -> Double,
                            yMin: Double,
                            yMax: Double) -> [DataPoint] {
        var result: [DataPoint] = []
        var segmentID = 0
        var prevWasNil = true
        for (index, value) in history.enumerated() {
            guard let f = value else { prevWasNil = true; continue }
            if prevWasNil { segmentID += 1 }
            let raw = norm(Double(f))
            let n = max(yMin, min(yMax, raw))
            result.append(DataPoint(id: index, index: index, norm: n, segment: segmentID))
            prevWasNil = false
        }
        return result
    }

    var body: some View {
        // 即便 cardFrame 尚未上报（首帧）也照常渲染：用 [0,1] 兜底，相当于退化成
        // "没有溢出区"的旧行为。一旦 PreferenceKey 把 cardFrame 推上来，body 会
        // 重新计算扩展 Y 域，曲线就会自然延展到整屏。
        chartView
    }

    /// Y 域映射：
    ///   plot Y = 1 ↔ 屏幕 y = cardFrame.minY（主区顶）
    ///   plot Y = 0 ↔ 屏幕 y = cardFrame.maxY（主区底）
    ///   线性映射: plotY = (cardFrame.maxY - screenY) / cardFrame.height
    /// 当 cardFrame 尚未就绪时退回 [0,1]。
    private var yDomain: (min: Double, max: Double) {
        guard cardFrame.height > 1, rootSize.height > 1 else {
            return (0, 1)
        }
        let yMax = Double(cardFrame.maxY) / Double(cardFrame.height)
        let yMin = Double(cardFrame.maxY - rootSize.height) / Double(cardFrame.height)
        return (yMin, yMax)
    }

    @ViewBuilder
    private var chartView: some View {
        let (yMin, yMax) = (yDomain.min, yDomain.max)

        let f0Pts = makePoints(pitchHistory, norm: Self.normF0, yMin: yMin, yMax: yMax)
        let f2Pts = makePoints(f2History,    norm: Self.normF2, yMin: yMin, yMax: yMax)

        Chart {
            // F0 — 红色实线
            ForEach(f0Pts) { p in
                LineMark(
                    x: .value("Frame", p.index),
                    y: .value("n", p.norm),
                    series: .value("s", "f0-\(p.segment)")
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(.red)
                .lineStyle(StrokeStyle(lineWidth: 2))
            }
            // F2 — 绿色虚线
            ForEach(f2Pts) { p in
                LineMark(
                    x: .value("Frame", p.index),
                    y: .value("n", p.norm),
                    series: .value("s", "f2-\(p.segment)")
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(.green)
                .lineStyle(StrokeStyle(lineWidth: 2, dash: [6, 4]))
            }
        }
        .chartXScale(domain: 0 ... 99)
        .chartYScale(domain: yMin ... yMax)
        // 不画 X 网格：避免在主区外的溢出区段也出现密集竖线，污染整屏背景
        .chartXAxis(.hidden)
        .chartYAxis {
            // 左轴：F0 刻度（红色）+ 网格线 —— 刻度值都在 [0,1]，所以仅在主区内显示
            AxisMarks(position: .leading, values: Self.f0NormTicks) { val in
                AxisValueLabel {
                    if let v = val.as(Double.self),
                       let i = Self.f0NormTicks.firstIndex(where: { abs($0 - v) < 0.001 }) {
                        Text(Self.f0Labels[i])
                            .font(.system(size: 9))
                            .foregroundStyle(.red.opacity(0.8))
                    }
                }
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))
                    .foregroundStyle(Color.secondary.opacity(0.15))
            }
            // 右轴：F2 刻度（绿色）— 仅标签
            AxisMarks(position: .trailing, values: Self.f2NormTicks) { val in
                AxisValueLabel {
                    if let v = val.as(Double.self),
                       let i = Self.f2NormTicks.firstIndex(where: { abs($0 - v) < 0.001 }) {
                        Text(Self.f2Labels[i])
                            .font(.system(size: 9))
                            .foregroundStyle(.green.opacity(0.8))
                    }
                }
            }
        }
        .padding(.horizontal, 24)   // 与前景 placeholder 对齐宽度
        .allowsHitTesting(false)    // 后景层不响应触摸，避免拦住按钮
    }
}


#Preview {
    ContentView()
}
