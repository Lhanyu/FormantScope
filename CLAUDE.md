# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

FormantScope — a SwiftUI app (iOS 17+ / macOS 14+) that captures live microphone
input and shows real-time speech acoustics: F0 (pitch), F1/F2 (formants), and an
amplitude level, plotted on a rolling, time-windowed history chart (default 8 s,
adjustable 2–20 s) with a per-readout window average.

- Bundle id: `com.yueranwang.formantscope`
- Single shared target `FormantScope` builds for both iOS and macOS.
- Swift 5, no third-party code checked in — dependencies come via SPM.

## Build, run, test

There is no Makefile or CLI wrapper; use `xcodebuild` with the shared scheme.

```bash
# Build for macOS
xcodebuild -scheme FormantScope -destination 'platform=macOS' build

# Build for an iOS simulator (adjust device name as available)
xcodebuild -scheme FormantScope -destination 'platform=iOS Simulator,name=iPhone 16' build

# Or, without pinning a device, target any installed iOS simulator runtime
xcodebuild -scheme FormantScope -destination 'generic/platform=iOS Simulator' build

# Run unit + UI tests (pick a destination that exists on the machine)
xcodebuild -scheme FormantScope -destination 'platform=macOS' test
```

- Always pass `-scheme FormantScope`; the scheme is shared (in `xcshareddata`).
- **Build BOTH platforms after changing shared code.** Much logic lives behind
  `#if os(iOS)` / `#if os(macOS)`; a macOS-only build silently skips the iOS
  branch (and vice versa), so a "green" build can still hide a broken platform.
- Prefer building/destination-checking with whatever simulator is installed; don't
  assume a specific iOS version is present.
- The repo's own `DerivedData/` is gitignored. Don't commit build output.
- If an iOS build fails in `actool` with "could not find a suitable device" /
  "liblaunch_sim.dylib could not be opened", that's a broken simulator runtime,
  not a code/asset bug — check `xcrun simctl list runtimes` for `Unusable`
  duplicates, delete them, and `xcodebuild -downloadPlatform iOS` to reinstall.

## Dependencies (SPM, pinned in Package.resolved)

SoundpipeAudioKit pulls in AudioKit, AudioKitEX, KissFFT, Tonic. Versions are
pinned in `FormantScope.xcodeproj/.../Package.resolved` — keep that file committed
so versions are reproducible. Don't bump audio dependencies casually; the audio
graph relies on AudioKitEX tap behavior.

## Architecture

Six source files in `FormantScope/`:

| File | Role |
|------|------|
| `FormantScopeApp.swift` | App entry, macOS menu commands, stderr noise filter |
| `ContentView.swift` | All UI: full-screen chart, readouts, amplitude bar, controls |
| `AudioAnalyzer.swift` | Audio engine, taps, LPC DSP, WAV recording (the core) |
| `SettingsView.swift` | Cross-platform settings (display toggles, axis ranges, folder) |
| `RecordingFolderStore.swift` | Security-scoped bookmark persistence |
| `RecordingFolderPicker.swift` | iOS folder picker (macOS uses NSOpenPanel) |

### Audio graph (the load-bearing design)

Only one tap may attach per `AVAudioNode` bus, so taps are forked:

```
Mic ──► PitchTap (F0 + amplitude, callback on main)
 └──► innerMixer ──► RawDataTap (PCM → LPC → F1/F2, on lpcQueue)
            └──► recordMixer ──► AVAudioEngine tap (WAV, recordIOQueue)
                       └──► Fader(gain 0) ──► engine.output (silent)
```

- On **iOS** the graph is built lazily in `start()` (after the AVAudioSession is
  active) because input format is invalid before activation. On **macOS** it's
  built in `init()`. Keep this split.
- F0 = AudioKitEX PitchTap (AUBIO). F1/F2 = custom LPC in `processLPC`.

### Timestamped history model

History is **not** a fixed-length frame array. Each curve (`pitchHistory`,
`f1History`, `f2History`) is `[TimedSample]` where `t` comes from a **session
logical clock** = monotonic `systemUptime` − accumulated paused duration. The
clock does not advance while stopped, so after stop→start the first new sample
abuts the last old one and the curve continues seamlessly (no left-shift / no
slope across the pause). `historyRetainSeconds` (30 s) bounds memory; the chart
renders a real-time window (`timeWindowSec`) so spans are identical across
devices regardless of sample rate. Don't reintroduce frame-index history.

### Input route / configuration changes

`AudioAnalyzer` observes `AVAudioEngineConfigurationChange` (input-source switch,
sample-rate/channel change, device plug/unplug). On that event it calls `stop()`
and bumps `autoStopSignal`; `ContentView` watches that counter and resets the UI
to idle (button → Start, recording disarmed). The frozen curve stays put because
history isn't cleared. This is the only sanctioned reaction to a route change —
don't try to hot-rebuild the graph in place (that's what caused the earlier
"freezes for a beat, then misbehaves" symptom with AirPods).

