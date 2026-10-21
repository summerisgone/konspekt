import Foundation
import KonspektCore
#if os(Windows)
import WinSDK
#endif

func log(_ msg: String) {
    print("\(ISO8601DateFormatter().string(from: Date())) \(msg)")
    fflush(stdout)
}

/// Serializes pipeline runs in-process; flock guards across processes.
actor Processor {
    let pipeline: Pipeline
    init(config: Config) {
        let api = APIClient.live(config: config)
        pipeline = Pipeline(transcriber: api, summarizer: api)
    }

    func run(_ s: Session) async -> SessionStatus? {
        let lockPath = s.dir.appendingPathComponent("processing.lock").path
        #if os(Windows)
        // A file opened without sharing is the cross-process lock; the handle closes on return.
        let h = lockPath.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, GENERIC_READ | DWORD(GENERIC_WRITE), 0, nil, DWORD(OPEN_ALWAYS), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        }
        guard h != INVALID_HANDLE_VALUE else {
            if GetLastError() == DWORD(ERROR_SHARING_VIOLATION) { log("\(s.name): busy, skipped") }
            return nil
        }
        defer { CloseHandle(h) }
        #else
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            log("\(s.name): busy, skipped")
            return nil
        }
        defer { flock(fd, LOCK_UN) }
        #endif
        let st = await pipeline.process(s)
        log("\(s.name): \(st.state.rawValue) attempts=\(st.attempts)\(st.lastError.map { " error=\($0)" } ?? "")")
        return st
    }

    func runPending(_ store: SessionStore) async {
        for s in store.pending() { _ = await run(s) }
    }
}

final class Daemon {
    let store: SessionStore
    let processor: Processor
    var detector = CallDetector()
    let recorder = Recorder()
    var current: (Session, SessionStatus)?
    var work: Task<Void, Never> = Task {}

    init(config: Config) {
        store = SessionStore(root: config.outputDir)
        processor = Processor(config: config)
    }

    func enqueuePending() {
        let prev = work, store = store, processor = processor
        work = Task { await prev.value; await processor.runPending(store) }
    }

    func run() {
        for s in store.all() {
            if var st = try? s.readStatus(), st.state == .recording {
                st.state = .recorded
                st.end = st.end ?? Date()
                try? s.write(st)
            }
        }
        enqueuePending()
        let timer = Timer(timeInterval: 1, repeats: true) { [self] _ in tick() }
        RunLoop.main.add(timer, forMode: .common)
        let retry = Timer(timeInterval: 900, repeats: true) { [self] _ in enqueuePending() }
        RunLoop.main.add(retry, forMode: .common)

        #if os(Windows)
        guard WindowsStop.claim() else {
            log("another daemon is running")
            exit(1)
        }
        #else
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { [self] in
            log("SIGTERM, shutting down")
            finishCall(at: Date())
            exit(0)
        }
        src.resume()
        #endif
        log("daemon started, root \(store.root.path)")
        RunLoop.main.run()
    }

    func tick() {
        #if os(Windows)
        if WindowsStop.requested() {
            log("stop requested, shutting down")
            finishCall(at: Date())
            exit(0)
        }
        #endif
        let (state, objs) = TelemostProbe.sample()
        let now = Date()
        if current != nil { recorder.setMicGate(open: state.input) }
        switch detector.feed(state, at: now) {
        case .started(let t):
            startCall(at: t, objects: objs, micOpen: state.input)
        case .ended(let t):
            finishCall(at: t)
            enqueuePending()
        case nil:
            break
        }
    }

    func startCall(at t: Date, objects: [TelemostProbe.Source], micOpen: Bool) {
        do {
            let s = try store.create(start: t)
            var st = try s.readStatus()
            log("call started, session \(s.name)")
            do {
                recorder.setMicGate(open: micOpen)
                try recorder.start(session: s, processObjects: objects)
                current = (s, st)
            } catch {
                log("recorder failed: \(error)")
                recorder.stop()
                st.state = .recorded
                st.end = t
                st.lastError = "recorder: \(error)"
                try? s.write(st)
            }
        } catch {
            log("cannot create session: \(error)")
        }
    }

    func finishCall(at t: Date) {
        guard var (s, st) = current else { return }
        recorder.stop()
        st.state = .recorded
        st.end = t
        try? s.write(st)
        current = nil
        log("call ended, session \(s.name)")
    }
}

#if os(Windows)
/// Single-instance mutex and stop event shared with KonspektTray (names in DaemonControl).
enum WindowsStop {
    nonisolated(unsafe) static var event: HANDLE?

    static func claim() -> Bool {
        let mutex = DaemonControl.mutexName.withCString(encodedAs: UTF16.self) { CreateMutexW(nil, true, $0) }
        guard mutex != nil, GetLastError() != DWORD(ERROR_ALREADY_EXISTS) else { return false }
        event = DaemonControl.stopEventName.withCString(encodedAs: UTF16.self) { CreateEventW(nil, true, false, $0) }
        ResetEvent(event)
        // Ctrl+C, closed console, logoff: signal the same event and give tick() time to finish the call.
        SetConsoleCtrlHandler({ _ in
            SetEvent(WindowsStop.event)
            Sleep(4000)
            return true
        }, true)
        return true
    }

    static func requested() -> Bool {
        guard let event else { return false }
        return WaitForSingleObject(event, 0) == WAIT_OBJECT_0
    }
}
#endif
