//
//  ContentView.swift
//  FormantScope
//
//  Created by Hanyu on 2026/4/25.
//

import SwiftUI
import AVFoundation
import Charts
#if os(macOS)
import AppKit
#endif

struct ContentView: View {

#if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
#endif

    @StateObject private var analyzer = AudioAnalyzer()
    @ObservedObject private var folderStore = RecordingFolderStore.shared
    @State private var isRunning = false
    @State private var isRecordingArmed = false
    /// 选完文件夹后是否自动进入录音（首次点 Record 触发选目录时使用）。
    @State private var pendingArmRecordAfterPick = false
    @State private var showFolderPicker = false
    /// 主区卡片在屏幕坐标系（命名 "rootSpace"）下的 frame，由前景 placeholder 通过
    /// PreferenceKey 上报给后景全屏图表。后景图表据此把 [0,1] Y 域精准对齐到这块区域，
    /// 超出 [0,1] 的部分自然往整屏上下溢出（曲线越界变"探出主区"的 geek 效果）。
    @State private var cardFrame: CGRect = .zero
    /// 底部录制 + 停止聆听两个按钮的 HStack 在 rootSpace 中的外接矩形，用于对齐保存浮窗。
    @State private var controlStripFrame: CGRect = .zero

    // MARK: 持久化设置
    @AppStorage("showF1")  private var showF1:  Bool   = true
    @AppStorage("showF2")  private var showF2:  Bool   = true
    @AppStorage("f0Min")   private var f0Min:   Double = 50
    @AppStorage("f0Max")   private var f0Max:   Double = 600
    @AppStorage("fmtMin")  private var fmtMin:  Double = 200
    @AppStorage("fmtMax")  private var fmtMax:  Double = 3_500

#if os(iOS)
    @State private var showSettings = false
#endif

    private var controlRoomSpring: Animation {
        .spring(response: 0.42, dampingFraction: 0.86)
    }

