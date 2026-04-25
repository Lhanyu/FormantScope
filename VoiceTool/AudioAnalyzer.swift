// AudioAnalyzer.swift
// VoiceTool
//
// 引擎层：PitchTap 提取 F0（基频）；RawDataTap + LPC 提取 F2（第二共振峰）。

import AudioKit
import AudioKitEX
import SoundpipeAudioKit
import AVFoundation
import Accelerate

final class AudioAnalyzer: ObservableObject {

    // MARK: - Published state

    /// 当前检测到的基频（Hz）。0 表示无有效信号。
    @Published var pitch: Float = 0.0

    /// 当前信号幅度，可用于判断是否有有效输入。
    @Published var amplitude: Float = 0.0

    /// 最近 100 帧的音高历史。nil 表示静音帧，Charts 遇到 nil 会自动断开线条。
    @Published var pitchHistory: [Float?] = Array(repeating: nil, count: 100)

    /// 当前检测到的第二共振峰（Hz）。0 表示无有效信号。
    @Published var f2: Float = 0.0

    /// 最近 100 帧的 F2 历史。nil 表示静音帧或 LPC 未找到有效 F2。
    @Published var f2History: [Float?] = Array(repeating: nil, count: 100)

    // MARK: - Noise gate

    /// 振幅低于此阈值时视为静音（PitchTap / AUBIO 归一化幅度）。
    static let amplitudeThreshold: Float = 0.15
    static let minPitch: Float = 50.0
    static let maxPitch: Float = 1_200.0
    /// 从静音进入有声态所需的连续帧数（onset）。
    /// 2 帧 ≈ 180 ms，比原来 3 帧（270 ms）更快响应，减少元音起始的 F0 延迟。
    static let requiredConsecutiveFrames: Int = 2
    /// F0 显示保持帧数（offset hysteresis）：确认的 F0 消失后，再保持这么多帧再断线。
    /// ~450 ms 足以跨越大多数清辅音（/p/ /t/ /k/ 闭塞段约 50–150 ms）。
    private static let maxPitchHoldFrames: Int = 5

    // MARK: - LPC parameters

    /// 降采样因子：44100 → 11025 Hz（÷4）。
    /// Praat 的做法：分析前先将信号降采到 "max_formant × 2" Hz，
    /// 44100 Hz 全频段若直接用 LPC，需 ~46 阶才够（Fs/1000+2）；
    /// 降到 11025 Hz 后，12 阶即可覆盖 5 个共振峰（1 pair/kHz × 5.5 kHz + 余量）。
    private static let downsampleFactor: Int = 4   // 44100 ÷ 4 = 11025 Hz

    /// LPC 阶数：在降采到 11025 Hz 的信号上运行。
    /// 12 阶 → 6 对极点，标准公式 Fs/1000+2 = 11025/1000+2 ≈ 13，取 12 略保守。
    private static let lpcOrder = 12

    /// LPC 谱包络评估点数（单侧频率轴）。
    /// 分辨率 11025 / 2 / 512 ≈ 10.8 Hz/bin，足以精确定位 F1/F2。
    private static let spectrumPoints = 512

    /// 原始 PCM RMS 门限，独立于 AUBIO 归一化幅度，用于过滤真正的静音帧。
    private static let rmsThreshold: Float = 0.005

    /// 共振峰搜索范围：包含 F1（200 Hz 起）以确保 F2 能正确排在第二位。
    private static let formantSearchMin: Float = 200
    private static let formantSearchMax: Float = 3_500

    /// F2 有效性范围静态下限。F1-aware 动态下限 = max(f2ValidMin, F1+f2AboveF1Margin)，
    /// 防止低 F1 被误认为 F2（如 /a/ 的 F1≈750 Hz）。
    private static let f2ValidMin:        Float = 600     // 覆盖 /o/、/u/ 的低 F2（~700 Hz）
    private static let f2ValidMax:        Float = 3_500
    private static let f2AboveF1Margin:   Float = 150     // F2 至少高于 F1 这么多 Hz
    private static let f1SearchMax:       Float = 1_000   // F1 通常不超过 1 kHz

    // MARK: - Private audio graph

    private let engine = AudioEngine()
    private var pitchTap: PitchTap?
    private var rawDataTap: RawDataTap?

