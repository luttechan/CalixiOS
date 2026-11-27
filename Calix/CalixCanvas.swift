import SwiftUI
import WebKit

@MainActor
final class CanvasBrowser: NSObject, WKNavigationDelegate, WKUIDelegate {
    static let startURL = URL(string: "https://canvas.bufs.ac.kr/login")!
    let view: WKWebView
    var onCampusPage: (() -> Void)?

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        view = WKWebView(frame: .zero, configuration: config)
        super.init()
        view.navigationDelegate = self
        view.uiDelegate = self
        view.load(URLRequest(url: Self.startURL))
    }

    nonisolated static func isCampus(_ url: URL) -> Bool {
        guard url.scheme == "https", url.port == nil || url.port == 443,
              url.user == nil, url.password == nil, let host = url.host else { return false }
        return host == "bufs.ac.kr" || host.hasSuffix(".bufs.ac.kr")
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if action.targetFrame?.isMainFrame == false && url.absoluteString == "about:blank" { return .allow }
        return Self.isCampus(url) ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, Self.isCampus(url) { webView.load(navigationAction.request) }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url, url.host == Self.startURL.host, Self.isCampus(url),
              !url.path.hasPrefix("/login"), !url.path.hasPrefix("/logout") else { return }
        onCampusPage?()
    }

    static func clearSession() async {
        let store = WKWebsiteDataStore.default()
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
}

