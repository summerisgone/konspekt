#if os(Windows)
import Foundation

/// Names shared by the daemon and KonspektTray.
public enum DaemonControl {
    /// Held by a running daemon; its existence means "running".
    public static let mutexName = "Local\\KonspektDaemon"
    /// Set to ask the daemon to finish the current call and exit.
    public static let stopEventName = "Local\\KonspektDaemonStop"

    /// %LOCALAPPDATA%\Konspekt\konspekt.log
    public static var logFile: URL {
        let base = ProcessInfo.processInfo.environment["LOCALAPPDATA"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AppData/Local")
        return base.appendingPathComponent("Konspekt").appendingPathComponent("konspekt.log")
    }
}
#endif
