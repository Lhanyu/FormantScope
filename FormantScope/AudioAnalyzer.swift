// AudioAnalyzer.swift
// FormantScope
//
// 引擎层：PitchTap 提取 F0（基频）；RawDataTap + LPC 提取 F2（第二共振峰）。

import AudioKit
import AudioKitEX
import SoundpipeAudioKit
import AVFoundation
import Accelerate

final class AudioAnalyzer: ObservableObject {

    // MARK: - Timed history model

    /// 一条带时间戳的历史样本。
    /// `t` 取自单调时钟（`ProcessInfo.systemUptime`），单位秒。
    /// 旧设计用「定长 100 的帧索引数组」，但每帧时长 = bufferSize/sampleRate，
    /// 在不同平台/硬件采样率下并不一致（44.1k≈93ms vs 48k≈85ms），导致同样
    /// 100 帧在不同设备上跨越的真实时间不同；且 F0（PitchTap）与 F1/F2（RawDataTap）
    /// 是两个独立 tap，帧索引无法对齐到同一真实时刻。改为按测量时刻打时间戳后，
    /// 图表可按真实时间轴渲染固定窗口，跨设备一致，且三路曲线时间对齐。
    struct TimedSample: Equatable {
        let t: Double
        let value: Float?
    }

    /// 会话逻辑时钟读数（秒），用于给样本打时间戳。
    /// = 单调 `systemUptime` − 累计暂停时长，暂停期间不推进。
    /// 这样 stop→start 时第一个新样本紧接最后一个旧样本（仅差一帧），
    /// 曲线无缝续接，而非因 referenceNow 跳变导致旧曲线整体左移 + 跨暂停间隔的斜线。
    private func sessionTime() -> Double {
        ProcessInfo.processInfo.systemUptime - pausedDurationAccumulated
    }

    /// 累计暂停时长（秒）：把单调时钟折算为"仅活跃时间"的会话时钟。
    private var pausedDurationAccumulated: Double = 0

    /// 上次 stop 时的原始 systemUptime；下次 start 据此累加暂停间隔。0 表示尚未停止过。
    private var lastStopUptime: Double = 0

    /// 历史保留时长（秒）：覆盖最大可调时间窗 + 余量。超过此跨度的旧样本会被裁掉。
    private static let historyRetainSeconds: Double = 30

    // MARK: - Published state

    /// 当前检测到的基频（Hz）。0 表示无有效信号。
    @Published var pitch: Float = 0.0

    /// 当前信号幅度，可用于判断是否有有效输入。
    @Published var amplitude: Float = 0.0

    /// 音高历史（带时间戳）。value 为 nil 表示静音帧，Charts 遇到 nil 会自动断开线条。
    @Published var pitchHistory: [TimedSample] = []

    /// 当前检测到的第一共振峰（Hz）。0 表示无有效信号。
    @Published var f1: Float = 0.0

    /// F1 历史（带时间戳）。value 为 nil 表示静音帧或 LPC 未找到有效 F1。
    @Published var f1History: [TimedSample] = []

    /// 当前检测到的第二共振峰（Hz）。0 表示无有效信号。
    @Published var f2: Float = 0.0

    /// F2 历史（带时间戳）。value 为 nil 表示静音帧或 LPC 未找到有效 F2。
    @Published var f2History: [TimedSample] = []

    /// 最近一次保存的录音完整路径（含文件名）；非 nil 时主界面可显示非阻塞浮层。
    @Published private(set) var lastSavedRecordingPath: String?

    /// 输入源 / 音频路由发生变化、引擎被系统重配置时自增。
    /// 此时引擎已被动停止，ContentView 监听此计数把界面复位到初始态
    /// （与用户手动「停止聆听」表现一致：曲线冻结、按钮回到 Start）。
    /// 用计数器而非 Bool：连续两次自动停止也能各触发一次 onChange。
    @Published private(set) var autoStopSignal = 0

    // MARK: - Noise gate