private struct CampusWebView: UIViewRepresentable {
    let browser: CanvasBrowser
    func makeUIView(context: Context) -> WKWebView { browser.view }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct CalixCanvas: View {
    let library: CalixLibrary
    @State private var browser: CanvasBrowser?
    @State private var syncTask: Task<Void, Never>?
    @State private var attemptedAutomaticSync = false
    @State private var message = "학교 계정으로 로그인한 뒤 동기화를 누르세요."
    @State private var report: SyncReport?

    private struct SyncReport {
        let assignments: Int
        let assignmentErrors: Int
        let videoErrors: Int
        let deadline: CanvasSnapshot.DeadlineReport?
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(message).font(.subheadline)
                if let time = library.data.lastSync {
                    Text("최근 동기화 \(time.formatted(.dateTime.month().day().hour().minute()))").font(.caption).foregroundStyle(.secondary)
                }
                if let report {
                    DisclosureGroup("조회 결과") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("과제 \(report.assignments)개")
                            Text("과제 목록 응답 오류 \(report.assignmentErrors)과목")
                            Text("영상 응답 오류 \(report.videoErrors)과목")
                            if let deadline = report.deadline {
                                LabeledContent {
                                    Text(Self.status(deadline.planner)) + Text(verbatim: ", ") + Text("반영 \(deadline.plannerUsed)개")
                                } label: { Text("Canvas 플래너") }
                                LabeledContent {
                                    Text(Self.status(deadline.calendar)) + Text(verbatim: ", ") + Text("반영 \(deadline.calendarUsed)개")
                                } label: { Text("Canvas 달력") }
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
                if syncTask != nil {
                    HStack {
                        ProgressView()
                        Text("학교 일정 확인 중")
                        Spacer()
                        Button("중단") { cancel() }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            if let browser { CampusWebView(browser: browser) } else { ProgressView().frame(maxHeight: .infinity) }
        }
        .navigationTitle("학교 동기화")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if browser == nil {
                let campus = CanvasBrowser()
                campus.onCampusPage = {
                    guard !attemptedAutomaticSync else { return }
                    attemptedAutomaticSync = true
                    sync()
                }
                browser = campus
            }
        }
        .onDisappear {
            browser?.onCampusPage = nil
            cancel()
            browser = nil
            attemptedAutomaticSync = false
        }
        .toolbar {
            Button("동기화") { sync() }.disabled(browser == nil || syncTask != nil)
        }
    }

    private func cancel() {
        guard let syncTask else { return }
        syncTask.cancel()
        browser?.view.reload()
        message = "동기화를 중단하는 중입니다."
    }

    private func sync() {
        guard let browser, browser.view.url?.host == "canvas.bufs.ac.kr",
              browser.view.url?.scheme == "https", !browser.view.isLoading else {
            message = "학교 로그인 화면이 열릴 때까지 기다려 주세요."
            return
        }
        syncTask = Task {
            report = nil
            defer { syncTask = nil }
            do {
                let script = try CanvasSnapshot.script()
                let includeAttendance = library.data.preferences.syncAttendance ?? library.data.preferences.showAttendance
                let arguments: [String: Any] = [
                    "expectedOwner": library.data.canvasID ?? "",
                    "knownModules": library.data.canvasID == nil || library.data.canvasDeadlineRevision != CanvasSnapshot.deadlineRevision
                        ? [:] : (library.data.moduleValidators ?? [:]),
                    "includeAttendance": includeAttendance
                ]
                let result = try await browser.view.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .page)
                try Task.checkCancellation()
                guard let value = result as? String, value.utf8.count < 20_000_000 else { throw CocoaError(.fileReadCorruptFile) }
                let resultData = try CanvasSnapshot.decode(value)
                guard library.data.canvasID == nil || library.data.canvasID == resultData.owner else {
                    message = "현재 계정과 다릅니다. 설정에서 먼저 로그아웃하세요."
                    return
                }
                let partial = resultData.courses.filter {
                    $0.assignments == nil || $0.modulesPartial == true || ($0.videos == nil && $0.modulesUnchanged != true) ||
                        (includeAttendance && $0.attendance == nil)
                }.count
                let incoming = resultData.courses.flatMap { ($0.assignments ?? []) + ($0.videos ?? []) }
                let dated = incoming.filter { $0.due != nil }.count
                let unconfirmed = incoming.filter { $0.due == nil && $0.dueKnown != true }.count
                let received = incoming.count
                if library.update({ resultData.merge(into: &$0) }) {
                    report = SyncReport(
                        assignments: resultData.courses.reduce(0) { $0 + ($1.assignments?.count ?? 0) },
                        assignmentErrors: resultData.courses.filter { Self.failed($0.assignmentSource) }.count,
                        videoErrors: resultData.courses.filter { Self.failed($0.videoSource) }.count,
                        deadline: resultData.deadlineReport
                    )
                    var summary = "일정 \(received)개, 기한 \(dated)개 확인"
                    if unconfirmed > 0 { summary += ", 기한 미확인 \(unconfirmed)개" }
                    if partial > 0 { summary += "\n일부 자료를 읽지 못한 과목 \(partial)개" }
                    message = summary
                }
            } catch {
                if Task.isCancelled { message = "동기화를 중단했습니다." }
                else if String(describing: error).contains("ACCOUNT_CHANGED") { message = "현재 계정과 다릅니다. 설정에서 먼저 로그아웃하세요." }
                else { message = "학교 데이터를 읽지 못했습니다. 로그인과 네트워크 연결을 확인하고 다시 시도하세요." }
            }
        }
    }

    private static func failed(_ code: String?) -> Bool {
        ["auth", "timeout", "network", "response", "partial"].contains(code ?? "")
    }

    private static func status(_ code: String) -> LocalizedStringKey {
        switch code {
        case "ok": "조회 완료"
        case "partial": "일부 조회"
        case "empty": "자료 없음"
        case "auth": "접근 권한 오류"
        case "timeout": "응답 시간 초과"
        case "network": "연결 오류"
        case "skipped": "조회 생략"
        default: "응답 오류"
        }
    }
}

struct CanvasSnapshot: Decodable {
    static let deadlineRevision = 3
    static func script() throws -> String {
        let files = ["CanvasModules", "CanvasSync"]
        return try files.map { file in
            guard let path = Bundle.main.url(forResource: file, withExtension: "js") else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            return try String(contentsOf: path, encoding: .utf8)
        }.joined(separator: "\n")
    }
    static func decode(_ json: String) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            guard let date = AuroraCodec.date(value) else { throw CocoaError(.fileReadCorruptFile) }
            return date
        }
        return try decoder.decode(Self.self, from: Data(json.utf8))
    }
    struct Course: Decodable {
        let id: String
        let name: String
        let assignments: [Row]?
        let videos: [Row]?
        let attendance: [CalixAttendance]?
        let modulesUnchanged: Bool?
        let modulesVerified: Bool?
        let modulesValidator: String?
        let modulesPartial: Bool?
        let assignmentSource: String?
        let videoSource: String?
    }

