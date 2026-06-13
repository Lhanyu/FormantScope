//
//  SettingsView.swift
//  FormantScope
//
//  Created by Hanyu on 2026/4/27.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

/// 跨平台设置面板。
/// macOS：嵌入 Settings scene（Cmd+,）。
/// iOS：作为 sheet 从主界面弹出。
struct SettingsView: View {

    @ObservedObject private var folderStore = RecordingFolderStore.shared
#if os(iOS)
    @State private var showRecordingFolderPicker = false
#endif
    @State private var showResetRecordingFolderConfirm = false

    @AppStorage("showF1")  private var showF1:  Bool   = true
    @AppStorage("showF2")  private var showF2:  Bool   = true
    @AppStorage("f0Min")   private var f0Min:   Double = 50
    @AppStorage("f0Max")   private var f0Max:   Double = 600
    @AppStorage("fmtMin")  private var fmtMin:  Double = 200
    @AppStorage("fmtMax")  private var fmtMax:  Double = 3_500
    @AppStorage("timeWindowSec") private var timeWindowSec: Double = 8

    @State private var f0MinText  = ""
    @State private var f0MaxText  = ""
    @State private var fmtMinText = ""
    @State private var fmtMaxText = ""
    @State private var timeWindowText = ""
    @State private var lastFocusedAxisField: AxisField?
    @FocusState private var focusedAxisField: AxisField?

    private enum AxisField: Hashable {
        case f0Min, f0Max, fmtMin, fmtMax, timeWindow
    }

    private enum AppLinks {
        static let sourceRepository = URL(string: "https://github.com/Lhanyu/FormantScope")!
    }

    var body: some View {
        Form {
            // MARK: 显示开关
            Section {
                Toggle("Show F1 Formant", isOn: $showF1)
                Toggle("Show F2 Formant", isOn: $showF2)
            } header: {
                Text("Display")
            }

            Section {
                if folderStore.hasBookmark {
                    Label("Recording folder saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Choose a folder for FormantScope WAV recordings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
#if os(macOS)
                Button("Choose recording folder…") {
                    chooseRecordingFolderMac()
                }
#elseif os(iOS)
                Button("Choose recording folder…") {
                    showRecordingFolderPicker = true
                }
#endif
                Button("Reset recording folder", role: .destructive) {
                    showResetRecordingFolderConfirm = true
                }
                .disabled(!folderStore.hasBookmark)
            } header: {
                Text("Recordings")
            }

            Section {
                rangeRow("Min", text: $f0MinText, field: .f0Min, placeholder: "50")
                rangeRow("Max", text: $f0MaxText, field: .f0Max, placeholder: "600")
            } header: {
                Text("Pitch Axis – F0")
            }

            Section {
                rangeRow("Min", text: $fmtMinText, field: .fmtMin, placeholder: "200")
                rangeRow("Max", text: $fmtMaxText, field: .fmtMax, placeholder: "3500")
            } header: {
                Text("Formant Axis – F1 / F2")
            }

            Section {
                rangeRow("Window", text: $timeWindowText, field: .timeWindow, placeholder: "8", unit: "s")
            } header: {
                Text("Time Window")
            } footer: {
                Text("History shown and averaged (2–20 s).")
            }

            // MARK: 恢复默认
            Section {
                Button(role: .destructive) {
                    showF1 = true;  showF2 = true
                    f0Min  = 50;    f0Max  = 600
                    fmtMin = 200;   fmtMax = 3_500
                    timeWindowSec = 8
                    syncAxisTextFields()
                } label: {
                    Text("Reset to Defaults")
                        .frame(maxWidth: .infinity)
                }
            }

            Section {
                Link(destination: AppLinks.sourceRepository) {
                    Label("FormantScope on GitHub", systemImage: "link")
                }
            } header: {
                Text("About")
            }
        }
        .formStyle(.grouped)
#if os(iOS)
        // decimalPad 没有 return 键，仅靠焦点切换提交会漏掉当前框，故补三条收起/提交入口：
        // 点空白收起（KeyboardDismissAttacher）、拖列表收起（interactively）、sheet 关闭兜底（onDisappear）。
        .background(KeyboardDismissAttacher())
        .scrollDismissesKeyboard(.interactively)
        .onDisappear { commitAllAxisFields() }
#endif
#if os(macOS)
        // 点空白处失焦 → 触发 AxisTextField 提交，体验与 iOS 一致。详见 ClickToResignAttacher。
        .background(ClickToResignAttacher())
#endif
        .confirmationDialog(
            "Reset saved recording folder?",
            isPresented: $showResetRecordingFolderConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) { folderStore.clearBookmark() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Next time you record, you will be asked to choose a folder again.")
        }
        .textSelection(.enabled)
        .onAppear { syncAxisTextFields() }
        .onChange(of: focusedAxisField) { _, newField in
            if let oldField = lastFocusedAxisField, oldField != newField {
                commitAxisField(oldField)
            }
            lastFocusedAxisField = newField
        }
#if os(iOS)
        .sheet(isPresented: $showRecordingFolderPicker) {
            RecordingFolderPicker(
                isPresented: $showRecordingFolderPicker,
                onFolderPicked: { url in
                    try? folderStore.saveBookmark(for: url)
                }
            )
        }
#endif
#if os(macOS)
        .frame(width: 310, height: 620)
#endif
    }

    // MARK: - Helpers

    /// 单行范围输入：默认编辑态；焦点离开或回车时保存。
    @ViewBuilder
    private func rangeRow(_ title: LocalizedStringKey,
                          text: Binding<String>,
                          field: AxisField,
                          placeholder: String,
                          unit: LocalizedStringKey = "Hz") -> some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer()
#if os(macOS)
            AxisTextField(text: text, placeholder: placeholder) {
                commitAxisField(field)
            }
                .frame(width: 80)
#else
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
                .focused($focusedAxisField, equals: field)
                .onSubmit { commitAxisField(field) }
                .keyboardType(.decimalPad)
                .frame(width: 100)
#endif
            Text(unit)
                .foregroundStyle(.secondary)
        }
    }