    /// 振幅低于此阈值时视为静音（PitchTap / AUBIO 归一化幅度）。
    static var amplitudeThreshold: Float {
#if os(iOS)
        0.08
#else
        0.15
#endif
    }
    /// iOS 内置麦克风在 measurement 模式下幅度读数通常明显低于 macOS。
    /// 这里仅补偿 PitchTap 的门控与 UI 幅度显示，不改变原始 PCM / LPC 数据。
    private static var amplitudeDisplayGain: Float {
#if os(iOS)
        2.0
#else
        1.0
#endif
    }
    static let minPitch: Float = 50.0
    static let maxPitch: Float = 1_200.0
    /// 从静音进入有声态所需的连续帧数（onset）。
    /// 2 帧 ≈ 180 ms，比原来 3 帧（270 ms）更快响应，减少元音起始的 F0 延迟。
    static let requiredConsecutiveFrames: Int = 2
    /// F0 显示保持帧数（offset hysteresis）：确认的 F0 消失后，再保持这么多帧再断线。
    /// PitchTap 默认 buffer=4096，在 44.1 kHz 下每帧约 93 ms。
    /// 设为 1 → 尾巴 ≈ 93 ms，仅吸收单帧抖动，肉眼几乎不可见，避免长尾效应。
    /// （原值 5 ≈ 465 ms 长尾，是为跨越清辅音闭塞段而设；本工具是连续元音追踪，不需要这种桥接。）
    private static let maxPitchHoldFrames: Int = 1
    /// 相邻帧允许的最大 F0 变化。超过后不立刻采纳，先作为“可疑突变”观察。
    private static let maxPitchDeltaPerFrame: Float = 200
    /// 大跳变至少连续出现这么多帧才接受，抑制咽气/口水等瞬态毛刺。
    private static let pitchJumpConfirmationFrames: Int = 2

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
    private static var rmsThreshold: Float {
#if os(iOS)
        0.0025
#else
        0.005
#endif
    }

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
    private var hasBuiltGraph = false
    private var isRunning = false

    /// LPC 计算专用后台队列，避免阻塞主线程。
    private let lpcQueue = DispatchQueue(label: "com.formantscope.lpc", qos: .userInteractive)

    private var consecutiveVoiceFrames: Int = 0
    /// F0 显示保持：上次确认的音高值，onset 结束后继续展示 maxPitchHoldFrames 帧。
    private var lastConfirmedPitch: Float = 0
    private var pitchHoldCount: Int = 0
    /// 可疑大跳变候选值与累计帧数：用于“连续确认后再切换”。
    private var pendingJumpPitch: Float = 0
    private var pendingJumpCount: Int = 0

    /// 静音 Fader：AudioEngine 必须设置 output 才能让 tap 正常触发。
    private var silence: Fader?

    /// mic → innerMixer → **recordMixer** → Fader；录音 tap 仅挂在 recordMixer。
    private var recordMixer: Mixer?

    /// RawDataTap / 采样率引用：挂在 innerMixer（原 tapMixer）。
    private var tapMixer: Mixer?

    /// 往用户目录写 WAV 的 tap（每节点仅允许一个 tap，故单独挂 recordMixer）。
    private var recordTapInstalled = false
    private let recordIOQueue = DispatchQueue(label: "com.yueranwang.formantscope.record", qos: .utility)
    private var recordingFile: AVAudioFile?
    /// 待写录音目标 URL：beginRecording 登记，首个缓冲到达时据此用真实格式懒建 recordingFile。
    /// 仅在 recordIOQueue 上访问。
    private var pendingRecordingURL: URL?
    /// 与 recordingFile 成对的 security-scoped 目录 URL（须在 stop 写盘后 stopAccessing）。
    private var recordingScopedParentURL: URL?
    /// 当前正在写入的 WAV URL（`endRecording` 后用其 path 提示浮层）。
    private var activeRecordingFileURL: URL?

    /// Debug 帧计数，每 30 帧打印一次 LPC 诊断日志。
    private var lpcDebugCount = 0

