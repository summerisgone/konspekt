import Testing
@testable import KonspektCore

@Suite struct TelemostProbeTests {
    @Test func test_helper_path_matches() {
        #expect(TelemostProbe.isTelemostPath("/Applications/Yandex.Telemost.app/Contents/MacOS/Yandex.Telemost"))
        #expect(TelemostProbe.isTelemostPath("/Applications/Yandex.Telemost.app/Contents/Frameworks/QtWebEngineProcess.app/Contents/MacOS/QtWebEngineProcess"))
        #expect(!TelemostProbe.isTelemostPath("/Applications/Safari.app/Contents/MacOS/Safari"))
        #expect(TelemostProbe.isTelemostPath(#"C:\Program Files\Yandex\YandexTelemost\YandexTelemost.exe"#))
        #expect(TelemostProbe.isTelemostPath(#"C:\Program Files\Yandex\YandexTelemost\QtWebEngineProcess.exe"#))
        #expect(!TelemostProbe.isTelemostPath(#"C:\Program Files\Yandex\YandexBrowser\browser.exe"#))
    }

    @Test func test_no_telemost_running() {
        let (s, objs) = TelemostProbe.sample()
        if !s.running { #expect(!s.input && !s.output && objs.isEmpty) }
        else { #expect(!objs.isEmpty) }
    }
}