    /// LPC 计算专用后台队列，避免阻塞主线程。
    private let lpcQueue = DispatchQueue(label: "com.voicetool.lpc", qos: .userInteractive)

    private var consecutiveVoiceFrames: Int = 0
    /// F0 显示保持：上次确认的音高值，onset 结束后继续展示 maxPitchHoldFrames 帧。
    private var lastConfirmedPitch: Float = 0
    private var pitchHoldCount: Int = 0

    /// 静音 Fader：AudioEngine 必须设置 output 才能让 tap 正常触发。
    private var silence: Fader?

    /// 用于读取真实硬件采样率（引擎启动后才有效）。
    private var tapMixer: Mixer?

    /// Debug 帧计数，每 30 帧打印一次 LPC 诊断日志。
    private var lpcDebugCount = 0

    /// PitchTap 最新的确认音高快照，供 lpcQueue 判断当前是否有声。
    /// 写入：main（PitchTap 回调）；读取：lpcQueue（processLPC）。
    /// Float 读写在 x86/ARM 上天然原子，此处轻微数据竞争对展示无影响。
    private var currentPitchSnapshot: Float = 0

    /// PitchTap 最新的原始幅度快照（未经防抖），用于低 F0 场景下的备用声态门控。
    /// 当 F0 低（~100 Hz）时，3 帧防抖会频繁将 pitch 清零，但 amplitude 更稳定。
    private var amplitudeSnapshot: Float = 0

    /// LPC 流水线上次找到的有效 F2（Hz），仅在 lpcQueue 上访问。
    private var lastValidF2: Float = 0

    /// 当 LPC 未检到有效 F2 时，最多连续保持多少帧旧 F2 值。
    /// 8 帧 ≈ 720 ms，足以跨越辅音段（50–200 ms）而不断线。
    private static let maxF2HoldFrames = 8

    /// 相邻帧 F2 最大允许跳变量（Hz/帧）。超过此值视为高阶共振峰串扰，拒绝接受。
    /// /a/→/i/ F2 跨度约 1200 Hz，过渡期间每帧约 300–400 Hz；800 Hz 留足余量同时过滤 F3 串扰。
    private static let maxF2DeltaPerFrame: Float = 800
    private var f2HoldCount: Int = 0

    // MARK: - Init

    init() {
        buildGraph()
    }

    // MARK: - Graph construction

    private func buildGraph() {
        guard let mic = engine.input else {
            print("[AudioAnalyzer] 麦克风输入不可用")
            return
        }

        // AVAudioNode 一次只允许一个 installTap。
        // 用 Mixer 把信号分叉：PitchTap 挂在 mic（avAudioNode A），
        // RawDataTap 挂在 mixer（avAudioNode B），两者互不冲突。
        let mixer      = Mixer(mic)
        tapMixer       = mixer          // 保存引用，供 findFormants 读取真实采样率
        let silenceNode = Fader(mixer, gain: 0)
        silence = silenceNode
        engine.output = silenceNode

        // PitchTap：提取 F0 和幅度（AudioKitEX 内部使用 AUBIO，已自动派发到 main）
        pitchTap = PitchTap(mic) { [weak self] pitches, amps in
            guard let self else { return }
            let currentPitch = pitches[0]
            let currentAmp   = amps[0]

            let isVoice = currentAmp   >= Self.amplitudeThreshold
                       && currentPitch >= Self.minPitch
                       && currentPitch <= Self.maxPitch

            if isVoice {
                self.consecutiveVoiceFrames += 1
                self.pitchHoldCount = 0
            } else {
                self.consecutiveVoiceFrames = 0
            }

            // onset：连续 requiredConsecutiveFrames 帧有声 → 进入确认态
            let confirmed = isVoice && self.consecutiveVoiceFrames >= Self.requiredConsecutiveFrames

            // offset hysteresis：确认断声后，再保持 maxPitchHoldFrames 帧旧值再断线
            // 目的：跨越辅音（/p/ /t/ /k/ 等）时 F0 曲线不出现短暂缺口。
            let displayPitch: Float?
            if confirmed {
                self.lastConfirmedPitch = currentPitch
                displayPitch = currentPitch
            } else if self.lastConfirmedPitch > 0,
                      self.pitchHoldCount < Self.maxPitchHoldFrames {
                self.pitchHoldCount += 1
                displayPitch = self.lastConfirmedPitch  // 保持上一帧值
            } else {
                self.lastConfirmedPitch = 0
                displayPitch = nil
            }

            self.pitch                = displayPitch ?? 0
            // currentPitchSnapshot 只在"真正确认"时更新，F2 接受新值需要此快照 > 0。
            // hold 期间保持上一次确认值，让 isVoiced 门控仍然有效。
            if confirmed { self.currentPitchSnapshot = currentPitch }
            else if displayPitch == nil { self.currentPitchSnapshot = 0 }
            // displayPitch != nil 但 !confirmed（hold 中）：currentPitchSnapshot 保持不变

            self.amplitudeSnapshot    = currentAmp
            self.amplitude            = currentAmp
            self.pitchHistory.removeFirst()
            self.pitchHistory.append(displayPitch)
        }

        // RawDataTap 挂在 mixer 而非 mic，避免与 PitchTap 争用同一 AVAudioNode 的 installTap。
        // bufferSize 4096 与 PitchTap 内部缓冲大小一致，使两条历史曲线帧率相近（约 10 fps）。
        rawDataTap = RawDataTap(mixer, bufferSize: 4_096, callbackQueue: lpcQueue) { [weak self] samples in
            self?.processLPC(samples)
        }
    }