    /// PitchTap 最新的确认音高快照，供 lpcQueue 判断当前是否有声。
    /// 写入：main（PitchTap 回调）；读取：lpcQueue（processLPC）。
    /// Float 读写在 x86/ARM 上天然原子，此处轻微数据竞争对展示无影响。
    private var currentPitchSnapshot: Float = 0

    /// PitchTap 最新的原始幅度快照（未经防抖），用于低 F0 场景下的备用声态门控。
    /// 当 F0 低（~100 Hz）时，3 帧防抖会频繁将 pitch 清零，但 amplitude 更稳定。
    private var amplitudeSnapshot: Float = 0

    /// LPC 流水线上次找到的有效 F1（Hz），仅在 lpcQueue 上访问。
    private var lastValidF1: Float = 0

    /// 当 LPC 未检到有效 F1 时，最多连续保持多少帧旧 F1 值。
    private static let maxF1HoldFrames = 8

    /// 相邻帧 F1 最大允许跳变量（Hz/帧）。F1 移动比 F2 慢，/a/→/i/ 跨度约 400 Hz。
    private static let maxF1DeltaPerFrame: Float = 400
    private var f1HoldCount: Int = 0

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

    /// AVAudioEngineConfigurationChange 观察者令牌，deinit 时注销。
    private var configChangeObserver: NSObjectProtocol?

    init() {
#if os(iOS)
        // iOS（尤其是模拟器）在 AVAudioSession 激活前常拿到无效 input format（sampleRate = 0）。
        // 因此延迟到 start()（会话激活之后）再构建音频图。
#else
        buildGraph()
#endif
        registerConfigChangeObserver()
    }