    var body: some View {
        // 最外层 GeometryReader：第一帧就能拿到真实窗口尺寸，
        // 避免用 @State 默认值 + PreferenceKey 回调的"两帧"方案带来的初始错位。
        GeometryReader { geo in
            // MARK: 自适应布局参数（基于真实 geo.size 实时计算）
            let hScale: CGFloat = max(0.5, min(1.4, geo.size.height / 640))
            let wScale: CGFloat = max(0.5, min(1.4, geo.size.width  / 400))
            let chartHeight:           CGFloat = max(120, 320 * hScale)
            let spacerReadoutToChart:  CGFloat = max(8,   40  * hScale)
            let spacerChartToBar:      CGFloat = max(4,   12  * hScale)
            let buttonBottomPad:       CGFloat = max(12,  48  * hScale)
            let readoutSpacing:        CGFloat = max(8,   24  * min(hScale, wScale))
            let dividerHeight:         CGFloat = max(32,  60  * hScale)
#if os(iOS)
            // 窄屏：列间距与字号同步收紧，避免 F0/F1/F2 三列挤破屏宽。
            let w = geo.size.width
            let readoutHSpacing: CGFloat = {
                if w < 340 { return 2 }
                if w < 380 { return 4 }
                if w < 420 { return 6 }
                return readoutSpacing
            }()
            let readoutLabelFont: CGFloat = {
                if w < 340 { return 9 }
                if w < 380 { return 10 }
                if w < 420 { return 11 }
                return 12
            }()
            let readoutValueFont: CGFloat = {
                if w < 340 { return 32 }
                if w < 380 { return 36 }
                if w < 420 { return 40 }
                return 46
            }()
            let readoutUnitFont: CGFloat = {
                if w < 340 { return 11 }
                if w < 380 { return 12 }
                return 14
            }()
            let readoutDividerH: CGFloat = {
                if w < 380 { return max(26, dividerHeight * 0.72) }
                return dividerHeight
            }()
            /// 读数区与屏幕左右边距（原仅依赖全宽 HStack，边缘偏紧）。
            let readoutEdgePadding: CGFloat = {
                if w < 340 { return 16 }
                if w < 380 { return 20 }
                if w < 420 { return 24 }
                return 28
            }()
#endif
#if os(iOS)
            let readoutStackSpacing = readoutHSpacing
            let dividerFrameH = readoutDividerH
            let readoutLabelFontFinal = readoutLabelFont
            let readoutValueFontFinal = readoutValueFont
            let readoutUnitFontFinal  = readoutUnitFont
#else
            let readoutStackSpacing = readoutSpacing
            let dividerFrameH = dividerHeight
            let readoutLabelFontFinal: CGFloat = 12
            let readoutValueFontFinal: CGFloat = 48
            let readoutUnitFontFinal: CGFloat  = 14
            let readoutEdgePadding: CGFloat = max(24, min(40, geo.size.width * 0.045))
#endif

            ZStack {
                // ===== Layer 0：后景全屏图表 =====
                BackgroundVoiceChart(
                    pitchHistory: analyzer.pitchHistory,
                    f1History:    analyzer.f1History,
                    f2History:    analyzer.f2History,
                    cardFrame:    cardFrame,
                    rootSize:     geo.size,
                    showF1:       showF1,
                    showF2:       showF2,
                    f0Min:        f0Min,
                    f0Max:        f0Max,
                    fmtMin:       fmtMin,
                    fmtMax:       fmtMax
                )

                // ===== Layer 1：主区卡片底色 =====
                if cardFrame.height > 1 {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.secondary.opacity(0.06))
                        .frame(width: cardFrame.width, height: cardFrame.height)
                        .position(x: cardFrame.midX, y: cardFrame.midY)
                        .allowsHitTesting(false)
                }

                // ===== Layer 2：前景 UI =====
                VStack(spacing: 0) {
                    Spacer()

                    HStack(spacing: readoutStackSpacing) {
                        FrequencyReadout(
                            label: "F0 Fundamental",
                            value: analyzer.pitch,
                            color: .red,
                            labelSize: readoutLabelFontFinal,
                            valueSize: readoutValueFontFinal,
                            unitSize: readoutUnitFontFinal
                        )
                        .frame(maxWidth: .infinity)
                        .layoutPriority(1)

                        if showF1 {
                            Divider()
                                .frame(height: dividerFrameH)
                            FrequencyReadout(
                                label: "F1 Formant",
                                value: analyzer.f1,
                                color: .blue,
                                labelSize: readoutLabelFontFinal,
                                valueSize: readoutValueFontFinal,
                                unitSize: readoutUnitFontFinal
                            )
                            .frame(maxWidth: .infinity)
                            .layoutPriority(1)
                        }

                        if showF2 {
                            Divider()
                                .frame(height: dividerFrameH)
                            FrequencyReadout(
                                label: "F2 Formant",
                                value: analyzer.f2,
                                color: .green,
                                labelSize: readoutLabelFontFinal,
                                valueSize: readoutValueFontFinal,
                                unitSize: readoutUnitFontFinal
                            )
                            .frame(maxWidth: .infinity)
                            .layoutPriority(1)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, readoutEdgePadding)
#if os(iOS)
                    .padding(.top, 44)
#endif

                    Spacer().frame(height: spacerReadoutToChart)

                    // 主区 placeholder：上报 frame 给后景图表对齐
                    Color.clear
                        .frame(height: chartHeight)
                        .background(
                            GeometryReader { cardGeo in
                                Color.clear.preference(
                                    key: CardFrameKey.self,
                                    value: cardGeo.frame(in: .named("rootSpace"))
                                )
                            }
                        )
                        .padding(.horizontal, 24)

                    Spacer().frame(height: spacerChartToBar)

                    AmplitudeBar(amplitude: analyzer.amplitude)
                        .frame(height: 8)
                        .padding(.horizontal, 48)

                    Spacer()

                    /// 底部：全宽大条在 **右侧槽**（开始聆听）；一分为二时左=录音、右=停止聆听，
                    /// 宽度从左槽 0→半宽、右槽全宽→半宽，大条视感收到 **右侧** 与「停止聆听」对应。
                    GeometryReader { innerGeo in
                        let gap: CGFloat = isRunning ? 12 : 0
                        let totalW = innerGeo.size.width
                        let halfW = max(0, (totalW - gap) / 2)
                        let leftW = isRunning ? halfW : 0
                        let rightW = isRunning ? halfW : totalW

                        HStack(spacing: gap) {
                            Group {
                                if isRunning {
                                    Button {
                                        withAnimation(controlRoomSpring) {
                                            toggleRecordingArmed()
                                        }
                                    } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: isRecordingArmed ? "stop.circle.fill" : "record.circle")
                                                .contentTransition(.symbolEffect(.replace))
                                            Text(isRecordingArmed ? "Stop Recording" : "Record")
                                                .contentTransition(.interpolate)
                                                .lineLimit(1)
                                                .minimumScaleFactor(0.55)
                                        }
                                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 16)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(isRecordingArmed ? Color.orange : Color.accentColor)
                                    .animation(controlRoomSpring, value: isRecordingArmed)
                                } else {
                                    Color.clear
                                        .allowsHitTesting(false)
                                }
                            }
                            .frame(width: leftW)
                            .clipped()
                            .animation(controlRoomSpring, value: isRunning)

                            Button {
                                if isRunning {
                                    stopListeningSameAsStopButton()
                                } else {
                                    withAnimation(controlRoomSpring) {
                                        isRecordingArmed = false
                                        isRunning = analyzer.start()
                                    }
                                }
                            } label: {
                                Group {
                                    if isRunning {
                                        Label("Stop Listening", systemImage: "stop.circle.fill")
                                    } else {
                                        Label("Start Listening", systemImage: "mic.circle.fill")
                                    }
                                }
                                .lineLimit(1)
                                .minimumScaleFactor(0.55)
                                .frame(maxWidth: .infinity)
                                .contentTransition(.interpolate)
                                .animation(controlRoomSpring, value: isRunning)
                                .font(.system(size: 20, weight: .semibold, design: .rounded))
                                .padding(.vertical, 16)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(isRunning ? Color.red : Color.accentColor)
                            .animation(controlRoomSpring, value: isRunning)
                            .frame(width: rightW)
                            .clipped()
                            .animation(controlRoomSpring, value: isRunning)
                        }
                        .frame(width: totalW)
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: ControlStripFrameKey.self,
                                    value: proxy.frame(in: .named("rootSpace"))
                                )
                            }
                        }
                    }
                    .frame(height: 60)
                    .padding(.horizontal, 32)
                    .padding(.bottom, buttonBottomPad)
                }
            }
            .coordinateSpace(name: "rootSpace")
            .onPreferenceChange(CardFrameKey.self) { cardFrame = $0 }
            .onPreferenceChange(ControlStripFrameKey.self) { controlStripFrame = $0 }
            .onAppear { requestMicrophonePermission() }