    // MARK: - Lifecycle

    func start() {
#if os(iOS)
        configureAudioSession()
#endif
        do {
            try engine.start()
            pitchTap?.start()
            rawDataTap?.start()
        } catch {
            print("[AudioAnalyzer] 引擎启动失败：\(error)")
        }
    }

    func stop() {
        pitchTap?.stop()
        rawDataTap?.stop()
        engine.stop()
#if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false)
#endif
    }

    // MARK: - LPC pipeline

    /// 完整 LPC F2 提取流水线，在 lpcQueue 上执行，结果派发到主线程。
    ///
    /// 流程：RMS 门控 → 预加重 → Hamming 窗 → 自相关 → Levinson-Durbin → 谱包络 → 峰值拾取
    private func processLPC(_ samples: [Float]) {
        lpcDebugCount += 1
        let shouldPrint = (lpcDebugCount % 30 == 1)   // 每 ~3 秒打印一次，不刷屏

        // RMS 门控：过滤静音，避免对噪声帧运行 LPC
        var meanSquare: Float = 0
        vDSP_measqv(samples, 1, &meanSquare, vDSP_Length(samples.count))
        let rms = sqrt(meanSquare)

        if shouldPrint {
            print("[LPC] frame=\(lpcDebugCount) sampleCount=\(samples.count) rms=\(String(format:"%.5f", rms)) threshold=\(Self.rmsThreshold)")
        }

        guard rms >= Self.rmsThreshold else {
            publishF2(nil)
            return
        }

        // 获取真实硬件采样率（引擎启动后才有效）
        let rawSampleRate: Float
        if let sr = tapMixer?.avAudioNode.outputFormat(forBus: 0).sampleRate, sr > 0 {
            rawSampleRate = Float(sr)
        } else {
            rawSampleRate = Float(Settings.sampleRate)
        }
        let effectiveSR = rawSampleRate / Float(Self.downsampleFactor)

        let emphasized   = preEmphasis(samples)
        let windowed     = applyHamming(emphasized)
        // 降采样至 ~11025 Hz 再做 LPC：
        // 44100 Hz 全频段需 ~46 阶才能准确定位共振峰；降采后 12 阶即够。
        let downsampled  = downsample(windowed, factor: Self.downsampleFactor)
        let r            = autocorrelation(downsampled, order: Self.lpcOrder)

        // r[0] 为零表示帧全静音（不应发生，但防御性处理）
        guard r[0] > 1e-10 else {
            publishF2(nil)
            return
        }

        let a        = levinsonDurbin(r, order: Self.lpcOrder)
        let spectrum = lpcSpectrum(a, nPoints: Self.spectrumPoints)
        let formants = findFormants(spectrum, sampleRate: effectiveSR)

        if shouldPrint {
            print("[LPC] formants=\(formants.map { String(format:"%.0f", $0) }) Hz")
        }

        // ── F1-aware F2 选取 ──────────────────────────────────────────────────
        // 1. 先找 F1（≤ f1SearchMax 的第一个峰），formants 已按频率升序排列。
        // 2. F2 下限 = max(f2ValidMin, F1+f2AboveF1Margin)，避免将低 F1 误判为 F2。
        //    /o/: F1≈500 → floor=max(600,650)=650   /a/: F1≈750 → floor=max(600,900)=900
        //    /i/: F1≈300 → floor=max(600,450)=600   /u/: F1≈350 → floor=max(600,500)=600
        let detectedF1 = formants.first { $0 <= Self.f1SearchMax }
        let f2Floor = detectedF1.map { max(Self.f2ValidMin, $0 + Self.f2AboveF1Margin) }
                      ?? Self.f2ValidMin
        let detectedF2 = formants.first { $0 >= f2Floor && $0 <= Self.f2ValidMax }

        // 声态门控 + 速度门限（三路逻辑，串行判断）
        // isVoiced 宽松版：pitch 已确认（含 3 帧防抖） OR 原始幅度已超阈值（无防抖）。
        // 后者专为低 F0（~100 Hz）设计：防抖使 pitch 频繁归零，但 amplitude 保持稳定。
        let isVoiced = currentPitchSnapshot > 0
                    || amplitudeSnapshot >= Self.amplitudeThreshold

        var publishValue: Float? = nil

        // ① F0 在 + LPC 找到 F2 + 帧间跳变 ≤ maxF2DeltaPerFrame → 接受新值
        //    跳变超限：视为高阶共振峰串扰，不更新 lastValidF2，落入 ② hold
        if isVoiced, let f2 = detectedF2 {
            let delta = lastValidF2 > 0 ? abs(f2 - lastValidF2) : 0
            if delta <= Self.maxF2DeltaPerFrame {
                lastValidF2 = f2
                f2HoldCount = 0
                publishValue = f2
            }
            // 跳变超限时 publishValue 仍为 nil，落入下面的 hold 分支
        }

        // ② 本帧无有效 F2（漏检、跳变超限、或辅音段）→ 在 isVoiced 期间短暂保持旧值。
        //    isVoiced 由 currentPitchSnapshot 驱动：
        //      · F0 确认中：currentPitchSnapshot = confirmed pitch > 0 → isVoiced=true → 保持 ✓
        //      · F0 hold 中：currentPitchSnapshot 保留上次确认值 > 0    → isVoiced=true → 保持 ✓
        //      · F0 完全清零（长静音）：currentPitchSnapshot = 0          → isVoiced=false → 立即断线 ✓
        if publishValue == nil, isVoiced, lastValidF2 > 0, f2HoldCount < Self.maxF2HoldFrames {
            f2HoldCount += 1
            publishValue = lastValidF2
        }

        // ③ hold 超限 → 断线，清零缓存
        if publishValue == nil {
            lastValidF2 = 0
            f2HoldCount = 0
        }

        if shouldPrint {
            let f1Str  = detectedF1.map { String(format:"%.0f", $0) } ?? "nil"
            let mode   = detectedF2 != nil ? "detected" : (publishValue != nil ? "hold(\(f2HoldCount))" : "nil")
            print("[LPC] F1=\(f1Str)  f2Floor=\(String(format:"%.0f",f2Floor))  F2=\(publishValue.map{String(format:"%.0f",$0)} ?? "nil")  [\(mode)]")
        }

        publishF2(publishValue)
    }

