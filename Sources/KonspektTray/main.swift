#if os(Windows)
import Foundation
import KonspektCore
import WinSDK

// Tray icon for Windows: starts `konspekt.exe daemon` without a console window, restarts it
// when it exits (the LaunchAgent KeepAlive counterpart), autostart via the HKCU Run key.

func wide(_ s: String) -> [WCHAR] { Array(s.utf16) + [0] }

let runKey = #"Software\Microsoft\Windows\CurrentVersion\Run"#
let runValue = "Konspekt"
let exitConfigError: DWORD = 78

enum Command: UINT_PTR {
    case toggle = 1, autostart, folder, settings, log, quit
    case call0 = 100
}

final class Tray {
    let configURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KONSPEKT_CONFIG"] ?? Config.defaultEnvFile.path)
    let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    var hwnd: HWND?
    var icon: HICON?
    var taskbarCreated: UINT = 0
    /// The user wants the daemon running; cleared by "Остановить".
    var wanted = true
    var daemon: HANDLE?
    var message = ""
    /// Modification date of the config the daemon was started with.
    var configStamp: Date?
    /// Modification date of a config the daemon rejected (exit code 78).
    var failedConfig: Date?
    var calls: [Session] = []

    var running: Bool {
        let m = DaemonControl.mutexName.withCString(encodedAs: UTF16.self) { OpenMutexW(DWORD(SYNCHRONIZE), false, $0) }
        guard let m else { return false }
        CloseHandle(m)
        return true
    }

    var store: SessionStore {
        let env = Config.parse((try? String(contentsOf: configURL, encoding: .utf8)) ?? "")
        return SessionStore(root: Config.outputDir(env))
    }

    var recording: Bool {
        store.all().suffix(3).contains { (try? $0.readStatus())?.state == .recording }
    }

    // MARK: daemon

