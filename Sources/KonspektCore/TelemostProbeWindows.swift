#if os(Windows)
import CWinAudio
import Foundation

extension TelemostProbe {
    /// Process id; the recorder captures the whole process tree of the first one.
    public typealias Source = UInt32

    public static func sample() -> (AudioState, [UInt32]) {
        var sessions = [kw_session](repeating: kw_session(), count: 512)
        let n = Int(kw_list_sessions(&sessions, Int32(sessions.count)))
        var pids: [UInt32] = []
        var main: Set<UInt32> = []
        var input = false, output = false
        for s in sessions.prefix(max(0, n)) {
            guard let path = processPath(s.pid), isTelemostPath(path) else { continue }
            if !pids.contains(s.pid) { pids.append(s.pid) }
            if path.lowercased().hasSuffix("\\yandextelemost.exe") { main.insert(s.pid) }
            if s.active != 0 {
                if s.capture != 0 { input = true } else { output = true }
            }
        }
        // The main executable first: its process tree includes QtWebEngineProcess children.
        pids.sort { main.contains($0) && !main.contains($1) }
        return (AudioState(running: !pids.isEmpty, input: input, output: output), pids)
    }

    private static func processPath(_ pid: UInt32) -> String? {
        var buf = [CChar](repeating: 0, count: 2048)
        guard kw_process_path(pid, &buf, Int32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }
}
#endif