    private func syncAxisTextFields() {
        f0MinText  = formatHz(f0Min)
        f0MaxText  = formatHz(f0Max)
        fmtMinText = formatHz(fmtMin)
        fmtMaxText = formatHz(fmtMax)
        timeWindowText = formatHz(timeWindowSec)
    }

    private func commitAxisField(_ field: AxisField) {
        switch field {
        case .f0Min:
            commit($f0MinText, to: &f0Min, isValid: { $0 < f0Max })
        case .f0Max:
            commit($f0MaxText, to: &f0Max, isValid: { $0 > f0Min })
        case .fmtMin:
            commit($fmtMinText, to: &fmtMin, isValid: { $0 < fmtMax })
        case .fmtMax:
            commit($fmtMaxText, to: &fmtMax, isValid: { $0 > fmtMin })
        case .timeWindow:
            commit($timeWindowText, to: &timeWindowSec, isValid: { $0 >= 2 && $0 <= 20 })
        }
    }

    /// 逐个 re-parse 提交所有轴输入框（幂等）。sheet 关闭兜底，确保当前框也落盘。
    private func commitAllAxisFields() {
        commitAxisField(.f0Min)
        commitAxisField(.f0Max)
        commitAxisField(.fmtMin)
        commitAxisField(.fmtMax)
        commitAxisField(.timeWindow)
    }

    private func commit(_ text: Binding<String>,
                        to value: inout Double,
                        isValid: (Double) -> Bool) {
        let raw = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let next = Double(raw), next > 0, isValid(next) {
            value = next
            text.wrappedValue = formatHz(next)
        } else {
            text.wrappedValue = formatHz(value)
        }
    }

    private func formatHz(_ value: Double) -> String {
        value.rounded() == value ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

#if os(macOS)
    private func chooseRecordingFolderMac() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose a folder for FormantScope recordings")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? folderStore.saveBookmark(for: url)
    }
#endif
}

