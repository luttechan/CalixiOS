import SwiftUI
import UIKit

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
                    guard !library.locked, !library.unavailable, library.data.preferences.hasSchoolProfile,
                          (try? AuroraPairing(url.absoluteString)) != nil else { return }
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
                    await CalixScreenshot.runWireCheck()
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
            let originalDue = AuroraCodec.date("2026-11-29T21:30:00+09:00")
            data.events = [
                CalixEvent(id: "canvas:42:assignment:4", title: "Edited", due: originalDue,
                           note: "Keep", remote: true, manualCompletion: false, customTitle: "Edited"),
                CalixEvent(id: "canvas:42:video:8", title: "Cached", kind: .video, remote: true),
            ]
            snapshot.merge(into: &data)
            let assignment = data.events.first { $0.id == "canvas:42:assignment:4" }
            data.preferences.theme = .vesper
            let roundTrip = try JSONDecoder().decode(CalixData.self, from: JSONEncoder().encode(data))
            let valid = data.events.count == 2 && assignment?.title == "Edited" && assignment?.note == "Keep" &&
                originalDue != nil && assignment?.due == originalDue && assignment?.done == false && assignment?.syncStatus == "graded" &&
                data.canvasCourses?["42"]?.term == "검증 학기" && data.moduleValidators?["42"] == "example" &&
                roundTrip.preferences.theme == .vesper
            let aurora = try verifyAurora()
            let profile = try verifyProfile()
            report = valid && aurora && profile ? "PASS" : "Canvas, Aurora, or profile verification failed"
        } catch {
            report = String(describing: error)
        }
        try? report.write(to: URL.documentsDirectory.appendingPathComponent("calix-smoke.txt"), atomically: true, encoding: .utf8)
    }

    @MainActor private static func verifyProfile() throws -> Bool {
        var data = CalixData()
        guard !data.preferences.hasSchoolProfile,
              !CalixPreferences.validSchoolProfile(department: "학과", studentNumber: "12A4") else { return false }
        data.preferences.department = "예시 학과"
        data.preferences.studentNumber = "00001234"
        data.preferences.nickname = "Vesper Test"
        guard data.preferences.hasSchoolProfile else { return false }
        let encoded = try JSONEncoder().encode(data)
        guard try JSONDecoder().decode(CalixData.self, from: encoded).preferences.studentNumber == "00001234" else { return false }
        var link = AuroraLinkState(workspace: "fixture")
        let offer = AuroraWorkspace.offer(data, link, receipt: "fixture", name: "Vesper")
        let wire = String(decoding: try JSONEncoder().encode(offer), as: UTF8.self)
        guard offer.nickname?.value == "Vesper Test", !wire.contains("00001234"), !wire.contains("department") else { return false }
        let remote = """
        {"records":{},"conflicts":[],"school":[],"attendance":[],"owner":"","mainTerm":"","nickname":"Aurora Test"}
        """
        AuroraWorkspace.apply(try JSONDecoder().decode(AuroraSnapshot.self, from: Data(remote.utf8)), baseline: [:],
                              baselineNickname: "Vesper Test", data: &data, link: &link)
        guard data.preferences.nickname == "Aurora Test", link.nickname?.aurora == "Aurora Test" else { return false }
        let canvas = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 48)).image { context in
            context.cgContext.setFillColor(UIColor.systemMint.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
        }
        guard let png = canvas.pngData(), let thumbnail = CalixAvatar.thumbnail(png), UIImage(data: thumbnail) != nil,
              CalixAvatar.thumbnail(Data([0, 1, 2])) == nil else { return false }
        return TimetablePalette.all.allSatisfy { palette in
            let surface = UIColor(white: palette.dark ? 0.20 : 0.87, alpha: 1)
            return CalixContrast.ratio(palette.readableAccent, surface) >= 4.5
        } && CalixTheme.allCases.allSatisfy { theme in
            let surface = UIColor(white: theme.forcesDark ? 0.20 : 0.88, alpha: 1)
            return CalixContrast.ratio(CalixContrast.foreground(theme.accentSource, on: surface), surface) >= 4.5
        }
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
        {"records":{"event":{"manual:sample":{"revision":"111","value":{"title":"Aurora","start":"2026-11-27T00:00:00+09:00","due":"2026-11-29T21:30:00+09:00","done":false,"starred":true}}}},"conflicts":[],"school":[],"attendance":[],"owner":"","mainTerm":"2026학년도 2학기","timetableColors":{"base":{"theme":1,"mode":"auto","colors":{},"slots":[]},"terms":{},"presets":{}}}
        """
        let snapshot = try JSONDecoder().decode(AuroraSnapshot.self, from: Data(smoke.utf8))
        AuroraWorkspace.apply(snapshot, baseline: [:], data: &data, link: &link)
        guard data.events.first?.starts != nil, data.events.first?.starred == true,
              data.auroraTimetableColors?.base.theme == 1, data.auroraTimetableColors?.base.palette.dark == false,
              TimetablePalette.all.count == 16,
              AuroraWorkspace.offer(data, link, receipt: "none", name: "Fixture").changes.isEmpty else { return false }
        data.events[0].title = "Edited on Vesper"
        let offer = AuroraWorkspace.offer(data, link, receipt: "none", name: "Fixture")
        guard offer.changes["event"]?["manual:sample"]?.base == "111", offer.changes["journal"] == nil else { return false }
        let changed = """
        {"records":{"event":{"manual:sample":{"revision":"222","value":{"title":"Edited on Aurora"}}}},"conflicts":["event/manual:sample"],"school":[],"attendance":[],"owner":"","mainTerm":"2026학년도 2학기"}
        """
        let conflict = try JSONDecoder().decode(AuroraSnapshot.self, from: Data(changed.utf8))
        let baseline = AuroraWorkspace.collect(data, link)
        AuroraWorkspace.apply(conflict, baseline: baseline, data: &data, link: &link)
        return data.events[0].title == "Edited on Vesper" && link.conflicts == 1 &&
            link.anchors["event"]?["manual:sample"]?.revision == "111"
    }

    @MainActor static func runWireCheck() async {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-calix-link-wire"), args.indices.contains(index + 1) else { return }
        let report: String
        do {
            let code = try AuroraPairing(args[index + 1], simulatorFixture: true)
            let id = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            let offer = AuroraOffer(receipt: id, name: "Fixture", changes: [
                "event": ["m:fixture": .init(base: nil, value: ["title": .text("Vesper 개강 준비")])]
            ])
            let snapshot = try await AuroraConnection.sync(code, offer: offer)
            report = snapshot.records["event"]?["manual:fixture"]?.revision == "aurora-fixture" ? "PASS" : "Unexpected response"
        } catch {
            report = String(describing: error)
        }
        try? report.write(to: URL.documentsDirectory.appendingPathComponent("calix-wire.txt"), atomically: true, encoding: .utf8)
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
        case "more", "aurora-link", "timetable", "checklist", "grades", "study": 4
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
        result.preferences.nickname = "Vesper Test"
        result.preferences.department = "컴퓨터공학과"
        result.preferences.studentNumber = "202600001"
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
        result.preferences.mainTerm = "2026학년도 2학기"
        let term = result.preferences.mainTerm
        result.lessons = [
            CalixLesson(title: "기업가정신", term: term, weekday: 2, start: 540, end: 630, room: "D401", lecturer: "오민준"),
            CalixLesson(title: "아카데믹 영어", term: term, weekday: 4, start: 660, end: 750, room: "D302", lecturer: "김민서"),
            CalixLesson(title: "세계문화의 이해", term: term, weekday: 5, start: 780, end: 870, room: "D406", lecturer: "이소연"),
            CalixLesson(title: "국제관계 입문", term: term, online: true),
        ]
        result.tasks = [
            CalixTask(title: "에세이 개요", section: "아카데믹 영어", status: "진행중", due: due(0), role: "초안"),
            CalixTask(title: "발표 자료 분담", section: "기업가정신", status: "계획", due: due(2), role: "자료 조사"),
            CalixTask(title: "팀 회의 요약", section: "기업가정신", done: true, status: "완료", due: due(-1)),
        ]
        result.grades = [
            CalixGrade(title: "기업가정신", term: term, credits: 3, mark: "A+", category: "전공"),
            CalixGrade(title: "아카데믹 영어", term: term, credits: 3, mark: "A", category: "교양"),
            CalixGrade(title: "세계문화의 이해", term: term, credits: 2, mark: "B+", category: "전공"),
        ]
        result.focusHistory = [
            CalixFocusRecord(id: UUID(), started: now, seconds: 1500),
            CalixFocusRecord(id: UUID(), started: now.addingTimeInterval(-86400), seconds: 2400),
        ]
        return result
    }
}
#endif