    private func publishF2(_ value: Float?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.f2 = value ?? 0
            self.f2History.removeFirst()
            self.f2History.append(value)
        }
    }

    // MARK: - LPC helpers

    /// 预加重滤波：y[n] = x[n] - α·x[n-1]。
    /// 语音识别常用 α=0.97，但共振峰分析应使用 α≈0（不预加重）：
    /// 预加重使 F1（~500 Hz）仅剩 ~6%（α=0.97）或 ~30%（α=0.70），
    /// LPC 会把极点全部分配给高频，导致 F1/F2 峰消失。
    /// 默认 α=0 即直接透传，声道谱包络保持自然衰减形态，共振峰更清晰。
    private func preEmphasis(_ x: [Float], alpha: Float = 0.0) -> [Float] {
        guard alpha > 0 else { return x }  // alpha=0 时直接跳过，避免无效计算
        var y = x
        for i in stride(from: y.count - 1, through: 1, by: -1) {
            y[i] -= alpha * x[i - 1]
        }
        return y
    }

    /// Hamming 窗（vDSP 加速），减少帧边缘的频谱泄漏。
    private func applyHamming(_ x: [Float]) -> [Float] {
        let n = x.count
        var window = [Float](repeating: 0, count: n)
        vDSP_hamm_window(&window, vDSP_Length(n), 0)
        var result = [Float](repeating: 0, count: n)
        vDSP_vmul(x, 1, window, 1, &result, 1, vDSP_Length(n))
        return result
    }

    /// 偏置自相关 r[k] = Σ x[n]·x[n+k]，使用 vDSP 点积加速，共计 (order+1) 次向量点积。
    private func autocorrelation(_ x: [Float], order: Int) -> [Float] {
        let n = x.count
        var r = [Float](repeating: 0, count: order + 1)
        x.withUnsafeBufferPointer { ptr in
            for k in 0 ... order {
                vDSP_dotpr(
                    ptr.baseAddress!,     1,
                    ptr.baseAddress! + k, 1,
                    &r[k],
                    vDSP_Length(n - k)
                )
            }
        }
        return r
    }

    /// Levinson-Durbin 递推：由自相关序列直接求解 LPC 系数 a[0..order-1]。
    private func levinsonDurbin(_ r: [Float], order: Int) -> [Float] {
        var a = [Float](repeating: 0, count: order)
        var e = r[0]

        for i in 0 ..< order {
            var lambda: Float = 0
            for j in 0 ..< i {
                lambda += a[j] * r[i - j]
            }
            guard e > 1e-10 else { break }
            lambda = -(r[i + 1] + lambda) / e

            let aCopy = a
            a[i] = lambda
            for j in 0 ..< i {
                a[j] = aCopy[j] + lambda * aCopy[i - 1 - j]
            }

            e *= 1.0 - lambda * lambda
        }

        return a
    }

    /// LPC 谱包络：H(f) = 1 / |A(e^{jω})|²，在 nPoints 个频率点上逐一评估。
    ///
    /// A(e^{jω}) = 1 + Σ_{m=1}^{p} a[m]·e^{-jmω}
    private func lpcSpectrum(_ a: [Float], nPoints: Int) -> [Float] {
        var spectrum = [Float](repeating: 0, count: nPoints)
        let order = a.count
        for k in 0 ..< nPoints {
            let omega = Float.pi * Float(k) / Float(nPoints)
            var re: Float = 1.0
            var im: Float = 0.0
            for m in 0 ..< order {
                let angle = Float(m + 1) * omega
                re += a[m] * cos(angle)
                im -= a[m] * sin(angle)
            }
            let mag2 = re * re + im * im
            spectrum[k] = mag2 > 0 ? 1.0 / mag2 : 0
        }
        return spectrum
    }

    /// 降采样：对每 factor 个样本取均值（boxcar 低通 + 抽取），减少高频混叠。
    /// 44100 Hz ÷ 4 = 11025 Hz，可覆盖共振峰分析所需的 0–5512 Hz 范围。
    private func downsample(_ x: [Float], factor: Int) -> [Float] {
        let outCount = x.count / factor
        var result   = [Float](repeating: 0, count: outCount)
        let fFactor  = Float(factor)
        for i in 0 ..< outCount {
            let base = i * factor
            var sum: Float = 0
            for k in 0 ..< factor { sum += x[base + k] }
            result[i] = sum / fFactor
        }
        return result
    }

    /// 峰值拾取：在 LPC 谱包络中找局部极大值，返回频率（Hz）按升序排列。
    /// sampleRate 为信号实际采样率（降采后的有效采样率）。
    private func findFormants(_ spectrum: [Float], sampleRate: Float) -> [Float] {
        let binWidth = sampleRate / 2.0 / Float(spectrum.count)
        var formants: [Float] = []

        for i in 1 ..< spectrum.count - 1 {
            guard spectrum[i] > spectrum[i - 1],
                  spectrum[i] > spectrum[i + 1] else { continue }

            let hz = Float(i) * binWidth
            guard hz >= Self.formantSearchMin, hz <= Self.formantSearchMax else { continue }

            formants.append(hz)
        }

        return formants
    }

    // MARK: - iOS Audio Session

#if os(iOS)
    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.defaultToSpeaker, .allowBluetooth]
            )
            try session.setActive(true)
        } catch {
            print("[AudioAnalyzer] AVAudioSession 配置失败：\(error)")
        }
    }
#endif

    deinit {
        stop()
    }
}
