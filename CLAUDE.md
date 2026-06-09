# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

FormantScope — a SwiftUI app (iOS 17+ / macOS 14+) that captures live microphone
input and shows real-time speech acoustics: F0 (pitch), F1/F2 (formants), and an
amplitude level, with a rolling ~100-frame history chart.

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
  `f0Max`, `fmtMin`, `fmtMax`) and their defaults are duplicated between
  `ContentView` and `SettingsView` — if you change a default, change both.
- DSP uses Accelerate (vDSP) where it matters; keep hot paths off naive loops.

## Gotchas / known sharp edges

- **stderr filter** (`FormantScopeApp.swift`): redirects STDERR through a pipe at
  launch to drop CoreAudio/XPC noise. It currently runs in all builds and is a bit
  fragile (treats any read error as EOF, no `#if DEBUG` gate). If you touch it, be
  careful not to swallow crash backtraces; prefer gating to DEBUG.
- **Security-scoped recording folder**: the caller (`AudioAnalyzer`) must balance
  `startAccessingSecurityScopedResource` (in `beginRecording…`) with `stop` (in
  `endRecording`). If recording errors out, make sure access is still released.
- **Chart coordinate mapping** (`ContentView` `BackgroundVoiceChart`): the chart's
  Y domain is dynamically expanded so normalized [0,1] aligns to the foreground
  card frame reported via `PreferenceKey`. The `yDomain` guards degenerate frames —
  keep those guards if you edit the math.
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
