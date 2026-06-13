//
//  ContentView.swift
//  FormantScope
//
//  Created by Hanyu on 2026/4/25.
//

import SwiftUI
import AVFoundation
import Charts
#if os(iOS)
import UIKit
#endif
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
    /// 图表显示的时间窗（秒）。规范化跨设备跨度：图表按真实时间轴渲染最近这么多秒，
    /// 不再依赖随采样率漂移的帧索引。同时也是 F0/F1/F2 读数下方"窗内平均"的统计范围。
    @AppStorage("timeWindowSec") private var timeWindowSec: Double = 8

#if os(iOS)
    @State private var showSettings = false
#endif

    /// 读数下方"窗内平均"的快照，每秒刷新一次（见 avgTick）。仪表盘大数字 F0/F1/F2
    /// 本就带平滑动画，若 avg 也跟着每帧高频跳动会显得很花；这里降频到 1 Hz 且无动画
    /// 直接切值，让小字 avg 安静、只有大数字有动效。
    @State private var avgF0: Float? = nil
    @State private var avgF1: Float? = nil
    @State private var avgF2: Float? = nil
    private let avgTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

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
#if os(iOS)
            /// iPad：抬高图表主区高度；`cardFrame` 变大后 `BackgroundVoiceChart.yDomain` 自动重算，曲线覆盖区域同步。
            let isPad = UIDevice.current.userInterfaceIdiom == .pad
            let chartHScale: CGFloat = max(0.5, min(isPad ? 1.95 : 1.4, geo.size.height / 640))
            let chartHeightBase: CGFloat = isPad ? 400 : 320
            let chartHeight: CGFloat = max(isPad ? 160 : 120, chartHeightBase * chartHScale)
#else
            let chartHeight: CGFloat = max(120, 320 * hScale)
