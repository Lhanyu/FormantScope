//
//  FormantScopeApp.swift
//  FormantScope
//
//  Created by Hanyu on 2026/4/25.
//

import SwiftUI

@main
struct FormantScopeApp: App {
    init() {
        suppressCoreAudioXPCNoise()
    }

    var body: some Scene {
#if os(macOS)
        WindowGroup {
            ContentView()
                .frame(minWidth: 360, minHeight: 420)
        }
        .defaultSize(width: 420, height: 660)
        .commands { DisplayCommands() }

        Settings {
            SettingsView()
        }
#else
        WindowGroup {
            ContentView()
        }
#endif
    }
}

// MARK: - macOS 菜单命令

#if os(macOS)
/// 在 View 菜单末尾追加 F1/F2 显示开关，带快捷键。
private struct DisplayCommands: Commands {
    @AppStorage("showF1") var showF1: Bool = true
    @AppStorage("showF2") var showF2: Bool = true

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Toggle("Show F1 Formant", isOn: $showF1)
                .keyboardShortcut("1", modifiers: [.command, .option])
            Toggle("Show F2 Formant", isOn: $showF2)
                .keyboardShortcut("2", modifiers: [.command, .option])
        }
    }
}
#endif

// MARK: - stderr 噪声过滤

/// CoreAudio / XPC 产生的 NSXPCDecoder 警告走 NSLog → stderr（*** 开头），
/// 无法通过 OS_ACTIVITY_DT_MODE 抑制。此函数将 stderr 接入过滤管道：
/// 含噪声关键词的行直接丢弃，其余行写回原始 stderr，print() 走 stdout 完全不受影响。
///
/// 注意：AudioEngine start/stop 时产生的 os_log 走统一日志系统，不经过 stderr，
/// 需在 Xcode scheme → Run → Arguments → Environment Variables 中加入：
///   OS_ACTIVITY_MODE = disable
/// 来抑制 Xcode 控制台里的 os_log 洪流，这里的管道对其无效。
private func suppressCoreAudioXPCNoise() {
    // 保存原始 stderr 文件描述符
    let origFd = dup(STDERR_FILENO)
    guard origFd >= 0 else { return }

    var pipefd: [Int32] = [-1, -1]
    guard pipe(&pipefd) == 0 else { close(origFd); return }

    // 把 stderr 重定向到管道写端
    dup2(pipefd[1], STDERR_FILENO)
    close(pipefd[1])

    let readFd = pipefd[0]

    // 后台线程：从管道读端逐行过滤，非噪声行写回原始 stderr
    Thread.detachNewThread {
        let origOut = FileHandle(fileDescriptor: origFd, closeOnDealloc: true)
        var chunk   = [UInt8](repeating: 0, count: 4_096)
        var pending = Data()

        while true {
            let n = read(readFd, &chunk, chunk.count)
            guard n > 0 else { break }
            pending.append(contentsOf: chunk[..<n])

            // 逐行处理（保留不以换行结尾的末尾碎片留到下次）
            while let nl = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let end      = pending.index(after: nl)
                let lineData = Data(pending[pending.startIndex ..< end])
                let line     = String(bytes: lineData, encoding: .utf8) ?? ""

                let trimmed  = line.trimmingCharacters(in: .whitespacesAndNewlines)
                let isNoise  = trimmed.isEmpty                                // 空行
                            || trimmed == "{("                                 // XPC 数组括号
                            || trimmed == ")}"
                            || line.contains("NSXPCDecoder")
                            || line.contains("NSSecureCoding")
                            || line.contains("bad range for [%{public}@]")
                            || line.contains("Allowed class list")
                            || line.contains("'NSObject'")
                if !isNoise { origOut.write(lineData) }

                pending.removeSubrange(pending.startIndex ..< end)
            }
        }

        // 写出残余未换行内容
        if !pending.isEmpty { origOut.write(pending) }
        close(readFd)
    }
}
