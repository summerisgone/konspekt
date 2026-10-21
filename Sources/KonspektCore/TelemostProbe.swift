#if os(macOS)
import CoreAudio
import Darwin
#endif
import Foundation

public enum TelemostProbe {
    /// macOS: anything inside Yandex.Telemost.app.
    /// Windows: C:\Program Files\Yandex\YandexTelemost\YandexTelemost.exe and its QtWebEngineProcess.exe.
    public static func isTelemostPath(_ p: String) -> Bool {
        p.contains("Yandex.Telemost.app") || p.lowercased().contains("\\yandextelemost\\")
    }
}

#if os(macOS)
extension TelemostProbe {
    public typealias Source = AudioObjectID

    public static func sample() -> (AudioState, [AudioObjectID]) {
        var objs: [AudioObjectID] = []
        var input = false, output = false
        for obj in processObjects() {
            guard let pid: pid_t = get(obj, kAudioProcessPropertyPID),
                  let path = pidPath(pid), isTelemostPath(path) else { continue }
            objs.append(obj)
            if (get(obj, kAudioProcessPropertyIsRunningInput) as UInt32?) ?? 0 != 0 { input = true }
            if (get(obj, kAudioProcessPropertyIsRunningOutput) as UInt32?) ?? 0 != 0 { output = true }
        }
        return (AudioState(running: !objs.isEmpty, input: input, output: output), objs)
    }

    private static func processObjects() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &list) == noErr else { return [] }
        return list
    }

    private static func get<T: FixedWidthInteger>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> T? {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var v: T = 0
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v) == noErr ? v : nil
    }

    private static func pidPath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, 4096) > 0 else { return nil }
        return String(cString: buf)
    }
}
#endif
