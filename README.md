# FormantScope

**[English](#english)** · **[简体中文](#简体中文)**

---

<a id="english"></a>

## English

Brief intro for Apple platforms — **F0 (fundamental frequency)**, **F1 (first formant)**, and **F2 (second formant)** via a speech-oriented DSP pipeline and an audio graph that avoids tap conflicts.

### Overview

FormantScope is a SwiftUI app that captures live microphone input and shows:

- **F0**: pitch in Hz  
- **F1**: first formant in Hz  
- **F2**: second formant in Hz  
- amplitude level  
- a rolling ~100-frame history as a **dual-axis chart** (F0 on the left scale; F1 and F2 share the right scale)

The chart fills the screen behind the main card; traces can extend beyond that card while the foreground stays readable — useful for coaching, demos, or any workflow that needs responsive feedback.

### Features

- Live F0 / F1 / F2 readouts  
- Background chart — F0 solid red; F1 blue dashed and F2 green dashed (each formant curve can be hidden)  
- **Settings** — show/hide F1 and F2; edit the F0 axis range and the shared F1/F2 axis range (`AppStorage`)  
  - **iOS**: toolbar button (top trailing) opens a sheet  
  - **macOS**: standard **Settings** (**⌘,**) plus **View** menu toggles for F1/F2 (**⌥⌘1**, **⌥⌘2**)  
- **WAV recording** — while listening, **Record** writes `formantscope-YYYYMMdd-HHmmss.wav` into a folder chosen once per device (security-scoped bookmark); a toast shows the saved path  
- Voice gating plus onset/hold/jump smoothing for **F0**; separate hold and max-per-frame deltas for **F1** / **F2**  
- **Silent output path** (Fader gain 0) — analysis without audible playback  
- **iOS**: listening stops when the app goes to the background  
- **stderr filtering** at launch for noisy CoreAudio / XPC lines in the Xcode console; for `os_log` spam, try **`OS_ACTIVITY_MODE = disable`** in the scheme environment  

### Technical highlights

#### 1) Audio graph — fork taps and a record branch

Only one tap may attach per `AVAudioNode` bus. **PitchTap** stays on the mic; **`innerMixer`** carries the summed path where **RawDataTap** reads PCM for LPC. A separate **`recordMixer`** hosts the WAV tap; **`Fader` gain 0** on the way to **engine.output** keeps things silent.

```text
Mic ──► PitchTap (F0 + level)
 │
 └──► innerMixer ──► RawDataTap (PCM → LPC → F1/F2)
               │
               └──► recordMixer ──► AVAudioEngine tap ──► (WAV while recording)
                        │
                        └──► Fader (gain 0) ──► engine output (silent)
```

#### 2) LPC-based F1 / F2 estimation

LPC envelope path: RMS gate, Hamming window, downsample ×4 (~11 kHz), autocorrelation, Levinson–Durbin (order 12), envelope sampling, peak picking. **F1** is the first prominent low-band peak; **F2** is **F1-aware** with a floor above F1 so low F1 is not read as F2 (e.g. vowels such as /a/). Both peaks use temporal limits (delta caps and brief holds).

**F0** comes from AudioKitEX **PitchTap** (AUBIO). Amplitude gates differ slightly on **iOS** vs **macOS** for typical built-in microphones.

#### 3) Practical stability logic

**F0** — onset needs consecutive voiced frames; short hold tail; large jumps must confirm across frames before switching.  

**F1 / F2** — independent counters and delta guards to tame spikes and harmonic leakage.

### Project structure

```text
FormantScope/
├── FormantScope/
│   ├── FormantScopeApp.swift         # scenes, macOS commands, stderr filter
│   ├── ContentView.swift             # UI, chart, recording controls
│   ├── AudioAnalyzer.swift           # engine, taps, LPC, WAV
│   ├── SettingsView.swift
│   ├── RecordingFolderStore.swift
│   ├── RecordingFolderPicker.swift   # iOS folder picker sheet
│   ├── Info.plist
│   ├── InfoPlist.xcstrings           # e.g. microphone usage strings
│   ├── FormantScope.entitlements     # sandbox, mic, user-selected files (Mac)
│   └── Assets.xcassets/
├── FormantScope.xcodeproj/
│   └── project.xcworkspace/xcshareddata/swiftpm/Package.resolved
├── FormantScopeTests/
├── FormantScopeUITests/
├── LICENSE
├── README.md
└── docs/
```

SPM resolves **SoundpipeAudioKit**, which pulls **AudioKit**, **AudioKitEX**, and related repos (see **`Package.resolved`** for pinned versions).

### Tech stack

- Swift / SwiftUI  
- AVFoundation  
- Accelerate (vDSP)  
- AudioKit / AudioKitEX / SoundpipeAudioKit (SPM)  
- Swift Charts  

### Getting started

#### Requirements

- Xcode 16+  
- Deployment: **iOS 17+** and **macOS 14+** (`FormantScope` target)  
- A microphone; an Apple Developer account if you run on a physical **iOS** device  

#### Run

Build and run **on a Mac with Xcode**:

1. Open **`FormantScope.xcodeproj`**  
2. Select the **FormantScope** scheme  
3. Choose a **run destination** — **My Mac**, an **iOS Simulator**, or a connected **iOS device** — then **Product → Run** (**⌘R**)  
4. Allow microphone access when asked  
5. Tap **Start Listening**  
6. Optional: **Settings** → pick a recording folder; while listening, **Record** / **Stop Recording** for WAV  

### Contributing

Contributions are welcome. For larger changes, open an issue first so scope and design stay aligned.

### License

Released under the [MIT License](LICENSE).

---

<a id="简体中文"></a>

## 简体中文

面向 Apple 平台的实时语音分析工具：跟踪 **F0（基频）**、**F1（第一共振峰）**、**F2（第二共振峰）**，采用面向语音的 DSP 与避免 tap 冲突的音频图。

### 概述

FormantScope 基于 SwiftUI，采集麦克风并显示：

- **F0**：基频（Hz）  
- **F1**：第一共振峰（Hz）  
- **F2**：第二共振峰（Hz）  
- 振幅电平  
- 约 **100 帧**滚动历史，**双轴折线图**（左轴 F0；F1 与 F2 共用右轴）

图表铺满主卡片背后的全屏区域，曲线可越过主卡视觉范围，前景读数与按钮仍清晰；适用于练声、语音学演示等需要即时反馈的场景。

### 功能特性

- 实时 F0 / F1 / F2  
- 背景图：F0 红色实线；F1 蓝色虚线、F2 绿色虚线（可分别关闭）  
- **设置**：F1/F2 显示开关；F0 纵轴范围与 F1/F2 共用纵轴范围（`AppStorage`）  
  - **iOS**：右上角工具栏按钮弹出 Sheet  
  - **macOS**：系统 **设置（⌘,）**，以及 **显示** 菜单中的 F1/F2 开关（**⌥⌘1**、**⌥⌘2**）  
- **WAV 录音**：聆听中点击 **Record**，写入 `formantscope-YYYYMMdd-HHmmss.wav`；目录一次性选定（书签 + security-scoped），保存后以浮层显示路径  
- **F0** 有声门控与起停、跳变平滑；**F1**、**F2** 各自的保持帧与帧间最大跳变限制  
- **静音输出链路**（Fader 增益 0），只做分析不外放  
- **iOS**：进入后台自动停止聆听  
- 启动时对 Xcode 控制台 **stderr** 做 CoreAudio / XPC 噪声行过滤；若仍被 `os_log` 刷屏，可在 Scheme 环境变量中设置 **`OS_ACTIVITY_MODE = disable`**  

### 技术亮点

#### 1）音频图：分叉 Tap 与录音支路

同一 `AVAudioNode` bus 仅能挂一个 tap。**PitchTap** 驻留在麦克风；**`innerMixer`** 混音并由 **RawDataTap** 取 PCM 做 LPC。**`recordMixer`** 单独挂录音 tap；经 **`Fader(0)`** 接 **输出**以保持静音。

```text
麦克风 ──► PitchTap（F0 + 电平）
    │
    └──► innerMixer ──► RawDataTap（PCM → LPC → F1/F2）
                  │
                  └──► recordMixer ──► 录音 tap ──►（录制时写 WAV）
                           │
                           └──► Fader(0) ──► 引擎输出（静音）
```

#### 2）基于 LPC 的 F1 / F2 估计

包络路径：RMS 门控、Hamming 窗、4 倍降采样（约 11 kHz）、自相关、Levinson–Durbin（12 阶）、包络采样与峰值搜索。**F1** 取低频段首要峰；**F2** 在 **F1-aware** 下选取，频率下限高于 F1，避免把偏低 F1 误判为 F2（如元音 /a/）。两峰均有时序约束（跳变上限、短时保持）。

**F0** 来自 AudioKitEX **PitchTap**（AUBIO）。**iOS** 与 **macOS** 对幅度门限略有区分，以适配常见内置麦克风。

#### 3）稳定性策略

**F0** — 有声需连续帧确认；短时保持；大范围跳变需多帧后方可切换。  

**F1 / F2** — 独立的保持与帧间 Δ 守卫，减轻毛刺与谐波泄漏。

### 项目结构

```text
FormantScope/
├── FormantScope/
│   ├── FormantScopeApp.swift         # 场景、macOS 菜单、stderr 过滤
│   ├── ContentView.swift             # 界面、图表、录音控件
│   ├── AudioAnalyzer.swift           # 引擎、tap、LPC、WAV
│   ├── SettingsView.swift
│   ├── RecordingFolderStore.swift
│   ├── RecordingFolderPicker.swift   # iOS 文件夹 Sheet
│   ├── Info.plist
│   ├── InfoPlist.xcstrings           # 如麦克风权限文案
│   ├── FormantScope.entitlements     # 沙盒、麦克风、用户所选文件夹（Mac）
│   └── Assets.xcassets/
├── FormantScope.xcodeproj/
│   └── project.xcworkspace/xcshareddata/swiftpm/Package.resolved
├── FormantScopeTests/
├── FormantScopeUITests/
├── LICENSE
├── README.md
└── docs/
```

依赖由 **Swift Package Manager** 解析 **SoundpipeAudioKit**，并传递依赖 **AudioKit**、**AudioKitEX** 等；版本见 **`Package.resolved`**。

### 技术栈

- Swift / SwiftUI  
- AVFoundation  
- Accelerate（vDSP）  
- AudioKit / AudioKitEX / SoundpipeAudioKit（SPM）  
- Swift Charts  

### 快速开始

#### 环境要求

- Xcode 16+  
- 部署：**iOS 17+**、**macOS 14+**（`FormantScope` 目标）  
- 麦克风；若在实体 **iOS** 设备上运行，需要 Apple Developer 账号完成签名  

#### 运行

在 **Mac 上使用 Xcode** 编译并运行：

1. 打开 **`FormantScope.xcodeproj`**  
2. 选择 **FormantScope** scheme  
3. 选择 **运行目标** — **My Mac（本机）**、**iOS 模拟器** 或 **已连接的 iOS 设备** — 执行 **Product → Run**（**⌘R**）  
4. 在系统提示时允许麦克风权限  
5. **开始聆听**  
6. 可选：**设置** 中选择录音目录；聆听时使用 **Record** / **Stop Recording** 保存 WAV  

### 贡献

欢迎贡献代码或反馈。若以较大重构或新特性为主，建议先提交 issue，约定范围与设计。

### 许可

本项目基于 [MIT 许可证](LICENSE) 开源。