    func startDaemon() {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            message = "Сначала заполните настройки"
            return
        }
        guard !running else { return }
        let logURL = DaemonControl.logFile
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var sa = SECURITY_ATTRIBUTES(nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size), lpSecurityDescriptor: nil, bInheritHandle: true)
        let log = logURL.path.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(FILE_APPEND_DATA), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE), &sa,
                        DWORD(OPEN_ALWAYS), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        }
        defer { if log != INVALID_HANDLE_VALUE { CloseHandle(log) } }

        var si = STARTUPINFOW()
        si.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
        si.dwFlags = DWORD(STARTF_USESTDHANDLES)
        si.hStdOutput = log
        si.hStdError = log
        var pi = PROCESS_INFORMATION()
        let exe = exeDir.appendingPathComponent("konspekt.exe").path
        var cmd = wide("\"\(exe)\" daemon")
        let ok = CreateProcessW(nil, &cmd, nil, nil, log != INVALID_HANDLE_VALUE, DWORD(CREATE_NO_WINDOW),
                                nil, nil, &si, &pi)
        guard ok else {
            message = "Не удалось запустить konspekt.exe (код \(GetLastError()))"
            wanted = false
            return
        }
        CloseHandle(pi.hThread)
        if let d = daemon { CloseHandle(d) }
        daemon = pi.hProcess
        configStamp = modified(configURL)
        message = ""
    }

    func stopDaemon() {
        let ev = DaemonControl.stopEventName.withCString(encodedAs: UTF16.self) { OpenEventW(DWORD(EVENT_MODIFY_STATE), false, $0) }
        if let ev {
            SetEvent(ev)
            CloseHandle(ev)
        }
        if let d = daemon {
            WaitForSingleObject(d, 10000)
            CloseHandle(d)
            daemon = nil
        }
    }

    /// Every 5 s: restart a daemon that exited, and restart after the config file changed.
    func supervise() {
        if let d = daemon, WaitForSingleObject(d, 0) == WAIT_OBJECT_0 {
            var code: DWORD = 0
            GetExitCodeProcess(d, &code)
            CloseHandle(d)
            daemon = nil
            if code == exitConfigError {
                failedConfig = configStamp
                message = "Ошибка в настройках, подробности в логе"
            }
        }
        guard wanted else { return }
        if running, daemon != nil, modified(configURL) != configStamp, !recording {
            stopDaemon()
        }
        // After a config error, wait until the file is saved again.
        if !running, failedConfig == nil || modified(configURL) != failedConfig {
            failedConfig = nil
            startDaemon()
        }
        updateTip()
    }

    func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // MARK: autostart

    var autostart: Bool {
        get {
            var size: DWORD = 0
            return runKey.withCString(encodedAs: UTF16.self) { key in
                runValue.withCString(encodedAs: UTF16.self) { name in
                    RegGetValueW(HKEY_CURRENT_USER, key, name, DWORD(RRF_RT_REG_SZ), nil, nil, &size) == ERROR_SUCCESS
                }
            }
        }
        set {
            runKey.withCString(encodedAs: UTF16.self) { key in
                runValue.withCString(encodedAs: UTF16.self) { name in
                    if newValue {
                        let exe = wide("\"\(exeDir.appendingPathComponent("KonspektTray.exe").path)\"")
                        _ = exe.withUnsafeBytes {
                            RegSetKeyValueW(HKEY_CURRENT_USER, key, name, DWORD(REG_SZ), $0.baseAddress, DWORD($0.count))
                        }
                    } else {
                        _ = RegDeleteKeyValueW(HKEY_CURRENT_USER, key, name)
                    }
                }
            }
        }
    }

    // MARK: shell

    func open(_ path: String, with app: String? = nil) {
        let target = app ?? path
        let params = app == nil ? nil : "\"\(path)\""
        _ = target.withCString(encodedAs: UTF16.self) { file in
            "open".withCString(encodedAs: UTF16.self) { verb in
                if let params {
                    params.withCString(encodedAs: UTF16.self) { ShellExecuteW(nil, verb, file, $0, nil, SW_SHOWNORMAL) }
                } else {
                    ShellExecuteW(nil, verb, file, nil, nil, SW_SHOWNORMAL)
                }
            }
        }
    }

    func openSettings() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: configURL.path) {
            try? fm.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let template = """
            # Настройки Konspekt. После сохранения файла демон перезапустится сам.
            OPENAI_BASE_URL=
            OPENAI_API_KEY=
            OPENAI_MODEL_NAME=
            # SUMMARY_MODEL_NAME=qwen-3.8-27b
            # KONSPEKT_DIR=
            # TRANSCRIPTION_PROMPT_FILE=
            # SUMMARY_PROMPT_FILE=

            """
            try? template.write(to: configURL, atomically: true, encoding: .utf8)
        }
        open(configURL.path, with: "notepad.exe")
    }

    // MARK: icon and menu

    func addIcon() {
        var nid = notifyData()
        nid.uFlags = UINT(NIF_ICON | NIF_MESSAGE | NIF_TIP)
        Shell_NotifyIconW(DWORD(NIM_ADD), &nid)
    }

    func updateTip() {
        var nid = notifyData()
        nid.uFlags = UINT(NIF_TIP)
        Shell_NotifyIconW(DWORD(NIM_MODIFY), &nid)
    }

    func notifyData() -> NOTIFYICONDATAW {
        var nid = NOTIFYICONDATAW()
        nid.cbSize = DWORD(MemoryLayout<NOTIFYICONDATAW>.size)
        nid.hWnd = hwnd
        nid.uID = 1
        nid.uCallbackMessage = UINT(WM_APP + 1)
        nid.hIcon = icon
        let tip = Array(("Konspekt: " + statusText).utf16.prefix(127)) + [0]
        withUnsafeMutableBytes(of: &nid.szTip) { buf in
            tip.withUnsafeBytes { buf.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(buf.count))) }
        }
        return nid
    }

    var statusText: String {
        if !message.isEmpty { return message }
        guard running else { return "остановлен" }
        return recording ? "идет запись" : "ждет звонка"
    }

    static let stateNames: [SessionState: String] = [
        .recording: "идет запись", .recorded: "ожидает обработки", .transcribed: "расшифровано", .done: "готово",
    ]

    func showMenu() {
        let menu = CreatePopupMenu()
        defer { DestroyMenu(menu) }
        func item(_ title: String, _ cmd: UINT_PTR, flags: Int32 = MF_STRING) {
            _ = wide(title).withUnsafeBufferPointer { AppendMenuW(menu, UINT(flags), cmd, $0.baseAddress) }
        }
        func separator() { AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil) }

        let isRunning = running
        item("Konspekt: \(statusText)", 0, flags: MF_STRING | MF_GRAYED)
        item(isRunning ? "Остановить" : "Запустить", Command.toggle.rawValue)
        item("Запускать при входе в Windows", Command.autostart.rawValue, flags: MF_STRING | (autostart ? MF_CHECKED : 0))
        separator()

        calls = Array(store.all().suffix(5).reversed())
        if calls.isEmpty {
            item("Звонков пока нет", 0, flags: MF_STRING | MF_GRAYED)
        }
        for (i, s) in calls.enumerated() {
            let st = try? s.readStatus()
            let state = st.map { $0.lastError == nil ? Self.stateNames[$0.state] ?? "" : "ошибка" } ?? ""
            item("\(s.name) — \(state)", Command.call0.rawValue + UINT_PTR(i))
        }
        separator()
        item("Открыть папку записей", Command.folder.rawValue)
        item("Настройки...", Command.settings.rawValue)
        item("Открыть лог", Command.log.rawValue)
        separator()
        item("Выход", Command.quit.rawValue)

        var pt = POINT()
        GetCursorPos(&pt)
        SetForegroundWindow(hwnd)
        // The chosen item arrives as WM_COMMAND.
        TrackPopupMenu(menu, UINT(TPM_RIGHTBUTTON), pt.x, pt.y, 0, hwnd, nil)
        PostMessageW(hwnd, UINT(WM_NULL), 0, 0)
    }

    func handle(_ cmd: UINT_PTR) {
        switch Command(rawValue: cmd) {
        case .toggle:
            if running { wanted = false; stopDaemon() } else { wanted = true; failedConfig = nil; startDaemon() }
        case .autostart:
            autostart.toggle()
        case .folder:
            let dir = store.root
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            open(dir.path)
        case .settings:
            openSettings()
        case .log:
            open(DaemonControl.logFile.path, with: "notepad.exe")
        case .quit:
            wanted = false
            stopDaemon()
            var nid = notifyData()
            Shell_NotifyIconW(DWORD(NIM_DELETE), &nid)
            PostQuitMessage(0)
        default:
            let i = Int(cmd) - Int(Command.call0.rawValue)
            if cmd >= Command.call0.rawValue, i < calls.count { open(calls[i].dir.path) }
        }
        updateTip()
    }
}

