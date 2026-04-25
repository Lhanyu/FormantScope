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

    var body: some View {
        ZStack {
            VStack(spacing: 40) {
                Spacer()

                // 频率数字显示区：F0 + F2 并排
                HStack(spacing: 32) {
                    FrequencyReadout(
                        label: "F0 基频",
                        value: analyzer.pitch,
                        color: .red
                    )

                    Divider().frame(height: 60)

                    FrequencyReadout(
                        label: "F2 共振峰",
                        value: analyzer.f2,
                        color: .green
                    )
                }

                // 实时双曲线折线图（F0 左轴 / F2 右轴）
                VoiceChart(
                    pitchHistory: analyzer.pitchHistory,
                    f2History:    analyzer.f2History
                )
                .frame(height: 220)
                .padding(.horizontal, 24)

                // 幅度指示条（辅助确认麦克风信号）
                AmplitudeBar(amplitude: analyzer.amplitude)
                    .frame(height: 8)
                    .padding(.horizontal, 48)

                Spacer()

                // 启停按钮
                Button {
                    isRunning ? analyzer.stop() : analyzer.start()
                    isRunning.toggle()
                } label: {
                    Label(
                        isRunning ? "停止监听" : "开始监听",
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

// MARK: - FrequencyReadout

/// 单个频率参数的数字显示组件（标签 + 数值 + 单位）。
private struct FrequencyReadout: View {
    let label: String
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
        // 映射：gate → 0，gate+0.20 → 1.0（正常说话约 0.20–0.35）
        return CGFloat(min(Double(amplitude - gate) * 5.0, 1.0))
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

// MARK: - VoiceChart
//
// 双 Y 轴叠加图：F0（红）和 F2（绿）共享同一个 Chart，
// 各自归一化到 [0, 1] 坐标系，左轴显示 F0 Hz 刻度，右轴显示 F2 Hz 刻度。
// Swift Charts 不原生支持双轴，用归一化坐标 + 两组 AxisMarks 模拟。
private struct VoiceChart: View {

    let pitchHistory: [Float?]
    let f2History:    [Float?]

    // MARK: - 坐标范围
    private static let f0Min: Double = 50,   f0Max: Double = 600
    private static let f2Min: Double = 500,  f2Max: Double = 3_500

    // 归一化公式
    private static func normF0(_ hz: Double) -> Double { (hz - f0Min) / (f0Max - f0Min) }
    private static func normF2(_ hz: Double) -> Double { (hz - f2Min) / (f2Max - f2Min) }

    // 左轴（F0）刻度：归一化位置 + 显示文字
    private static let f0NormTicks: [Double] = [100, 200, 300, 400, 500].map(normF0)
    private static let f0Labels:    [String] = ["100", "200", "300", "400", "500"]

    // 右轴（F2）刻度
    private static let f2NormTicks: [Double] = [700, 1_000, 1_500, 2_000, 2_500, 3_000].map(normF2)
    private static let f2Labels:    [String] = ["700", "1k", "1.5k", "2k", "2.5k", "3k"]

    // MARK: - 数据模型
    private struct DataPoint: Identifiable {
        let id: Int
        let index: Int
        let norm: Double   // 归一化到 [0, 1]
        let segment: Int
    }

    private func makePoints(_ history: [Float?],
                            norm: @escaping (Double) -> Double) -> [DataPoint] {
        var result: [DataPoint] = []
        var segmentID = 0
        var prevWasNil = true
        for (index, value) in history.enumerated() {
            guard let f = value else { prevWasNil = true; continue }
            if prevWasNil { segmentID += 1 }
            let n = max(0, min(1, norm(Double(f))))
            result.append(DataPoint(id: index, index: index, norm: n, segment: segmentID))
            prevWasNil = false
        }
        return result
    }

    // MARK: - Body
    var body: some View {
        let f0Pts = makePoints(pitchHistory, norm: Self.normF0)
        let f2Pts = makePoints(f2History,    norm: Self.normF2)

        Chart {
            // F0 — 红色实线
            ForEach(f0Pts) { p in
                LineMark(
                    x: .value("帧", p.index),
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
                    x: .value("帧", p.index),
                    y: .value("n", p.norm),
                    series: .value("s", "f2-\(p.segment)")
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(.green)
                .lineStyle(StrokeStyle(lineWidth: 2, dash: [6, 4]))
            }
        }
        .chartXScale(domain: 0 ... 99)
        .chartXAxis {
            AxisMarks(values: .stride(by: 10)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))
                    .foregroundStyle(Color.secondary.opacity(0.2))
            }
        }
        .chartYScale(domain: 0 ... 1)
        .chartYAxis {
            // 左轴：F0 刻度（红色）+ 网格线
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
            // 右轴：F2 刻度（绿色）— 仅标签，无额外网格线
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
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.secondary.opacity(0.06))
        )
    }
}


#Preview {
    ContentView()
}