#if os(iOS)
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .background, isRunning else { return }
                stopListeningSameAsStopButton()
            }
#endif
            .animation(.spring(response: 0.35, dampingFraction: 0.88), value: analyzer.lastSavedRecordingPath)
            .onChange(of: analyzer.lastSavedRecordingPath) { _, newPath in
                guard let path = newPath else { return }
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    await MainActor.run {
                        if analyzer.lastSavedRecordingPath == path {
                            analyzer.clearSavedRecordingToast()
                        }
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let path = analyzer.lastSavedRecordingPath, controlStripFrame.height > 0 {
                    Button {
                        analyzer.clearSavedRecordingToast()
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Saved successfully")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(path)
                                .font(.caption)
                                .monospaced()
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .lineLimit(6)
                                .minimumScaleFactor(0.75)
                                .textSelection(.enabled)
                            Text("Tap to dismiss")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .frame(width: controlStripFrame.width)
                    .padding(.bottom, geo.size.height - controlStripFrame.minY)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
#if os(iOS)
            // iOS：设置入口与录音目录选择
            .overlay(alignment: .topTrailing) {
                Button { showSettings = true } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 30, weight: .light))
                        .padding(16)
                        .foregroundStyle(Color.secondary.opacity(0.7))
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
                .padding(.trailing, 16)
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    SettingsView()
                        .navigationTitle("Settings")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showSettings = false }
                            }
                        }
                }
            }
            .sheet(isPresented: $showFolderPicker) {
                RecordingFolderPicker(
                    isPresented: $showFolderPicker,
                    onFolderPicked: handlePickedRecordingFolder,
                    onCancelled: { pendingArmRecordAfterPick = false }
                )
            }
#endif
        }
    }

    // MARK: - Helpers

    /// 与「停止聆听」按钮相同：结束录音（落盘）、停止引擎、更新 UI。
    private func stopListeningSameAsStopButton() {
        withAnimation(controlRoomSpring) {
            isRecordingArmed = false
            pendingArmRecordAfterPick = false
            analyzer.endRecording()
            analyzer.stop()
            isRunning = false
        }
    }

    private func toggleRecordingArmed() {
        guard isRunning else { return }
        if isRecordingArmed {
            isRecordingArmed = false
            analyzer.endRecording()
            return
        }
        if !folderStore.hasBookmark {
            pendingArmRecordAfterPick = true
#if os(macOS)
            presentMacRecordingFolderPicker()
#else
            showFolderPicker = true
#endif
            return
        }
        startRecordingToUserFolderOrReauth()
    }

    private func startRecordingToUserFolderOrReauth() {
        do {
            try analyzer.beginRecordingToUserFolder(store: folderStore)
            isRecordingArmed = true
        } catch {
            if let folderErr = error as? RecordingFolderError {
                if case .staleBookmark = folderErr {
                    folderStore.clearBookmark()
                }
            }
            pendingArmRecordAfterPick = true
#if os(macOS)
            presentMacRecordingFolderPicker()
#else
            showFolderPicker = true
#endif
        }
    }

    private func handlePickedRecordingFolder(_ url: URL) {
        do {
            try folderStore.saveBookmark(for: url)
            if pendingArmRecordAfterPick {
                pendingArmRecordAfterPick = false
                if isRunning {
                    do {
                        try analyzer.beginRecordingToUserFolder(store: folderStore)
                        isRecordingArmed = true
                    } catch {
                        pendingArmRecordAfterPick = true
#if os(macOS)
                        presentMacRecordingFolderPicker()
#else
                        showFolderPicker = true
#endif
                    }
                }
            }
        } catch {
            pendingArmRecordAfterPick = false
        }
    }

