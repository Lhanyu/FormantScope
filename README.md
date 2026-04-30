# FormantScope

Real-time voice analysis app for Apple platforms. It tracks **F0 (fundamental frequency)**, **F1 (first formant)**, and **F2 (second formant)** using a speech-oriented DSP pipeline plus an audio graph layout that avoids tap conflicts.

[简体中文](#简体中文)

---

## English

### Overview

FormantScope is a SwiftUI app that captures live microphone input and shows:

- **F0**: pitch in Hz  
- **F1**: first formant in Hz  
- **F2**: second formant in Hz  
- amplitude level  
- a rolling ~100-frame history as a **dual-axis chart** (F0 on the left scale, F1/F2 share the right scale)

The chart is drawn full-screen behind the main card; traces can visually extend beyond the card region while foreground controls stay readable. Use cases include voice coaching, phonetics demos, and any workflow where responsive visual feedback matters.

### Features

- Live F0 / F1 / F2 readouts  
- Background chart: F0 solid red; F1 blue dashed and F2 green dashed (each formant trace can be hidden)  
- **Settings**: show/hide F1 and F2, edit F0 axis range and shared F1/F2 axis range (persisted via `AppStorage`)  
  - **iOS**: gear menu (top trailing) opens a sheet  
  - **macOS**: standard **Settings** window (**⌘**,) plus **View** menu toggles for F1/F2 (**⌥⌘1**, **⌥⌘2**)  
- **WAV recording**: while listening, **Record** writes `formantscope-YYYYMMdd-HHmmss.wav` into a folder the user selects once (security-scoped bookmark on both platforms); success toast shows the saved path  
- Voice-state gating, onset/offset and jump logic for stable F0; separate hold/max-delta logic for **F1** and **F2**  
- **Silent playback path** (gain 0) so analysis runs without routing audible output  
- **iOS**: listening stops automatically when the app moves to background  
- Startup **stderr filter** trims noisy CoreAudio/XPC decoder lines from the Xcode console (`print` remains on stdout). For floods from `os_log`, set **`OS_ACTIVITY_MODE = disable`** in the Run scheme environment if needed  

### Technical Highlights

#### 1) Audio graph: fork taps + dedicated record branch

Only one tap may attach per `AVAudioNode` bus. The graph keeps **PitchTap** on the microphone, routes mix processing through **`innerMixer`**, and hangs **RawDataTap** on **`innerMixer`** so it never competes with `PitchTap`. A second mixer (**`recordMixer`**) taps the same downstream path for WAV capture; silence is enforced with **`Fader` gain 0** on the branch that drives the engine output.

```text
Mic ──► PitchTap (F0 + level)
 │
 └──► innerMixer ──► RawDataTap (PCM → LPC → F1/F2)
               │
               └──► recordMixer ──► AVAudioEngine tap ──► (WAV while recording)
                        │
                        └──► Fader (gain 0) ──► engine output (silent)
```

This gives stable simultaneous F0 and formant estimation and a separate recording tap without double-tapping one node.

#### 2) LPC-based F1/F2 estimation

Formants are derived from PCM with an LPC spectral envelope pipeline (RMS gate, Hamming window, downsample ×4 toward ~11 kHz, autocorrelation, Levinson–Durbin order 12, envelope sampling, peak picking). **F1** is chosen as the first peak in a low band; **F2** selection is **F1-aware** with a frequency floor above F1 so low F1 is not mistaken for F2 (e.g. vowels like /a/). Both formants apply temporal constraints (per-frame delta limits and short holds across weak frames).

Pitch path uses AudioKitEX **PitchTap** (AUBIO); gate thresholds differ slightly between **iOS** and **macOS** to match typical built-in microphone levels.

#### 3) Practical stability logic

F0: consecutive-frame onset confirmation, minimal hold tail, cautious acceptance of large per-frame jumps.  
F1 / F2: independent hold counters and maximum delta-per-frame guards to reduce spur spikes and harmonic bleed.

### Project structure

```text
FormantScope/
├── FormantScope/
│   ├── FormantScopeApp.swift    # scenes, macOS commands, stderr filter hook
│   ├── ContentView.swift        # main UI, chart, recording controls
│   ├── AudioAnalyzer.swift      # engine, taps, LPC, recording
│   ├── SettingsView.swift
│   ├── RecordingFolderStore.swift
│   ├── RecordingFolderPicker.swift   # iOS document folder picker
│   ├── Info.plist
│   ├── InfoPlist.xcstrings          # localized keys e.g. microphone usage
│   ├── FormantScope.entitlements     # sandbox, mic, user-selected files (macOS)
│   └── Assets.xcassets/
├── FormantScope.xcodeproj/
│   └── project.xcworkspace/xcshareddata/swiftpm/Package.resolved
├── FormantScopeTests/
├── FormantScopeUITests/
├── LICENSE
├── README.md
└── docs/
```

Dependencies resolve via **Swift Package Manager**: add the **SoundpipeAudioKit** package in Xcode; it pulls **AudioKit**, **AudioKitEX**, and related packages (see `Package.resolved` for pinned revisions).

### Tech stack

- Swift / SwiftUI  
- AVFoundation  
- Accelerate (vDSP)  
- AudioKit / AudioKitEX / SoundpipeAudioKit (SPM)  
- Swift Charts  

### Getting started

#### Requirements

- Xcode 16+  
- **iOS 17+** and **macOS 14+** (per `FormantScope` target)  
- Microphone-capable hardware; Apple Developer account for signing on physical devices  

#### Run

Build and run **on a Mac using Xcode**:

1. Open `FormantScope.xcodeproj`  
2. Select the **FormantScope** scheme  
3. Pick a **run destination**: **My Mac**, an **iOS Simulator**, or a connected **iOS device** — then Product → Run (**⌘R**)  
4. Grant microphone access when prompted  
5. Tap **Start Listening**  
6. Optional: **Settings** → choose recording folder; while listening use **Record** / **Stop Recording** to capture WAV  

### Contributing

Contributions are welcome. For substantial changes, please open an issue first to align on scope and design.

### License

This project is released under the [MIT License](LICENSE).

---

## 简体中文

### 项目简介

FormantScope 是基于 SwiftUI 的实时语音分析应用，用于显示与跟踪：

- **F0 基频**  
- **F1 第一共振峰**  
- **F2 第二共振峰**  
- 振幅电平  
- 约 100 帧滚动历史（**左轴 F0**、**右轴 F1/F2 共用** 的双轴图表）

图表绘制在全屏背景层，主区卡片在上层；曲线可视觉延伸到卡片外，读数与按钮仍清晰。适用于发声训练、语音学演示等需要低延迟反馈的场景。

### 功能特性

- 实时 F0 / F1 / F2（Hz）  
- 背景图：F0 红色实线；F1 蓝色虚线、F2 绿色虚线（均可单独关闭）  
- **设置**：F1/F2 显示开关；F0 坐标轴范围与 F1/F2 共用坐标轴范围（`AppStorage` 持久化）  
  - **iOS**：右上角菜单打开 Sheet  
  - **macOS**：系统 **设置（⌘,）**；**显示** 菜单中可 **⌥⌘1 / ⌥⌘2** 切换 F1/F2  
- **WAV 录音**：在「开始聆听」状态下使用 **Record**，将 `formantscope-YYYYMMdd-HHmmss.wav` 写入用户曾选定的目录（书签 + security-scoped）；保存成功会显示路径浮层  
- F0 门控、起止与跳变抑制；F1、F2 各有保持与单帧跳变上限  
- **静音输出链**（Fader 增益为 0），分析时不外放  
- **iOS**：应用进入后台时自动停止聆听  
- 启动时 **过滤 stderr** 中 CoreAudio/XPC 相关噪声行；若仍被 `os_log` 刷屏，可在 Scheme 环境变量中加 **`OS_ACTIVITY_MODE = disable`**  

### 技术亮点

#### 1）音频图：分叉 Tap + 独立录音支路

`AVAudioNode` 同一 bus 只能挂一个 tap。工程将 **PitchTap** 挂在麦克风；**`innerMixer`** 承担混音，**RawDataTap** 挂在 **`innerMixer`** 上供 LPC，与 PitchTap 不冲突；**`recordMixer`** 再分出一支专供 **WAV 写入 tap**；经 **Fader(0)** 接引擎输出以保持静音。

```text
麦克风 ──► PitchTap（F0 + 电平）
    │
    └──► innerMixer ──► RawDataTap（PCM → LPC → F1/F2）
                  │
                  └──► recordMixer ──► 录音 tap ──►（录制时写 WAV）
                           │
                           └──► Fader(0) ──► 引擎输出（静音）
```

#### 2）LPC 估计 F1 / F2

对 PCM 做 RMS 门控、Hamming 窗、4 倍降采样、自相关、Levinson–Durbin（12 阶）、包络与峰值搜索；先稳定 **F1**，再 **F1-aware** 选取 **F2**（动态下限避免把低 F1 当成 F2）。F1/F2 均带时序约束（跳变上限、短时保持）。

F0 来自 AudioKitEX **PitchTap**（AUBIO）；**iOS / macOS** 对幅度门限做了区分，以适配常见内置麦电平差异。

#### 3）稳定性策略

F0：连续帧 onset、短 hold、大幅跳变需多帧确认。  
F1/F2：独立的保持帧与单帧最大跳变，抑制毛刺与高阶共振峰串扰。

### 项目结构

见上文英文 **Project structure**（`SettingsView`、`RecordingFolder*`、无本地 `AudioKit/` 目录，依赖以 SPM 解析）。

### 快速开始

在 **Mac 上用 Xcode 编译并运行**：

1. 打开 `FormantScope.xcodeproj`  
2. 选择 **FormantScope** scheme  
3. 在 Xcode 中选 **运行目标**：**My Mac（本机）**、**iOS 模拟器** 或 **已连接的 iOS 设备**，再 **⌘R** 运行  
4. 授予麦克风权限  
5. **开始聆听**；若需录音，先在设置中选目录，再点 **Record**  

**系统要求**：Xcode 16+；应用目标为 **iOS 17+**、**macOS 14+**。

### 许可

本项目以 [MIT 许可证](LICENSE) 开源。