#if os(macOS)
/// 点设置窗口空白处让输入框失焦（→ 触发 AxisTextField 的 controlTextDidEndEditing 提交）。
///
/// 用本地事件监听而非手势识别器：手势天生与鼠标事件竞争，会延迟/拦截点击导致输入框
/// 光标不出、按钮点不动。事件监听的 handler 原样返回 event 不拦截，点击照常派发，仅在
/// 派发前判断落点——命中空白才让当前 field resign。零事件竞争。
private struct ClickToResignAttacher: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coord = context.coordinator
        coord.monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak coord] event in
            guard let coord, let window = event.window, window === coord.view?.window,
                  let content = window.contentView else { return event }
            let pt = content.convert(event.locationInWindow, from: nil)
            var hit = content.hitTest(pt)
            while let v = hit {
                // 命中输入框/任意控件：交给控件自己处理（放光标、点按钮），不动焦点。
                if v is NSControl || v is NSText { return event }
                hit = v.superview
            }
            // 空白处：让当前编辑框 resign（触发提交），但仍把事件原样放行。
            window.makeFirstResponder(nil)
            return event
        }
        coord.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let m = coordinator.monitor {
            NSEvent.removeMonitor(m)
            coordinator.monitor = nil
        }
    }

    final class Coordinator {
        weak var view: NSView?
        var monitor: Any?
    }
}
#endif

#if os(macOS)
/// AppKit-backed text field used inside macOS Form.
/// SwiftUI's TextField can render an extra value label in grouped Form rows;
/// this wrapper keeps the native input field while avoiding that duplicate.
private struct AxisTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onCommit: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField(string: text)
        textField.placeholderString = placeholder
        textField.alignment = .right
        textField.bezelStyle = .roundedBezel
        textField.delegate = context.coordinator
        textField.target = context.coordinator
        textField.action = #selector(Coordinator.commit)
        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.placeholderString = placeholder
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommit: onCommit)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding private var text: String
        private let onCommit: () -> Void

        init(text: Binding<String>, onCommit: @escaping () -> Void) {
            _text = text
            self.onCommit = onCommit
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            text = textField.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            text = textField.stringValue
            onCommit()
        }

        @objc func commit(_ sender: NSTextField) {
            text = sender.stringValue
            onCommit()
        }
    }
}
#endif

#if os(iOS)
import UIKit

/// 在所属 window 上挂一个"点击空白收键盘"的手势桥。
///
/// 为什么不用 SwiftUI 的 `.onTapGesture`：Form 底层是可滚动 List，在其上加全局
/// tap 会与滚动手势、TextField 命中测试相互仲裁，造成卡顿与"二次聚焦失败"。
/// 挂到 window 的 `UITapGestureRecognizer` 设 `cancelsTouchesInView = false` 不吞触摸
/// 且永远识别；是否收键盘改在响应时按落点 hitTest 判定（见 Coordinator.dismiss），
/// 命中输入控件不收，避免与聚焦抢占。收键盘后 `@FocusState` 归 nil，触发既有 onChange 提交。
private struct KeyboardDismissAttacher: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        DispatchQueue.main.async {
            guard let window = view.window,
                  context.coordinator.tap == nil else { return }
            let tap = UITapGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.dismiss))
            tap.cancelsTouchesInView = false
            tap.requiresExclusiveTouchType = false
            tap.delegate = context.coordinator
            window.addGestureRecognizer(tap)
            context.coordinator.tap = tap
            context.coordinator.installedOn = window
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    /// 设置页消失时把挂在 window 上的 tap 手势摘掉，避免反复开关设置页时
    /// 手势在 window 上越堆越多。
    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        if let tap = coordinator.tap {
            coordinator.installedOn?.removeGestureRecognizer(tap)
            coordinator.tap = nil
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var installedOn: UIWindow?
        weak var tap: UITapGestureRecognizer?

        // 手势永远识别、永不吞触摸；是否收键盘在响应时用命中测试判定，避免竞态。
        // 不在 shouldReceive 里按 touch.view 的 superview 链过滤：SwiftUI Form/List 里
        // touch.view 多是 cell/内部视图，真正的 UITextField 在其子/兄弟层向上找不到，
        // 过滤会失效并与正在建立的 first responder 抢占。改在落点 hitTest 取最深视图，
        // 命中输入控件就不收键盘。
        @objc func dismiss(_ sender: UITapGestureRecognizer) {
            guard let window = sender.view as? UIWindow else { return }
            let pt = sender.location(in: window)
            let hit = window.hitTest(pt, with: nil)
            var v = hit
            while let cur = v {
                if cur is UITextField || cur is UITextView { return }
                v = cur.superview
            }
            window.endEditing(true)
        }

        // 与其它手势并存，绝不抢占，避免影响滚动 / 控件点击。
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
#endif

#Preview {
    SettingsView()
}