#if os(macOS)
    private func presentMacRecordingFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder for FormantScope recordings"
        guard panel.runModal() == .OK, let url = panel.url else {
            pendingArmRecordAfterPick = false
            return
        }
        handlePickedRecordingFolder(url)
    }
#endif

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

/// 底部控制条（录制 + 停止聆听）在 rootSpace 中的外接矩形，用于保存成功浮窗贴齐按钮上沿与左右边。
private struct ControlStripFrameKey: PreferenceKey {
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
    var labelSize: CGFloat = 12
    var valueSize: CGFloat = 48
    var unitSize:  CGFloat = 14

    private var displayText: String {
        value > 0 ? String(format: "%.0f", value) : "---"
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: labelSize, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .multilineTextAlignment(.center)

            Text(displayText)
                .font(.system(size: valueSize, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.28)
                .lineLimit(1)
                .multilineTextAlignment(.center)
                .foregroundStyle(value > 0 ? color : color.opacity(0.5))
                .contentTransition(.numericText())
                .animation(.spring(duration: 0.2), value: value)

            Text("Hz")
                .font(.system(size: unitSize, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .textSelection(.enabled)
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
                // 背景轨道：使用 material 而非半透明纯色，确保能遮住底层溢出的图表线
                Capsule()
                    .fill(.ultraThinMaterial)

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
    let f1History:    [Float?]
    let f2History:    [Float?]
    /// 主区卡片在 "rootSpace" 坐标系的 frame；高度 0 表示尚未完成首次布局
    let cardFrame: CGRect
    /// ZStack 根容器尺寸，用来计算 Y 域上下沿对应屏幕顶/底的归一化值
    let rootSize:  CGSize
    /// 控制 F1/F2 折线与右轴的可见性
    let showF1:  Bool
    let showF2:  Bool
    /// 用户可配置的轴范围（Hz）
    let f0Min:   Double
    let f0Max:   Double
    let fmtMin:  Double
    let fmtMax:  Double

    // MARK: - 归一化（实例方法，使用传入的轴范围）

    private func normF0(_ hz: Double)  -> Double { (hz - f0Min)  / (f0Max  - f0Min)  }
    private func normFmt(_ hz: Double) -> Double { (hz - fmtMin) / (fmtMax - fmtMin) }

    // MARK: - 刻度候选集（Hz + 显示文本）

    private struct AxisTick {
        let norm:  Double
        let label: String
    }

    /// 从候选 Hz 列表中过滤出落在 (min, max) 内的刻度，并映射到归一化坐标。
    private static func makeTicks(_ candidates: [(Double, String)],
                                   min: Double, max: Double,
                                   norm: (Double) -> Double) -> [AxisTick] {
        candidates
            .filter { $0.0 > min && $0.0 < max }
            .map    { AxisTick(norm: norm($0.0), label: $0.1) }
    }

    private var f0Ticks: [AxisTick] {
        Self.makeTicks(
            [(50,"50"),(100,"100"),(150,"150"),(200,"200"),(250,"250"),
             (300,"300"),(350,"350"),(400,"400"),(450,"450"),(500,"500"),(550,"550")],
            min: f0Min, max: f0Max, norm: normF0)
    }

    private var fmtTicks: [AxisTick] {
        Self.makeTicks(
            [(300,"300"),(500,"500"),(700,"700"),(1_000,"1k"),
             (1_500,"1.5k"),(2_000,"2k"),(2_500,"2.5k"),(3_000,"3k"),(3_500,"3.5k")],
            min: fmtMin, max: fmtMax, norm: normFmt)
    }

    // MARK: - 数据点构造

    private struct DataPoint: Identifiable {
        let id: Int
        let index: Int
        let norm: Double
        let segment: Int
    }

    /// 构造数据点：保持原有的 nil 分段逻辑，但不再把 norm clamp 到 [0,1]，
    /// 而是 clamp 到当前扩展 Y 域，让超量程值仍可见且不会被裁出图表 frame。
    private func makePoints(_ history: [Float?],
                            norm: (Double) -> Double,
                            yMin: Double,
                            yMax: Double) -> [DataPoint] {
        var result: [DataPoint] = []
        var segmentID = 0
        var prevWasNil = true
        for (index, value) in history.enumerated() {
            guard let f = value else { prevWasNil = true; continue }
            if prevWasNil { segmentID += 1 }
            let n = max(yMin, min(yMax, norm(Double(f))))
            result.append(DataPoint(id: index, index: index, norm: n, segment: segmentID))
            prevWasNil = false
        }
        return result
    }

    // MARK: - Body

    var body: some View {
        chartView
    }

    /// Y 域映射：
    ///   plot Y = 1 ↔ 屏幕 y = cardFrame.minY（主区顶）
    ///   plot Y = 0 ↔ 屏幕 y = cardFrame.maxY（主区底）
    /// 当 cardFrame 尚未就绪时退回 [0,1]。
    private var yDomain: (min: Double, max: Double) {
        guard cardFrame.height > 1, rootSize.height > 1 else { return (0, 1) }
        let yMax = Double(cardFrame.maxY) / Double(cardFrame.height)
        let yMin = Double(cardFrame.maxY - rootSize.height) / Double(cardFrame.height)
        return (yMin, yMax)
    }

    @ViewBuilder
    private var chartView: some View {
        let (yMin, yMax) = (yDomain.min, yDomain.max)

        let f0Pts  = makePoints(pitchHistory, norm: normF0,  yMin: yMin, yMax: yMax)
        let f1Pts  = makePoints(f1History,    norm: normFmt, yMin: yMin, yMax: yMax)
        let f2Pts  = makePoints(f2History,    norm: normFmt, yMin: yMin, yMax: yMax)

        // 刻度 norm 数组供 AxisMarks(values:) 使用
        let f0Norms  = f0Ticks.map(\.norm)
        let fmtNorms = fmtTicks.map(\.norm)

        Chart {
            // F0 — 红色实线（始终显示）
            ForEach(f0Pts) { p in
                LineMark(x: .value("Frame", p.index),
                         y: .value("n", p.norm),
                         series: .value("s", "f0-\(p.segment)"))
                .interpolationMethod(.monotone)
                .foregroundStyle(.red)
                .lineStyle(StrokeStyle(lineWidth: 2))
            }

            // F1 — 蓝色虚线（可隐藏）
            if showF1 {
                ForEach(f1Pts) { p in
                    LineMark(x: .value("Frame", p.index),
                             y: .value("n", p.norm),
                             series: .value("s", "f1-\(p.segment)"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [6, 4]))
                }
            }

            // F2 — 绿色虚线（可隐藏）
            if showF2 {
                ForEach(f2Pts) { p in
                    LineMark(x: .value("Frame", p.index),
                             y: .value("n", p.norm),
                             series: .value("s", "f2-\(p.segment)"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.green)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [6, 4]))
                }
            }
        }
        .chartXScale(domain: 0 ... 99)
        .chartYScale(domain: yMin ... yMax)
        .chartXAxis(.hidden)
        .chartYAxis {
            // 左轴：F0 刻度（红色）+ 网格线
            AxisMarks(position: .leading, values: f0Norms) { val in
                AxisValueLabel {
                    if let v = val.as(Double.self),
                       let tick = f0Ticks.first(where: { abs($0.norm - v) < 1e-6 }) {
                        Text(tick.label)
                            .font(.system(size: 9))
                            .foregroundStyle(.red.opacity(0.8))
                    }
                }
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))
                    .foregroundStyle(Color.secondary.opacity(0.15))
            }

            // 右轴：Formant 刻度（F1/F2 共轴）—— F1 或 F2 至少一个可见时才显示
            if showF1 || showF2 {
                AxisMarks(position: .trailing, values: fmtNorms) { val in
                    AxisValueLabel {
                        if let v = val.as(Double.self),
                           let tick = fmtTicks.first(where: { abs($0.norm - v) < 1e-6 }) {
                            Text(tick.label)
                                .font(.system(size: 9))
                                .foregroundStyle(Color.secondary.opacity(0.6))
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .allowsHitTesting(false)
    }
}


#Preview {
    ContentView()
}