    struct Row: Decodable {
        let id: String
        let title: String
        let course: String
        let kind: EventKind
        let due: Date?
        let dueKnown: Bool?
        let done: Bool
        let completionKnown: Bool?
        let url: URL?
        let feedback: String?
        let status: String?

        func event(previous: CalixEvent?) -> CalixEvent {
            let preserveCompletion = status == "unverified" || completionKnown == false
            return CalixEvent(id: id, title: previous?.customTitle ?? title, course: course, kind: kind,
                       due: dueKnown == true ? due : (due ?? previous?.due), note: previous?.note ?? "",
                       done: previous?.manualCompletion ?? (preserveCompletion ? (previous?.done ?? done) : done),
                       starred: previous?.starred ?? false, remote: true,
                       manualCompletion: previous?.manualCompletion, url: url.flatMap { CanvasBrowser.isCampus($0) ? $0 : nil },
                       feedback: feedback ?? previous?.feedback, customTitle: previous?.customTitle,
                       syncStatus: completionKnown == false ? (previous?.syncStatus ?? status) : status,
                       deadlineKnown: due != nil || dueKnown == true || previous?.deadlineKnown == true)
        }
    }

    let owner: String
    let courses: [Course]
    struct DeadlineReport: Decodable {
        let planner: String
        let plannerUsed: Int
        let calendar: String
        let calendarUsed: Int
    }
    let deadlineReport: DeadlineReport?

    @MainActor func merge(into data: inout CalixData) {
        if let previous = data.auroraSchoolOwner, previous != owner {
            let ids = Set(data.auroraSchoolEvents ?? [])
            data.events.removeAll { $0.remote && ids.contains($0.id) }
            if data.canvasID == nil { data.attendance.removeAll() }
            data.auroraSchoolEvents = nil
            data.auroraSchoolOwner = nil
        }
        var events = Dictionary(data.events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var attendance = Dictionary(data.attendance.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var validators = data.canvasDeadlineRevision == Self.deadlineRevision ? (data.moduleValidators ?? [:]) : [:]
        var registered = data.canvasCourses ?? [:]
        for course in courses {
            registered[course.id] = CanvasCourse(id: course.id, name: course.name, term: registered[course.id]?.term ?? data.preferences.mainTerm)
            if course.modulesVerified == true { validators[course.id] = course.modulesValidator }
            for row in (course.assignments ?? []) + (course.videos ?? []) { events[row.id] = row.event(previous: events[row.id]) }
            if let rows = course.attendance {
                attendance = attendance.filter { !$0.key.hasPrefix("lesson:\(course.id):") && !$0.key.hasPrefix("item:\(course.id):") }
                for row in rows { attendance[row.id] = row }
            }
        }
        data.events = events.values.sorted { $0.id < $1.id }
        data.attendance = attendance.values.sorted { $0.id < $1.id }
        let active = Set(courses.map(\.id))
        data.moduleValidators = validators.filter { active.contains($0.key) }
        data.canvasDeadlineRevision = Self.deadlineRevision
        data.canvasCourses = registered
        data.canvasID = owner
        if courses.isEmpty || courses.contains(where: { $0.assignments != nil || $0.modulesVerified == true || $0.attendance != nil }) {
            data.lastSync = .now
        }
    }
}