#endif
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
            /// 读数区与屏幕左右边距，避免内容贴屏幕边缘。
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
                    fmtMax:       fmtMax,
                    windowSeconds: timeWindowSec
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
                            average: avgF0,
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
                                average: avgF1,
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
                                average: avgF2,
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
            .onReceive(avgTick) { _ in
                // 每秒刷新窗内平均快照（无动画，直接切值）。
                avgF0 = windowAverage(analyzer.pitchHistory)
                avgF1 = windowAverage(analyzer.f1History)
                avgF2 = windowAverage(analyzer.f2History)
            }
            .onChange(of: analyzer.autoStopSignal) { _, _ in
                // 输入源/音频路由变化导致引擎被系统停止：analyzer 已自行 stop()。
                // 这里只需把界面复位到初始态（按钮回 Start、解除录音武装），
                // 曲线因不再有新样本且历史未清空而自然冻结，与手动「停止聆听」一致。
                guard isRunning else { return }
                withAnimation(controlRoomSpring) {
                    isRecordingArmed = false
                    pendingArmRecordAfterPick = false
                    isRunning = false
                }
            }
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

    /// 计算某条带时间戳历史在当前时间窗内的平均值（仅统计有声、非 nil 的样本）。
    /// 窗口右端取该路最后一个样本的时间戳（与图表 referenceNow 一致），无有声样本时返回 nil。
    private func windowAverage(_ history: [AudioAnalyzer.TimedSample]) -> Float? {
        guard let last = history.last?.t else { return nil }
        let cutoff = last - timeWindowSec
        var sum: Float = 0
        var count = 0
        for s in history where s.t >= cutoff {
            if let v = s.value { sum += v; count += 1 }
        }
        return count > 0 ? sum / Float(count) : nil
    }

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
        } catch let folderErr as RecordingFolderError {
            // 仅「目录类」错误才值得重新弹出选择器：书签失效/无目录/访问被拒。
            if case .staleBookmark = folderErr {
                folderStore.clearBookmark()
            }
            pendingArmRecordAfterPick = true
#if os(macOS)
            presentMacRecordingFolderPicker()
#else
            showFolderPicker = true
#endif
        } catch {
            // 引擎未启动 / 音频图未就绪 / 输出格式无效（RecordingError）等：
            // 重选目录无济于事，重弹选择器会形成死循环（macOS runModal 递归）。
            // 直接停止本次重试，保留已存书签。
            pendingArmRecordAfterPick = false
            isRecordingArmed = false
        }
    }

    private func handlePickedRecordingFolder(_ url: URL) {
        do {
            try folderStore.saveBookmark(for: url)
            if pendingArmRecordAfterPick {
                pendingArmRecordAfterPick = false
                if isRunning {
                    // 目录刚选好且已写入书签；若此处仍失败，几乎必为非目录错误
                    // （引擎/格式），不再重弹选择器，避免死循环。
                    do {
                        try analyzer.beginRecordingToUserFolder(store: folderStore)
                        isRecordingArmed = true
                    } catch {
                        isRecordingArmed = false
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
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose a folder for FormantScope recordings")
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
    /// 时间窗内平均值（Hz）；nil 表示窗内无有声样本，此时不显示平均行。
    var average: Float? = nil
    let color: Color
    var labelSize: CGFloat = 12
    var valueSize: CGFloat = 48
    var unitSize:  CGFloat = 14

    private var displayText: String {
        value > 0 ? String(format: "%.0f", value) : "---"
    }

    private var averageText: String? {
        guard let average, average > 0 else { return nil }
        return String(format: "avg %.0f", average)
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

            // 窗内平均（小字副行，正下方居中）。窗内无有声样本时整行隐藏，
            // 避免静音时一排 "avg ---"。色彩用系统次级灰，弱化为辅助信息。
            // 值每秒刷新一次且无动画直接切换：仪表盘大数字本就有平滑动画，小字 avg
            // 再跟着跳会显得很花，故只保留大数字动效。
            Text(averageText ?? " ")
                .font(.system(size: unitSize, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .opacity(averageText == nil ? 0 : 1)
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

    let pitchHistory: [AudioAnalyzer.TimedSample]
    let f1History:    [AudioAnalyzer.TimedSample]
    let f2History:    [AudioAnalyzer.TimedSample]
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
    /// 显示的时间窗（秒）：X 轴域为 -windowSeconds ... 0，0 = 最新样本时刻。
    let windowSeconds: Double

    // MARK: - 归一化（实例方法，使用传入的轴范围）

    private func normF0(_ hz: Double)  -> Double { (hz - f0Min)  / (f0Max  - f0Min)  }
    private func normFmt(_ hz: Double) -> Double { (hz - fmtMin) / (fmtMax - fmtMin) }

    // MARK: - 刻度生成（"nice numbers" 算法）
    //
    // 用通用 1‑2‑5×10ⁿ 取整算法：给定任意 (min, max) 产出等间距的整刻度，并强制
    // 带上区间两端，跨设备/任意自定义轴范围都能给出"整齐、含端点"的专业刻度。

    private struct AxisTick {
        let norm:  Double
        let label: String
    }

    /// 1‑2‑5×10ⁿ 步长：把"理想步长"(range/target)向上取到最近的 1/2/5 量级整数。
    private static func niceStep(range: Double, target: Int) -> Double {
        guard range > 0, target > 0 else { return 0 }
        let raw = range / Double(target)
        let mag = pow(10, floor(log10(raw)))
        let norm = raw / mag                       // 落在 [1, 10)
        let niceNorm: Double
        switch norm {
        case ..<1.5: niceNorm = 1
        case ..<3:   niceNorm = 2
        case ..<7:   niceNorm = 5
        default:     niceNorm = 10
        }
        return niceNorm * mag
    }

    /// 区间 [lo, hi] 内、step 的整数倍刻度（含落在端点上的）。
    private static func niceTicks(min lo: Double, max hi: Double, target: Int) -> [Double] {
        let step = niceStep(range: hi - lo, target: target)
        guard step > 0 else { return [] }
        let eps = step * 1e-6
        var ticks: [Double] = []
        var v = (lo / step).rounded(.up) * step
        while v <= hi + eps {
            if v >= lo - eps { ticks.append(v) }
            v += step
        }
        return ticks
    }

    /// 频率轴刻度：nice 刻度 + 强制带上两端点。若端点离最近的 nice 刻度太近
    /// （< 0.35 step）则替换掉它，避免标签贴在一起。
    private static func freqAxisTicks(min lo: Double, max hi: Double, target: Int = 6) -> [Double] {
        var ts = niceTicks(min: lo, max: hi, target: target)
        let step = ts.count >= 2 ? ts[1] - ts[0] : (hi - lo)
        func forceEndpoint(_ e: Double) {
            if let nearest = ts.min(by: { abs($0 - e) < abs($1 - e) }),
               abs(nearest - e) < step * 0.35 {
                ts.removeAll { $0 == nearest }
            }
            ts.append(e)
        }
        forceEndpoint(lo)
        forceEndpoint(hi)
        return Array(Set(ts)).sorted()
    }

    /// Hz → 紧凑标签："1k" / "1.5k" / "350"。
    private static func freqLabel(_ hz: Double) -> String {
        if hz >= 1_000 {
            let k = hz / 1_000
            return k == k.rounded() ? "\(Int(k))k" : String(format: "%.1fk", k)
        }
        return "\(Int(hz.rounded()))"
    }

    private var f0Ticks: [AxisTick] {
        Self.freqAxisTicks(min: f0Min, max: f0Max)
            .map { AxisTick(norm: normF0($0), label: Self.freqLabel($0)) }
    }

    private var fmtTicks: [AxisTick] {
        Self.freqAxisTicks(min: fmtMin, max: fmtMax)
            .map { AxisTick(norm: normFmt($0), label: Self.freqLabel($0)) }
    }

    // MARK: - 时间轴刻度

    /// X 轴时间刻度（秒，负值=过去，0=最新）。直接用 nice 刻度即可，
    /// 常见窗口（8/20 s）会自然带上左端点与 0。
    private var timeTicks: [Double] {
        Self.niceTicks(min: -windowSeconds, max: 0, target: 5)
    }

    /// 时间标签："now" / "-2s" / "-1.5s"。
    private func timeLabel(_ x: Double) -> String {
        if abs(x) < 1e-6 { return "now" }
        return x == x.rounded() ? "\(Int(x))s" : String(format: "%.1fs", x)
    }

    // MARK: - 数据点构造

    private struct DataPoint: Identifiable {
        let id: Int
        /// 相对最新样本时刻的秒偏移（0 = 最新，负值向左）。
        let x: Double
        let norm: Double
        let segment: Int
    }

    /// 构造数据点：nil 样本切断折线（分段），X = 相对 referenceNow 的秒偏移（时间轴），
    /// Y clamp 到当前扩展 Y 域，让超量程值可见且不被裁出 frame。
    /// X 早于左端点（-windowSeconds）的样本直接丢弃：history 保留 30s，但窗外的旧点
    /// 会被 Charts 裁到 plot 左缘，若那段恰好竖直溢出就会糊成贴屏左缘的竖线，造成
    /// 左右不对称。丢弃后曲线在左端点干净截止，溢出只剩上下两侧。
    private func makePoints(_ history: [AudioAnalyzer.TimedSample],
                            referenceNow: Double,
                            norm: (Double) -> Double,
                            yMin: Double,
                            yMax: Double) -> [DataPoint] {
        var result: [DataPoint] = []
        var segmentID = 0
        var prevWasNil = true
        for (index, sample) in history.enumerated() {
            guard let f = sample.value else { prevWasNil = true; continue }
            let x = sample.t - referenceNow
            if x < -windowSeconds { prevWasNil = true; continue }
            if prevWasNil { segmentID += 1 }
            let n = max(yMin, min(yMax, norm(Double(f))))
            result.append(DataPoint(id: index, x: x, norm: n, segment: segmentID))
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

        // referenceNow = 三路历史最后时间戳的最大值（最新样本时刻），作为 X 轴 0 点。
        // 空历史时取 0，X 域 -windowSeconds...0 恒有效、不画任何线。
        let referenceNow = max(pitchHistory.last?.t ?? 0,
                               f1History.last?.t ?? 0,
                               f2History.last?.t ?? 0)

        let f0Pts  = makePoints(pitchHistory, referenceNow: referenceNow, norm: normF0,  yMin: yMin, yMax: yMax)
        let f1Pts  = makePoints(f1History,    referenceNow: referenceNow, norm: normFmt, yMin: yMin, yMax: yMax)
        let f2Pts  = makePoints(f2History,    referenceNow: referenceNow, norm: normFmt, yMin: yMin, yMax: yMax)

        // 刻度 norm 数组供 AxisMarks(values:) 使用
        let f0Norms  = f0Ticks.map(\.norm)
        let fmtNorms = fmtTicks.map(\.norm)

        Chart {
            // F0 — 红色实线（始终显示）
            ForEach(f0Pts) { p in
                LineMark(x: .value("t", p.x),
                         y: .value("n", p.norm),
                         series: .value("s", "f0-\(p.segment)"))
                .interpolationMethod(.monotone)
                .foregroundStyle(.red)
                .lineStyle(StrokeStyle(lineWidth: 2))
            }

            // F1 — 蓝色虚线（可隐藏）
            if showF1 {
                ForEach(f1Pts) { p in
                    LineMark(x: .value("t", p.x),
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
                    LineMark(x: .value("t", p.x),
                             y: .value("n", p.norm),
                             series: .value("s", "f2-\(p.segment)"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.green)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [6, 4]))
                }
            }
        }
        .chartXScale(domain: -windowSeconds ... 0)
        .chartYScale(domain: yMin ... yMax)
        .chartXAxis {
            // 时间轴只画竖向网格线（不画 AxisValueLabel）：标签会让 Charts 在底部
            // 预留 gutter、压缩 plot 高度，从而破坏"plot 满屏、[0,1] 精准对齐主卡片"
            // 的 Y 域映射。竖线在 plot 内部绘制、不占 gutter，安全。标签改由下方
            // chartOverlay 用 proxy 定位到主卡片底沿。
            AxisMarks(values: timeTicks) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))
                    .foregroundStyle(Color.secondary.opacity(0.12))
            }
        }
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
        .chartOverlay { proxy in
            // 时间标签贴主卡片底沿绘制。按 Y 域设计 plot Y=0 ↔ 主卡片底，故用
            // proxy.position(forY: 0) 取该屏幕 y，再把标签上移一点放进卡片内沿，
            // 避开屏幕最底部的能量条/按钮。cardFrame 未就绪（高度≈0，退回 Y 域 0…1）
            // 时不画，避免标签糊在屏幕边缘。
            if cardFrame.height > 1, let baseY = proxy.position(forY: 0) {
                ForEach(timeTicks, id: \.self) { t in
                    if let px = proxy.position(forX: t) {
                        Text(timeLabel(t))
                            .font(.system(size: 9))
                            .foregroundStyle(Color.secondary.opacity(0.55))
                            .fixedSize()
                            .position(x: px, y: baseY - 9)
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