    /// 监听音频引擎配置变化（输入源切换、采样率/通道变化、设备插拔）。
    /// 系统在路由变化时会停止并需重配置引擎；若我们继续用旧 tap/格式渲染，会出现
    /// 用户描述的「卡一下、切回来又能用、但仍变卡」的不一致状态。这里统一处理为：
    /// 主动停止采集并发信号让 UI 复位到初始态，等用户重新点 Start 再以新输入格式启动。
    ///
    /// 该通知由 AVAudioEngine 在内部线程发出，故切回主线程再操作引擎与 @Published 状态。
    private func registerConfigChangeObserver() {
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine.avEngine,
            queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.handleConfigurationChange()
            }
        }
    }

    /// 在主线程处理配置变化：仅当正在运行时才停止并通知 UI。
    /// 复用 stop()（已含 endRecording + 暂停时钟记账），保证与手动停止的会话时钟、
    /// 录音落盘行为完全一致，曲线得以无缝冻结。
    private func handleConfigurationChange() {
        guard isRunning else { return }
        stop()
        autoStopSignal &+= 1
    }

    // MARK: - Graph construction

    private func buildGraph() {
        // 重建前先清理旧 tap，避免重复 installTap。
        pitchTap?.stop()
        rawDataTap?.stop()
        if recordTapInstalled, let rm = recordMixer {
            rm.avAudioNode.removeTap(onBus: 0)
            recordTapInstalled = false
        }
        pitchTap = nil
        rawDataTap = nil
        tapMixer = nil
        recordMixer = nil
        silence = nil

        guard let mic = engine.input else {
            print("[AudioAnalyzer] 麦克风输入不可用")
            return
        }

        // AVAudioNode 一次只允许一个 installTap。
        // innerMixer：RawDataTap；recordMixer：写入 WAV；PitchTap 仍挂在 mic。
        let innerMixer = Mixer(mic)
        tapMixer       = innerMixer
        let recordBranch = Mixer(innerMixer)
        recordMixer    = recordBranch
        let silenceNode = Fader(recordBranch, gain: 0)
        silence = silenceNode
        engine.output = silenceNode

        // PitchTap：提取 F0 和幅度（AudioKitEX 内部使用 AUBIO，已自动派发到 main）
        pitchTap = PitchTap(mic) { [weak self] pitches, amps in
            guard let self else { return }
            // AUBIO 在静音/瞬态首帧偶尔返回空数组，直接 [0] 下标会崩溃。
            guard let currentPitch = pitches.first, let currentAmp = amps.first else { return }

            // 在测量发生处取时间戳（主线程），与 F1/F2 各自的测量时刻独立打点，
            // 让三路历史按真实时间轴对齐，而非依赖帧索引。
            let t = self.sessionTime()

            let displayAmp = min(currentAmp * Self.amplitudeDisplayGain, 1.0)
            let isVoice = displayAmp   >= Self.amplitudeThreshold
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
                let acceptedPitch: Float

                if self.lastConfirmedPitch > 0 {
                    let delta = abs(currentPitch - self.lastConfirmedPitch)
                    if delta > Self.maxPitchDeltaPerFrame {
                        // 大跳变：先观察，只有连续多帧都落在同一新频段才切换过去。
                        if self.pendingJumpCount > 0,
                           abs(currentPitch - self.pendingJumpPitch) <= Self.maxPitchDeltaPerFrame {
                            self.pendingJumpCount += 1
                        } else {
                            self.pendingJumpPitch = currentPitch
                            self.pendingJumpCount = 1
                        }

                        if self.pendingJumpCount >= Self.pitchJumpConfirmationFrames {
                            acceptedPitch = self.pendingJumpPitch
                            self.pendingJumpPitch = 0
                            self.pendingJumpCount = 0
                        } else {
                            acceptedPitch = self.lastConfirmedPitch
                        }
                    } else {
                        // 正常连续变化，清空突变候选。
                        self.pendingJumpPitch = 0
                        self.pendingJumpCount = 0
                        acceptedPitch = currentPitch
                    }
                } else {
                    // 首次进入确认态，直接接受。
                    self.pendingJumpPitch = 0
                    self.pendingJumpCount = 0
                    acceptedPitch = currentPitch
                }

                self.lastConfirmedPitch = acceptedPitch
                displayPitch = acceptedPitch
            } else if self.lastConfirmedPitch > 0,
                      self.pitchHoldCount < Self.maxPitchHoldFrames {
                self.pitchHoldCount += 1
                displayPitch = self.lastConfirmedPitch  // 保持上一帧值
            } else {
                self.lastConfirmedPitch = 0
                self.pendingJumpPitch = 0
                self.pendingJumpCount = 0
                displayPitch = nil
            }

            self.pitch                = displayPitch ?? 0
            // currentPitchSnapshot 只在"真正确认"时更新，F2 接受新值需要此快照 > 0。
            // hold 期间保持上一次确认值，让 isVoiced 门控仍然有效。
            if confirmed { self.currentPitchSnapshot = currentPitch }
            else if displayPitch == nil { self.currentPitchSnapshot = 0 }
            // displayPitch != nil 但 !confirmed（hold 中）：currentPitchSnapshot 保持不变

            self.amplitudeSnapshot    = displayAmp
            self.amplitude            = displayAmp
            self.appendSample(to: &self.pitchHistory, value: displayPitch, at: t)
        }

        // RawDataTap 挂在 innerMixer 而非 mic，避免与 PitchTap 争用同一 AVAudioNode 的 installTap。
        // bufferSize 4096 与 PitchTap 内部缓冲大小一致，使两条历史曲线帧率相近（约 10 fps）。
        rawDataTap = RawDataTap(innerMixer, bufferSize: 4_096, callbackQueue: lpcQueue) { [weak self] samples in
            self?.processLPC(samples)
        }
        hasBuiltGraph = true
    }

    // MARK: - Lifecycle

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
#if os(iOS)
        guard configureAudioSession() else { return false }
        if !hasBuiltGraph { buildGraph() }
#elseif os(macOS)
        if !hasBuiltGraph { buildGraph() }
