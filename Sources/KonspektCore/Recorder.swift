#if os(macOS)
import AVFoundation
import CoreAudio
import Foundation

public enum RecorderError: Error {
    case coreAudio(String, OSStatus)
}

public final class Recorder {
    private let queue = DispatchQueue(label: "konspekt.recorder.write")
    private let lock = NSLock()
    private var micGate = true
    private var callFile: AVAudioFile?
    private var micFile: AVAudioFile?
    private var engine: AVAudioEngine?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    public init() {}

    public func start(session: Session, processObjects: [AudioObjectID]) throws {
        guard #available(macOS 14.2, *) else { throw RecorderError.coreAudio("requires macOS 14.2", -1) }
        stop()
        let desc = CATapDescription(stereoMixdownOfProcesses: processObjects)
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted
        desc.isPrivate = true
        var st = AudioHardwareCreateProcessTap(desc, &tapID)
        guard st == noErr else { tapID = AudioObjectID(kAudioObjectUnknown); throw RecorderError.coreAudio("CreateProcessTap", st) }
        do {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            st = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
            guard st == noErr else { throw RecorderError.coreAudio("TapFormat", st) }
            guard let fmt = AVAudioFormat(streamDescription: &asbd) else { throw RecorderError.coreAudio("TapFormat", -1) }

            let aggDesc: [String: Any] = [
                kAudioAggregateDeviceNameKey: "KonspektTap",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: desc.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]],
            ]
            st = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
            guard st == noErr else { aggID = AudioObjectID(kAudioObjectUnknown); throw RecorderError.coreAudio("CreateAggregateDevice", st) }

            let file = try AVAudioFile(forWriting: session.callURL, settings: fmt.settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: fmt.isInterleaved)
            lock.lock(); callFile = file; lock.unlock()

            st = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { [weak self] _, inData, _, _, _ in
                guard let self,
                      let src = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: inData, deallocator: nil),
                      let copy = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: src.frameLength) else { return }
                copy.frameLength = src.frameLength
                let s = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
                let d = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
                for i in 0..<min(s.count, d.count) {
                    if let sp = s[i].mData, let dp = d[i].mData {
                        memcpy(dp, sp, Int(min(s[i].mDataByteSize, d[i].mDataByteSize)))
                    }
                }
                self.queue.async {
                    self.lock.lock(); let f = self.callFile; self.lock.unlock()
                    try? f?.write(from: copy)
                }
            }
            guard st == noErr else { procID = nil; throw RecorderError.coreAudio("CreateIOProc", st) }
            st = AudioDeviceStart(aggID, procID)
            guard st == noErr else { throw RecorderError.coreAudio("DeviceStart", st) }
        } catch {
            stop()
            throw error
        }
        startMic(url: session.micURL)
    }

    private func startMic(url: URL) {
        do {
            let eng = AVAudioEngine()
            let input = eng.inputNode
            let fmt = input.outputFormat(forBus: 0)
            let file = try AVAudioFile(forWriting: url, settings: fmt.settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: fmt.isInterleaved)
            lock.lock(); micFile = file; lock.unlock()
            input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, _ in
                guard let self,
                      let copy = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: buf.frameLength) else { return }
                copy.frameLength = buf.frameLength
                self.lock.lock(); let open = self.micGate; self.lock.unlock()
                let s = UnsafeMutableAudioBufferListPointer(buf.mutableAudioBufferList)
                let d = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
                for i in 0..<min(s.count, d.count) {
                    guard let dp = d[i].mData else { continue }
                    let n = Int(min(s[i].mDataByteSize, d[i].mDataByteSize))
                    if open, let sp = s[i].mData { memcpy(dp, sp, n) } else { memset(dp, 0, n) }
                }
                self.queue.async {
                    self.lock.lock(); let f = self.micFile; self.lock.unlock()
                    try? f?.write(from: copy)
                }
            }
            try eng.start()
            engine = eng
        } catch {
            FileHandle.standardError.write(Data("mic start failed: \(error)\n".utf8))
            engine?.inputNode.removeTap(onBus: 0)
            engine = nil
            lock.lock(); micFile = nil; lock.unlock()
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func stop() {
        if let e = engine {
            e.inputNode.removeTap(onBus: 0)
            e.stop()
            engine = nil
        }
        if aggID != kAudioObjectUnknown {
            if let p = procID {
                AudioDeviceStop(aggID, p)
                AudioDeviceDestroyIOProcID(aggID, p)
            }
            AudioHardwareDestroyAggregateDevice(aggID)
        }
        procID = nil
        aggID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown, #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        queue.sync {}
        lock.lock(); callFile = nil; micFile = nil; lock.unlock()
    }

    public func setMicGate(open: Bool) {
        lock.lock(); micGate = open; lock.unlock()
    }
}
#endif
