//
//  RecordingFolderStore.swift
//  FormantScope
//
//  一次性选择文件夹 + security-scoped bookmark；后续静默写入该路径。

import Foundation
import SwiftUI

enum RecordingFolderError: LocalizedError {
    case noBookmark
    case staleBookmark
    case accessDenied
    case bookmarkCreateFailed

    var errorDescription: String? {
        switch self {
        case .noBookmark:
            return "No recording folder has been chosen."
        case .staleBookmark:
            return "The saved folder is no longer valid. Please choose again."
        case .accessDenied:
            return "Could not access the recording folder."
        case .bookmarkCreateFailed:
            return "Could not save folder access."
        }
    }
}

/// 持久化书签；录音时由 `AudioAnalyzer` 持有 `startAccessing…` 直至 `endRecording`。
final class RecordingFolderStore: ObservableObject {

    static let shared = RecordingFolderStore()

    private static let defaultsKey = "formantscope.recordingFolderBookmark"

    /// 是否已保存过用户选择的文件夹书签（不代表本次进程内正在访问）。
    @Published private(set) var hasBookmark: Bool

    private init() {
        hasBookmark = UserDefaults.standard.data(forKey: Self.defaultsKey) != nil
    }

    /// 在已获得权限的 URL 上创建书签（需在 `startAccessingSecurityScopedResource` 之后于 iOS 选用结果上调用）。
    func saveBookmark(for url: URL) throws {
        let started = url.startAccessingSecurityScopedResource()
        defer {
            if started { url.stopAccessingSecurityScopedResource() }
        }
        guard started else { throw RecordingFolderError.accessDenied }
#if os(macOS)
        let creationOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
#else
        let creationOptions: URL.BookmarkCreationOptions = []
#endif
        let data = try url.bookmarkData(
            options: creationOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        hasBookmark = true
    }

    func clearBookmark() {
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        hasBookmark = false
    }

    /// 解析书签并开始 **security-scoped** 访问；调用方必须在结束时对返回的 URL 调用 `stopAccessingSecurityScopedResource()`。
    func resolveAndStartAccess() throws -> URL {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey) else {
            throw RecordingFolderError.noBookmark
        }
        var stale = false
#if os(macOS)
        let resolveOptions: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
#else
        let resolveOptions: URL.BookmarkResolutionOptions = [.withoutUI]
#endif
        let url = try URL(
            resolvingBookmarkData: data,
            options: resolveOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        if stale {
            throw RecordingFolderError.staleBookmark
        }
        guard url.startAccessingSecurityScopedResource() else {
            throw RecordingFolderError.accessDenied
        }
        return url
    }

    static func makeFileName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "formantscope-\(formatter.string(from: Date())).wav"
    }
}