let tray = Tray()

let wndProc: WNDPROC = { hwnd, msg, wParam, lParam in
    switch msg {
    case UINT(WM_APP + 1):
        let event = UINT(lParam & 0xFFFF)
        if event == UINT(WM_RBUTTONUP) || event == UINT(WM_LBUTTONUP) { tray.showMenu() }
        return 0
    case UINT(WM_COMMAND):
        tray.handle(UINT_PTR(wParam & 0xFFFF))
        return 0
    case UINT(WM_TIMER):
        tray.supervise()
        return 0
    case tray.taskbarCreated where tray.taskbarCreated != 0:
        tray.addIcon()
        return 0
    default:
        return DefWindowProcW(hwnd, msg, wParam, lParam)
    }
}

let single = "Local\\KonspektTray".withCString(encodedAs: UTF16.self) { CreateMutexW(nil, true, $0) }
if GetLastError() == DWORD(ERROR_ALREADY_EXISTS) { exit(0) }

let instance = GetModuleHandleW(nil)
let className = wide("KonspektTray")
className.withUnsafeBufferPointer { name in
    var wc = WNDCLASSEXW()
    wc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
    wc.lpfnWndProc = wndProc
    wc.hInstance = instance
    wc.lpszClassName = name.baseAddress
    RegisterClassExW(&wc)
    tray.hwnd = CreateWindowExW(0, name.baseAddress, name.baseAddress, 0, 0, 0, 0, 0, nil, nil, instance, nil)
}
tray.taskbarCreated = "TaskbarCreated".withCString(encodedAs: UTF16.self) { RegisterWindowMessageW($0) }
let iconPath = tray.exeDir.appendingPathComponent("Konspekt.ico").path
tray.icon = iconPath.withCString(encodedAs: UTF16.self) {
    LoadImageW(nil, $0, UINT(IMAGE_ICON), 0, 0, UINT(LR_LOADFROMFILE | LR_DEFAULTSIZE))?.assumingMemoryBound(to: HICON__.self)
} ?? LoadIconW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))  // IDI_APPLICATION

tray.addIcon()
if FileManager.default.fileExists(atPath: tray.configURL.path) { tray.startDaemon() } else { tray.openSettings() }
tray.updateTip()
SetTimer(tray.hwnd, 1, 5000, nil)

var msg = MSG()
while GetMessageW(&msg, nil, 0, 0) {
    TranslateMessage(&msg)
    DispatchMessageW(&msg)
}
_ = single
#endif
