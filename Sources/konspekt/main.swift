import Foundation
import KonspektCore

func fail(_ msg: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(code)
}

let args = Array(CommandLine.arguments.dropFirst())
let configPath = ProcessInfo.processInfo.environment["KONSPEKT_CONFIG"] ?? Config.defaultEnvFile.path

#if os(macOS)
// No arguments (opened from Finder): show the settings window.
if args.isEmpty || args[0].hasPrefix("-psn") {
    KonspektApp.main()
    exit(0)
}
#endif

let commands = ["daemon", "status", "retry", "process"]
guard let cmd = args.first, commands.contains(cmd), cmd != "process" || args.count == 2 else {
    fail("usage: konspekt [daemon | status | retry | process <dir>]", 64)
}

let config: Config
do {
    config = try Config.load(envFile: URL(fileURLWithPath: configPath))
} catch {
    fail("cannot load config at \(configPath): \(error)", 78)
}
let store = SessionStore(root: config.outputDir)

switch cmd {
case "daemon":
    Daemon(config: config).run()
case "status":
    for s in store.all() {
        if let st = try? s.readStatus() {
            print("\(s.name) \(st.state.rawValue) \(st.attempts) \(st.lastError ?? "")")
        } else {
            print("\(s.name) unreadable 0 ")
        }
    }
case "retry":
    await Processor(config: config).runPending(store)
default:
    let s = Session(dir: URL(fileURLWithPath: args[1]))
    if await Processor(config: config).run(s) == nil { exit(1) }
}