### Threading model — respect it

- PitchTap callback runs on **main**; it writes `@Published` pitch/amplitude/history directly.
- LPC runs on `lpcQueue`; results are pushed to main via `publishF1`/`publishF2`.
- Recording file I/O is confined to `recordIOQueue`.
- `currentPitchSnapshot` / `amplitudeSnapshot` cross main→lpcQueue (Float, treated
  as atomic enough for display). When touching these, don't assume locks exist.
- **Any new `@Published` mutation must happen on main.** Wrap in `DispatchQueue.main.async` if you're on a tap/background queue.

## Conventions

- Comments are in **Chinese**, code identifiers in English. Match this style.
- Comments explain *why* (DSP parameter choices, platform differences, smoothing
  rationale), not *what*. The existing comments are detailed and worth preserving
  when you refactor nearby code — don't strip them.
- Platform differences use `#if os(iOS)` / `#if os(macOS)` inline. Several tuning
  constants differ by platform (amplitude gates, RMS threshold, audio session).
- Persisted user settings use `@AppStorage`. Keys (`showF1`, `showF2`, `f0Min`,
  `f0Max`, `fmtMin`, `fmtMax`, `timeWindowSec`) and their defaults are duplicated
  between `ContentView` and `SettingsView` — if you change a default, change both.
- DSP uses Accelerate (vDSP) where it matters; keep hot paths off naive loops.

## Gotchas / known sharp edges

- **stderr filter** (`FormantScopeApp.swift`): redirects STDERR through a pipe at
  launch to drop CoreAudio/XPC noise. It currently runs in all builds and is a bit
  fragile (treats any read error as EOF, no `#if DEBUG` gate). If you touch it, be
  careful not to swallow crash backtraces; prefer gating to DEBUG.
- **Security-scoped recording folder**: the caller (`AudioAnalyzer`) must balance
  `startAccessingSecurityScopedResource` (in `beginRecording…`) with `stop` (in
  `endRecording`). If recording errors out, make sure access is still released.
- **Record tap must use `format: nil`** (`installRecordTapOnQueue`): Bluetooth
  input (AirPods) drops to HFP and the hardware sample rate falls (e.g. 16 kHz)
  while `recordMixer` still reports 48 kHz. Passing an explicit 48 kHz format to
  `installTap` fails the engine's `format.sampleRate == inputHWFormat.sampleRate`
  assertion and throws an NSException (swallowed on main = "frozen"; on a
  background queue = process kill). `nil` skips that check, matching
  PitchTap/RawDataTap. The WAV file is therefore created **lazily** from the first
  buffer's real format in `appendRecordingBuffer`, not pre-built. The record tap
  is **resident** (installed on first record, never `removeTap`'d); idle buffers
  are dropped by the `recordingFile == nil` guard. Don't install/remove the record
  tap inside `start()`/`stop()`.
- **AirPods gate sustained tones** (not an app bug): HFP firmware VAD + noise
  suppression treats a stationary tone as background noise and gates it after
  ~1–2 s, so a held vowel's F0/F1/F2 curve drops out. Happens in every app; the
  config is already optimal (`.measurement`, no VoiceProcessingIO). Only fix is a
  full-bandwidth mic (built-in / wired). Left as-is by user decision.
- **Chart coordinate mapping** (`ContentView` `BackgroundVoiceChart`): the chart's
  Y domain is dynamically expanded so normalized [0,1] aligns to the foreground
  card frame reported via `PreferenceKey`. The `yDomain` guards degenerate frames —
  keep those guards if you edit the math. Axis ticks come from a "nice numbers"
  (1‑2‑5×10ⁿ) algorithm that forces the range endpoints; the X axis shows the
  time window (gridlines + overlay labels, `now` at the right). Don't revert to
  hardcoded tick tables or hide the X axis.
- **Recording-folder error flow** (`ContentView`): re-auth (re-show picker) should
  only happen for `RecordingFolderError`, not for `RecordingError` (engine/format
  problems) — otherwise a non-folder failure can loop the picker.
- Microphone usage strings live in `InfoPlist.xcstrings`; entitlements
  (sandbox, mic, user-selected files) in `FormantScope.entitlements`.

## When making changes

- Audio/DSP changes can't be validated by unit tests here (tests are skeletal).
  Build, then verify behavior by running the app with a real mic when feasible; if
  you can't run it, say so rather than claiming the audio path works.
- Keep edits scoped — this is a focused app, not a framework. Don't add
  abstractions or config for hypothetical future needs.
- Don't commit unless asked. Don't touch `git config`, `DerivedData/`, or the
  pinned `Package.resolved` without reason.
