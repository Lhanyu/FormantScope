//
//  SettingsView.swift
//  VoiceTool
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

    @AppStorage("showF1")  private var showF1:  Bool   = true
    @AppStorage("showF2")  private var showF2:  Bool   = true
    @AppStorage("f0Min")   private var f0Min:   Double = 50
    @AppStorage("f0Max")   private var f0Max:   Double = 600
    @AppStorage("fmtMin")  private var fmtMin:  Double = 200
    @AppStorage("fmtMax")  private var fmtMax:  Double = 3_500

    @State private var f0MinText  = ""
    @State private var f0MaxText  = ""
    @State private var fmtMinText = ""
    @State private var fmtMaxText = ""
    @State private var lastFocusedAxisField: AxisField?
    @FocusState private var focusedAxisField: AxisField?

    private enum AxisField: Hashable {
        case f0Min, f0Max, fmtMin, fmtMax
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
                rangeRow("Min", text: $f0MinText, field: .f0Min, placeholder: "50")
                rangeRow("Max", text: $f0MaxText, field: .f0Max, placeholder: "600")
            } header: {
                Text("Pitch Axis")
            }

            Section {
                rangeRow("Min", text: $fmtMinText, field: .fmtMin, placeholder: "200")
                rangeRow("Max", text: $fmtMaxText, field: .fmtMax, placeholder: "3500")
            } header: {
                Text("Formant Axis – F1 / F2")
            }

            // MARK: 恢复默认
            Section {
                Button(role: .destructive) {
                    showF1 = true;  showF2 = true
                    f0Min  = 50;    f0Max  = 600
                    fmtMin = 200;   fmtMax = 3_500
                    syncAxisTextFields()
                } label: {
                    Text("Reset to Defaults")
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .formStyle(.grouped)
        .textSelection(.enabled)
        .onAppear { syncAxisTextFields() }
        .onChange(of: focusedAxisField) { _, newField in
            if let oldField = lastFocusedAxisField, oldField != newField {
                commitAxisField(oldField)
            }
            lastFocusedAxisField = newField
        }
#if os(macOS)
        .frame(width: 310, height: 390)
#endif
    }

    // MARK: - Helpers

    /// 单行范围输入：默认编辑态；焦点离开或回车时保存。
    @ViewBuilder
    private func rangeRow(_ title: LocalizedStringKey,
                          text: Binding<String>,
                          field: AxisField,
                          placeholder: String) -> some View {
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
            Text("Hz")
                .foregroundStyle(.secondary)
        }
    }

    private func syncAxisTextFields() {
        f0MinText  = formatHz(f0Min)
        f0MaxText  = formatHz(f0Max)
        fmtMinText = formatHz(fmtMin)
        fmtMaxText = formatHz(fmtMax)
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
        }
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
}

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

#Preview {
    SettingsView()
}
