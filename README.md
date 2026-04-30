# FormantScope

Real-time voice analysis app for Apple platforms, focused on **F0 (fundamental frequency)** and **F2 (second formant)** tracking with a speech-oriented DSP pipeline.

[简体中文](#简体中文)

---

## English

### Overview

FormantScope is a SwiftUI app that captures live microphone input and visualizes:

- **F0**: pitch (fundamental frequency) in Hz
- **F2**: second formant in Hz
- amplitude level
- short-term trend history (dual-axis chart)

It is designed for voice training, speech experiments, and educational demos where low-latency feedback matters.

### Features

- Real-time F0 and F2 readout
- Dual-series chart with independent visual scales
- Voice-state gating and hysteresis to reduce flicker
- iOS/macOS compatibility and robust start/stop behavior
- Zero-audio-output analysis mode (engine runs silently)

### Technical Highlights

#### 1) Audio Forking Pipeline (No Tap Conflict)

`AVAudioNode` allows only one tap per bus, so FormantScope avoids tap contention by forking the input path:

```text
Mic Input
   |
   +--> PitchTap (F0 + amplitude)
   |
   +--> Mixer --> RawDataTap (PCM for LPC)
               --> Fader(gain: 0) --> Engine Output (silent)
```

Why this matters:

- stable simultaneous extraction of F0 and F2
- no "multiple tap on same node" instability
- similar frame cadence across both analysis paths

#### 2) LPC-Based F2 Estimation (Speech-Oriented)

F2 is estimated from raw PCM through a formant-focused LPC pipeline:

1. RMS gating (drop near-silence frames)
2. optional pre-emphasis (currently neutral by default)
3. Hamming window
4. downsample by 4 (e.g. 44.1kHz -> 11.025kHz)
5. autocorrelation
6. Levinson-Durbin recursion (LPC order 12)
7. LPC envelope evaluation
8. local-peak picking in speech-relevant bands
9. **F1-aware F2 selection** + temporal constraints (delta limit / hold)

Why this matters:

- better robustness against breath/swallow transients
- fewer false formant jumps
- smoother continuity across short unvoiced segments

#### 3) Practical Stability Logic

- onset confirmation frames before accepting voiced F0
- offset hold frames for short consonant gaps
- sudden F0 jump rejection with multi-frame confirmation
- F2 hold and max-delta constraint to suppress spurious spikes

### Project Structure

```text
FormantScope/
├── FormantScope/
│   ├── FormantScopeApp.swift
│   ├── ContentView.swift
│   ├── AudioAnalyzer.swift
│   ├── Info.plist
│   └── Assets.xcassets/
├── FormantScope.xcodeproj/
├── FormantScopeTests/
├── FormantScopeUITests/
└── AudioKit/               # local dependency package
```

### Tech Stack

- Swift / SwiftUI
- AVFoundation
- Accelerate (vDSP)
- AudioKit + AudioKitEX + SoundpipeAudioKit
- Charts

### Getting Started

#### Requirements

- Xcode 16+
- iOS 17+ / macOS 15+ target in project settings
- Apple Developer account for physical-device testing

#### Run

1. Open `FormantScope.xcodeproj`
2. Select `FormantScope` scheme
3. Run on iOS device/simulator or macOS
4. Grant microphone permission
5. Tap **Start Listening**

### Open Source Quality Plan

- [ ] Improve test coverage for DSP utility functions
- [ ] Add synthetic-signal regression tests for F0/F2 stability
- [ ] Document parameter tuning guide
- [ ] Add CSV export for analysis sessions
- [ ] Add contribution templates and issue labels

### App Store / TestFlight Guide (Practical Checklist)

1. **Bundle & Signing**
   - confirm Bundle ID and Team
   - ensure capabilities and entitlements are correct
2. **Microphone & Privacy**
   - provide clear `NSMicrophoneUsageDescription`
   - complete App Privacy in App Store Connect
3. **Export Compliance**
   - set `ITSAppUsesNonExemptEncryption = NO` (already configured)
4. **Archive & Upload**
   - Product -> Archive -> Distribute App -> App Store Connect
5. **TestFlight Validation**
   - run internal testing rounds first
6. **Submission**
   - fill metadata, screenshots, review notes, support/privacy URLs

### Contributing

Contributions are welcome. If you plan to submit non-trivial changes, please open an issue first to discuss scope and design.

### License

You can choose a license based on your publishing preference (MIT/Apache-2.0 are common for Swift tools).  
If you want, I can generate a recommended `LICENSE` file and contribution templates next.

---

## 简体中文

### 项目简介

FormantScope 是一个基于 SwiftUI 的实时语音分析应用，主要用于显示与跟踪：

- **F0 基频**（fundamental frequency）
- **F2 第二共振峰**（second formant）
- 振幅电平
- 短时历史趋势（双轴折线图）

适用于声乐训练、语音实验和教学演示等低延迟反馈场景。

### 功能特性

- 实时显示 F0 / F2（Hz）
- F0 与 F2 双曲线可视化
- 声态门控与保持逻辑，减少断线和抖动
- iOS / macOS 兼容，并强化了重复启停稳定性
- 静默分析（引擎运行但不外放音频）

### 技术亮点

#### 1）音频分叉管道（避免 Tap 冲突）

由于 `AVAudioNode` 同一 bus 只能安装一个 tap，项目采用“分叉”架构：

```text
麦克风输入
   |
   +--> PitchTap（提取 F0 + 振幅）
   |
   +--> Mixer --> RawDataTap（提供 LPC 原始 PCM）
               --> Fader(gain: 0) --> 输出（静音）
```

这样可以在不冲突的情况下并行提取 F0 与 F2，并保证两条分析链路帧率接近。

#### 2）基于 LPC 的 F2 提取（语音导向）

F2 从原始 PCM 经过以下流程提取：

1. RMS 静音门控
2. 预加重（当前默认近似关闭）
3. Hamming 加窗
4. 4 倍降采样（例如 44.1kHz -> 11.025kHz）
5. 自相关
6. Levinson-Durbin 求解 LPC 系数（12 阶）
7. LPC 谱包络评估
8. 语音频段局部峰值搜索
9. **F1-aware 的 F2 选择** + 时序约束（跳变上限/短时保持）

该方案相比直接频谱峰值法更稳健，能减少咽气、口水音、辅音段导致的误检与突变。

#### 3）工程稳定性策略

- onset 连续确认后再进入有声音高态
- offset 短时保持，跨越清辅音间隙
- F0 大跳变需要多帧确认
- F2 增加跳变上限与保持逻辑，减少毛刺

### 项目结构

```text
FormantScope/
├── FormantScope/
│   ├── FormantScopeApp.swift
│   ├── ContentView.swift
│   ├── AudioAnalyzer.swift
│   ├── Info.plist
│   └── Assets.xcassets/
├── FormantScope.xcodeproj/
├── FormantScopeTests/
├── FormantScopeUITests/
└── AudioKit/（本地依赖）
```

### 快速开始

1. 用 Xcode 打开 `FormantScope.xcodeproj`
2. 选择 `FormantScope` scheme
3. 在模拟器/真机/macOS 运行
4. 授予麦克风权限
5. 点击“开始监听”

### 上架 App Store 指南（简版）

1. 检查 Bundle ID、签名与能力配置
2. 完成麦克风权限文案与隐私声明
3. 确认出口合规键 `ITSAppUsesNonExemptEncryption = NO`
4. Archive 并上传 App Store Connect
5. 先 TestFlight 内测，再提交审核

### 后续建议

- 补充 DSP 回归测试（合成信号）
- 增加会话数据导出（CSV）
- 增加开源协作模板（Issue/PR Template、Code of Conduct）

