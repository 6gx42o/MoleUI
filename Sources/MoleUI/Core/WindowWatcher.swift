import AppKit

/// Diagnostic for the "window vanishes but the app keeps running" bug.
///
/// The symptom gives nothing away from outside: process alive, main thread idle,
/// no crash, nothing on stderr. So instead of inferring, record the close at the
/// moment it happens — which window, and the call stack that asked for it. A
/// close initiated by AppKit/SwiftUI internals looks very different from one
/// initiated by a user action or by our own code.
enum WindowWatcher {

    static var logPath: String { DiagnosticsDir.file("window.log") }

    private static var handle: FileHandle?

    static func install() {
        // Truncate per launch so a reproduction isn't buried under old runs.
        FileManager.default.createFile(atPath: logPath, contents: nil)
        handle = FileHandle(forWritingAtPath: logPath)
        log("=== launch pid \(ProcessInfo.processInfo.processIdentifier) ===")

        let center = NotificationCenter.default

        // queue: nil, deliberately. Passing `.main` makes NotificationCenter
        // enqueue the block as an OperationQueue operation, which never runs
        // inline — even when already on the main thread. The stack that
        // initiated the close has unwound by then, so `Thread.callStackSymbols`
        // shows only this observer, which is exactly what it did: the one
        // diagnostic whose entire purpose was naming the caller was reporting
        // itself. nil delivers synchronously on the posting thread.
        center.addObserver(forName: NSWindow.willCloseNotification,
                           object: nil, queue: nil) { note in
            let window = note.object as? NSWindow
            log("WILL CLOSE  \(describe(window))")
            log("  visible windows before close: \(NSApp.windows.filter(\.isVisible).count)")
            log("  call stack:")
            for frame in Thread.callStackSymbols.prefix(24) { log("    \(frame)") }
        }

        center.addObserver(forName: NSWindow.didBecomeKeyNotification,
                           object: nil, queue: .main) { note in
            log("became key  \(describe(note.object as? NSWindow))")
        }

        center.addObserver(forName: NSApplication.didResignActiveNotification,
                           object: nil, queue: .main) { _ in
            log("app resigned active (windows: \(NSApp.windows.count))")
        }

        center.addObserver(forName: NSApplication.didBecomeActiveNotification,
                           object: nil, queue: .main) { _ in
            log("app became active (windows: \(NSApp.windows.count), visible: \(NSApp.windows.filter(\.isVisible).count))")
        }

        // Periodic census. Logged on every change, not just when it hits zero:
        // a window going away *without* a willClose would mean it was released
        // or ordered out rather than closed, which is a different bug entirely.
        var lastCensus = ""
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            let all = NSApp.windows
            let visible = all.filter(\.isVisible)
            let census = "total=\(all.count) visible=\(visible.count)"
            guard census != lastCensus else { return }
            lastCensus = census
            log("CENSUS \(census)")
            for window in all { log("    \(describe(window))") }
        }
    }

    private static func describe(_ window: NSWindow?) -> String {
        guard let window else { return "<nil>" }
        return "[\(type(of: window)) '\(window.title)' "
             + "frame=\(Int(window.frame.origin.x)),\(Int(window.frame.origin.y)) "
             + "\(Int(window.frame.width))x\(Int(window.frame.height)) "
             + "visible=\(window.isVisible) released=\(window.isReleasedWhenClosed)]"
    }

    static func log(_ message: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        guard let data = "\(stamp) \(message)\n".data(using: .utf8) else { return }
        handle?.write(data)
    }
}
