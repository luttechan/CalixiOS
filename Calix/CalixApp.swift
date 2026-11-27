import SwiftUI

@main
struct CalixApp: App {
    private struct PairRoute: Identifiable {
        let id = UUID()
        let code: String
    }
    @State private var library = CalixLibrary()
    @State private var pair: PairRoute?
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            CalixRoot(library: library)
                .environment(\.locale, Locale(identifier: library.data.preferences.language ?? "ko"))
                .onOpenURL { url in
                    guard !library.locked, !library.unavailable, (try? AuroraPairing(url.absoluteString)) != nil else { return }
                    pair = PairRoute(code: url.absoluteString)
                }
                .sheet(item: $pair) { route in
                    NavigationStack {
                        AuroraLinkView(library: library, initialCode: route.code)
                            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { pair = nil } } }
                    }
                }
                .task {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-calix-smoke") { CalixScreenshot.runSmokeCheck() }
                    #endif
                }
                .onChange(of: phase) { _, newPhase in
                    if newPhase == .background { library.backgrounded(); pair = nil }
                    if newPhase == .active { library.finishFocusIfNeeded() }
                }
        }
    }
}

#if DEBUG
enum CalixScreenshot {
    @MainActor static func runSmokeCheck() {
        let fixture = """
        {"owner":"13","courses":[{"id":"42","name":"Methods","assignments":[{"id":"canvas:42:assignment:4","title":"New Title","course":"Methods","kind":"과제","done":true,"status":"graded"}],"videos":null,"modulesUnchanged":true,"modulesVerified":true,"modulesValidator":"example"}]}
        """
        let report: String
        do {
            let snapshot = try JSONDecoder().decode(CanvasSnapshot.self, from: Data(fixture.utf8))
            var data = CalixData()
            data.preferences.mainTerm = "검증 학기"
            data.events = [
                CalixEvent(id: "canvas:42:assignment:4", title: "Edited", note: "Keep", remote: true, manualCompletion: false, customTitle: "Edited"),
                CalixEvent(id: "canvas:42:video:8", title: "Cached", kind: .video, remote: true),
            ]
            snapshot.merge(into: &data)
            let assignment = data.events.first { $0.id == "canvas:42:assignment:4" }
            data.preferences.theme = .vesper
            let roundTrip = try JSONDecoder().decode(CalixData.self, from: JSONEncoder().encode(data))
            let valid = data.events.count == 2 && assignment?.title == "Edited" && assignment?.note == "Keep" &&
                assignment?.done == false && assignment?.syncStatus == "graded" &&
                data.canvasCourses?["42"]?.term == "검증 학기" && data.moduleValidators?["42"] == "example" &&
                roundTrip.preferences.theme == .vesper
            let aurora = try verifyAurora()
            report = valid && aurora ? "PASS" : "Canvas or Aurora merge did not preserve expected state"
        } catch {
            report = String(describing: error)
        }
        try? report.write(to: URL.documentsDirectory.appendingPathComponent("calix-smoke.txt"), atomically: true, encoding: .utf8)
    }

    @MainActor private static func verifyAurora() throws -> Bool {
        let expiry = Int(Date().timeIntervalSince1970) + 90
        let validCode = "calix-vesper://pair?v=2&host=192.168.1.8&port=31410&computer=" +
            "11111111111111111111111111111111&expires=\(expiry)&key=" + String(repeating: "A", count: 43)
        let pair = try AuroraPairing(validCode)
        guard (try? AuroraPairing(validCode.replacingOccurrences(of: "192.168.1.8", with: "8.8.8.8"))) == nil else { return false }
        var data = CalixData()
        data.journals = [CalixJournal(title: "Protected", secret: true)]
        var link = AuroraLinkState(workspace: pair.workspace)
        let smoke = """
        {"records":{"event":{"manual:sample":{"revision":"111","value":{"title":"Aurora","start":"2026-11-27T00:00:00+09:00","due":"2026-11-29T21:30:00+09:00","done":false,"starred":true}}}},"conflicts":[],"school":[],"attendance":[],"owner":"","mainTerm":"2026학년도 2학기"}
        """
        let snapshot = try JSONDecoder().decode(AuroraSnapshot.self, from: Data(smoke.utf8))
        AuroraWorkspace.apply(snapshot, baseline: [:], data: &data, link: &link)
        guard data.events.first?.starts != nil, data.events.first?.starred == true,
              AuroraWorkspace.offer(data, link, receipt: "none", name: "Fixture").changes.isEmpty else { return false }
        data.events[0].title = "Edited on Vesper"
        let offer = AuroraWorkspace.offer(data, link, receipt: "none", name: "Fixture")
        return offer.changes["event"]?["manual:sample"]?.base == "111" && offer.changes["journal"] == nil
    }

    static var page: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-calix-screenshot"), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }

    static var tab: Int {
        switch page {
        case "deadlines": 1
        case "calendar": 2
        case "courses": 3
        case "more": 4
        default: 0
        }
    }

    static func seed(now: Date = .now) -> CalixData {
        func due(_ offset: Int) -> Date? {
            let calendar = Calendar.current
            return calendar.date(byAdding: .day, value: offset, to: now).flatMap {
                calendar.date(bySettingHour: 23, minute: 59, second: 59, of: $0)
            }
        }
        var result = CalixData()
        result.preferences.nickname = "민서"
        result.preferences.theme = page == "home-vesper" ? .vesper : .aurora
        result.canvasID = "fixture"
        result.lastSync = now
        result.events = [
            CalixEvent(title: "창업 아이디어 정리", course: "기업가정신", due: due(0), starred: true),
            CalixEvent(title: "읽기 자료 요약", course: "아카데믹 영어", due: due(-1)),
            CalixEvent(title: "이번 주 강의 영상", course: "세계문화의 이해", kind: .video, due: due(2)),
            CalixEvent(title: "에세이 개요 작성", course: "아카데믹 영어", due: due(4)),
            CalixEvent(title: "팀 발표 자료 제출", course: "기업가정신", due: due(10)),
            CalixEvent(title: "수업 안내 영상", course: "기업가정신", kind: .video, due: due(-4), done: true),
            CalixEvent(title: "발표 주제 투표", course: "아카데믹 영어", due: due(-4), done: true),
            CalixEvent(title: "강의 복습 영상", course: "세계문화의 이해", kind: .video)
        ]
        return result
    }
}
#endif
