//
//  RecordingFolderPicker.swift
//  FormantScope
//
//  iOS：系统文件夹选取器。macOS：见 SettingsView 内 NSOpenPanel。

#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 用于 `.sheet`；选取后回调 URL（已由系统授权，保存书签前须 `startAccessing` — 回调里处理）。
struct RecordingFolderPicker: UIViewControllerRepresentable {

    typealias UIViewControllerType = UIDocumentPickerViewController

    @Binding var isPresented: Bool
    var onFolderPicked: (URL) -> Void
    var onCancelled: () -> Void = {}

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder], asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: RecordingFolderPicker

        init(_ parent: RecordingFolderPicker) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                parent.isPresented = false
                return
            }
            parent.onFolderPicked(url)
            parent.isPresented = false
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancelled()
            parent.isPresented = false
        }
    }
}
#else
// macOS 使用 NSOpenPanel（见 ContentView、SettingsView）。
#endif
