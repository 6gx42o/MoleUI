import Foundation

/// Where the diagnostic commands write their reports.
///
/// `~/Library/Logs/MoleUI/`, not the project directory — build output and source
/// should not be littered with runtime artifacts, and Console.app picks up
/// anything under Library/Logs for free.
enum DiagnosticsDir {
    static func file(_ name: String) -> String {
        let dir = NSHomeDirectory() + "/Library/Logs/MoleUI"
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)
        return dir + "/" + name
    }
}