#endif
        guard hasBuiltGraph else {
            print("[AudioAnalyzer] 音频图尚未构建，无法启动")
            return false
        }
        do {
            try engine.start()
            // 累加本次暂停间隔到 pausedDurationAccumulated，使会话时钟在暂停期间"不走"。
            // 仅在成功启动后累加，避免启动失败时误计。lastStopUptime=0 表示首次启动，无需累加。
            if lastStopUptime > 0 {
                pausedDurationAccumulated += ProcessInfo.processInfo.systemUptime - lastStopUptime
                lastStopUptime = 0
            }
            // 注意：不在此处安装录音 tap。蓝牙输入（AirPods）下，对已运行引擎的 mixer
            // 节点调用 installTap 会触发 I/O 重配置并阻塞主线程，导致"开始聆听"无响应。
            // 录音 tap 改为按需安装：beginRecordingToUserFolder → installRecordTapOnQueue（后台队列）。
            pitchTap?.start()
            rawDataTap?.start()
            isRunning = true
            return true
        } catch {
            print("[AudioAnalyzer] 引擎启动失败：\(error)")
            return false
        }
    }

    func stop() {
        guard isRunning else { return }
        endRecording()
        pitchTap?.stop()
        rawDataTap?.stop()
        // 不在此处 removeTap：removeTap 与 installTap 一样会在蓝牙输入下阻塞主线程。
        // 录音 tap 设计为常驻，非录音期间其回调以 recordingFile==nil 守卫直接丢弃缓冲。
        engine.stop()
        // 清理渲染状态，提升 iOS 上重复启停稳定性（不破坏现有连接图）。
        engine.avEngine.reset()
        isRunning = false
        // 记录停止时刻（原始单调时钟），下次 start 据此把暂停间隔从会话时钟里扣除。
        lastStopUptime = ProcessInfo.processInfo.systemUptime
#if os(iOS)
        // 不在每次 stop 后立刻 setActive(false)，避免频繁路由重配置引发通道格式不一致。
#endif
    }

    // MARK: - User folder recording (WAV)

    enum RecordingError: LocalizedError {
        case engineNotRunning
        case graphNotReady
        case invalidOutputFormat

        var errorDescription: String? {
            switch self {
            case .engineNotRunning: return "Start listening before recording."
            case .graphNotReady: return "Audio graph is not ready."
            case .invalidOutputFormat: return "Could not read microphone output format."
            }
        }
    }

    /// 在用户已选目录中创建 `formantscope-*.wav` 并写入 PCM；需已 `start()`。
    func beginRecordingToUserFolder(store: RecordingFolderStore = .shared) throws {
        guard isRunning else { throw RecordingError.engineNotRunning }
        try beginRecordingToUserFolderLocked(store: store)
    }

    private func beginRecordingToUserFolderLocked(store: RecordingFolderStore) throws {
        guard recordingScopedParentURL == nil else { return }
        var alreadyRecording = false
        recordIOQueue.sync { alreadyRecording = (recordingFile != nil) }
        guard !alreadyRecording else { return }

        guard let rm = recordMixer else {
            throw RecordingError.graphNotReady
        }

        let parent = try store.resolveAndStartAccess()
        let fileURL = parent.appendingPathComponent(RecordingFolderStore.makeFileName(), isDirectory: false)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: fileURL)
        }

        recordingScopedParentURL = parent
        activeRecordingFileURL = fileURL
        // 文件不在此处预建：录音 tap 用 format: nil 安装，蓝牙(AirPods/HFP)下交付的缓冲
        // 采样率可能与 recordMixer 报告的 48 kHz 不一致；若按报告格式预建文件，写入异格式
        // 缓冲会失败或产生变速音频。因此把建文件延到首个缓冲到达时（appendRecordingBuffer），
        // 用 buffer.format 创建，保证文件格式与实际数据一致。这里仅在队列上登记待写 URL。
        recordIOQueue.async { [weak self] in
            guard let self else { return }
            self.pendingRecordingURL = fileURL
            self.installRecordTapOnQueue(rm)
        }
    }

    /// 停止写入并释放 security-scoped 访问；不停止引擎。
    func endRecording() {
        let pathToAnnounce = activeRecordingFileURL?.standardizedFileURL.path
        activeRecordingFileURL = nil
        // 同时清掉 recordingFile 与 pendingRecordingURL：若在首个缓冲到达前就停止录音，
        // 残留的待写 URL 会让后续 tap 回调误建文件。两者都只在 recordIOQueue 上改。
        recordIOQueue.sync {
            recordingFile = nil
            pendingRecordingURL = nil
        }
        if let u = recordingScopedParentURL {
            u.stopAccessingSecurityScopedResource()
            recordingScopedParentURL = nil
        }
        if let path = pathToAnnounce {
            // [weak self]：endRecording 可能由 deinit → stop() 触发，此时 self 正在析构，
            // 强引用会让该 Task 延长 self 生命周期并在释放后访问内存（UAF）。
            Task { @MainActor [weak self] in
                self?.lastSavedRecordingPath = path
            }
        }
    }

    /// 关闭底部保存成功浮层（用户点按或超时后调用）。
    func clearSavedRecordingToast() {
        lastSavedRecordingPath = nil
    }

    /// 在 recordIOQueue 上安装录音 tap（若尚未安装）。
    /// 关键：installTap 必须传 format: nil，不能传显式格式。
    /// 蓝牙输入（AirPods）激活麦克风后切到 HFP 模式，输入硬件采样率骤降（如 16 kHz），
    /// 但 recordMixer 的 outputFormat 仍报告 48 kHz。若把 48 kHz 显式传给 installTap，
    /// 引擎内部校验 `format.sampleRate == inputHWFormat.sampleRate` 不成立 → 抛 NSException
    /// （在主线程被 runloop 吞掉表现为"卡死"，在后台队列则直接终止进程）。
    /// 传 nil 时引擎采用节点自身总线格式并跳过该校验，与 PitchTap/RawDataTap 一致，故不崩。
    /// 录音文件用同一节点的 outputFormat 创建，与 nil-tap 交付的缓冲格式一致，写入无碍。
    /// tap 一旦装上即常驻（回调以 recordingFile==nil 守卫丢弃空闲帧），不在 stop 时 removeTap。
    /// 必须在 recordIOQueue 上调用。
    private func installRecordTapOnQueue(_ rm: Mixer) {
        guard !recordTapInstalled else { return }
        let node = rm.avAudioNode
        node.installTap(onBus: 0, bufferSize: 4_096, format: nil) { [weak self] buffer, _ in
            self?.appendRecordingBuffer(buffer)
        }
        recordTapInstalled = true
    }

    private func appendRecordingBuffer(_ buffer: AVAudioPCMBuffer) {
        recordIOQueue.async { [weak self] in
            guard let self else { return }
            // 懒建文件：用首个缓冲的真实格式创建，确保与 nil-tap 交付的数据格式一致
            // （蓝牙切换后采样率可能变化）。仅当有待写 URL 且尚未建文件时执行一次。
            if self.recordingFile == nil, let url = self.pendingRecordingURL {
                self.pendingRecordingURL = nil
                let fmt = buffer.format
                do {
                    self.recordingFile = try AVAudioFile(
                        forWriting: url,
                        settings: fmt.settings,
                        commonFormat: fmt.commonFormat,
                        interleaved: fmt.isInterleaved
                    )
                } catch {
                    print("[FormantScope] Recording file create failed: \(error)")
                    return
                }
            }
            guard let file = self.recordingFile else { return }
            do {
                try file.write(from: buffer)
            } catch {
                print("[FormantScope] Recording write failed: \(error)")
            }
        }
    }

    // MARK: - LPC pipeline

    /// 完整 LPC F2 提取流水线，在 lpcQueue 上执行，结果派发到主线程。
    ///
    /// 流程：RMS 门控 → 预加重 → Hamming 窗 → 自相关 → Levinson-Durbin → 谱包络 → 峰值拾取
    private func processLPC(_ samples: [Float]) {
        // 在 LPC 帧测量时刻打时间戳（lpcQueue），随结果一并派发到主线程，
        // 使 F1/F2 历史与 F0 历史按各自真实测量时刻对齐。
        let t = sessionTime()
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
            publishF1(nil, at: t)
            publishF2(nil, at: t)
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
            publishF1(nil, at: t)
            publishF2(nil, at: t)
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

        // ── F1 稳定逻辑（与 F2 对称）─────────────────────────────────────────
        var publishF1Value: Float? = nil

        if isVoiced, let f1 = detectedF1 {
            let delta = lastValidF1 > 0 ? abs(f1 - lastValidF1) : 0
            if delta <= Self.maxF1DeltaPerFrame {
                lastValidF1 = f1
                f1HoldCount = 0
                publishF1Value = f1
            }
        }

        if publishF1Value == nil, isVoiced, lastValidF1 > 0, f1HoldCount < Self.maxF1HoldFrames {
            f1HoldCount += 1
            publishF1Value = lastValidF1
        }

        if publishF1Value == nil {
            lastValidF1 = 0
            f1HoldCount = 0
        }

        // ── F2 稳定逻辑 ───────────────────────────────────────────────────────
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
            let f1DetStr = detectedF1.map { String(format:"%.0f", $0) } ?? "nil"
            let f1PubStr = publishF1Value.map { String(format:"%.0f", $0) } ?? "nil"
            let f2Mode   = detectedF2 != nil ? "detected" : (publishValue != nil ? "hold(\(f2HoldCount))" : "nil")
            print("[LPC] F1(det)=\(f1DetStr) F1(pub)=\(f1PubStr)  f2Floor=\(String(format:"%.0f",f2Floor))  F2=\(publishValue.map{String(format:"%.0f",$0)} ?? "nil")  [\(f2Mode)]")
        }

        publishF1(publishF1Value, at: t)
        publishF2(publishValue, at: t)
    }

    /// 向带时间戳历史追加一个样本，并裁掉早于保留窗口的旧样本。
    /// 必须在主线程调用（写入 @Published）。
    private func appendSample(to history: inout [TimedSample], value: Float?, at t: Double) {
        history.append(TimedSample(t: t, value: value))
        let cutoff = t - Self.historyRetainSeconds
        if let firstFresh = history.firstIndex(where: { $0.t >= cutoff }), firstFresh > 0 {
            history.removeFirst(firstFresh)
        }
    }

    private func publishF1(_ value: Float?, at t: Double) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.f1 = value ?? 0
            self.appendSample(to: &self.f1History, value: value, at: t)
        }
    }

    private func publishF2(_ value: Float?, at t: Double) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.f2 = value ?? 0
            self.appendSample(to: &self.f2History, value: value, at: t)
        }
    }

    // MARK: - LPC helpers

    /// 预加重滤波：y[n] = x[n] - α·x[n-1]。
    /// α=0.97 是共振峰分析的标准选择（Praat 等同样默认预加重）：
    /// 抵消声门源 −6 dB/oct 的频谱倾斜，避免低频能量主导 LPC，使各阶
    /// 极点更均衡地落在 F1/F2/F3 上、谱包络峰更锐利。
    private func preEmphasis(_ x: [Float], alpha: Float = 0.97) -> [Float] {
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
    private func configureAudioSession() -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
#if targetEnvironment(simulator)
            // 模拟器经常出现 I/O 重配置，使用 record 模式更稳定（无需扬声器回放）。
            try session.setCategory(.record, mode: .measurement, options: [])
#else
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.defaultToSpeaker, .allowBluetooth]
            )
#endif
            // 让 AVAudioSession 与 AudioKit 的 Settings.sampleRate 保持一致，
            // 避免激活后 input format 报告 sampleRate=0 或与下游 tap 的通道格式不匹配。
            // 这两个调用都是 best-effort：硬件可能强制使用其它值，但提示一致目标能显著提升稳定性。
            try? session.setPreferredSampleRate(Settings.sampleRate)
            try? session.setPreferredIOBufferDuration(0.005)   // ~5ms，平衡延迟与稳定性
            try session.setActive(true)
            return true
        } catch {
            print("[AudioAnalyzer] AVAudioSession 配置失败：\(error)")
            return false
        }
    }
#endif

    deinit {
        if let obs = configChangeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        stop()
#if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
#endif
    }
}
