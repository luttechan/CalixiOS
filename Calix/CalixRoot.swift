import SwiftUI
import UIKit

struct CalixRoot: View {
    let library: CalixLibrary
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if DEBUG
    @State private var tab = CalixScreenshot.tab
    #else
    @State private var tab = 0
    #endif

    var body: some View {
        let theme = library.data.preferences.theme
        Group {
            if library.unavailable {
                ContentUnavailableView {
                    Label("Calix", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text("저장한 데이터를 열지 못했습니다.")
                } actions: {
                    Button("다시 시도") { library.reload() }.buttonStyle(.borderedProminent)
                }
            } else if library.locked {
                ContentUnavailableView {
                    Label("Calix 잠김", systemImage: "lock.fill")
                } actions: {
                    Button("잠금 해제") {
                        Task {
                            if await library.authenticate("Calix 잠금을 해제합니다.") {
                                library.locked = false
                                library.finishFocusIfNeeded()
                            }
                        }
                    }.buttonStyle(.borderedProminent)
                }
            } else if !library.data.preferences.hasSchoolProfile {
                CalixSchoolProfileSetup(library: library)
            } else {
                TabView(selection: $tab) {
                    NavigationStack { CalixHome(library: library, openDeadlines: { changeTab(1) }) }
                        .tabItem { Label("홈", systemImage: "house") }.tag(0)
                    NavigationStack { CalixEvents(library: library) }
                        .tabItem { Label("일정", systemImage: "tray.full") }.tag(1)
                    NavigationStack { CalixCalendar(library: library) }
                        .tabItem { Label("달력", systemImage: "calendar") }.tag(2)
                    NavigationStack { CalixCourseList(library: library) }
                        .tabItem { Label("과목", systemImage: "books.vertical") }.tag(3)
                    NavigationStack { CalixMore(library: library) }
                        .tabItem { Label("더 보기", systemImage: "ellipsis") }.tag(4)
                }
            }
        }
        .scrollContentBackground(reduceTransparency ? .visible : .hidden)
        .background { VesperBackdrop(theme: theme).ignoresSafeArea() }
        .environment(\.vesperTheme, theme)
        .tint(theme.accent)
        .preferredColorScheme(theme.forcesDark ? .dark : .light)
        .overlay {
            if phase == .background && library.data.preferences.lockOnBackground {
                Rectangle().fill(.background).ignoresSafeArea()
            }
        }
        .alert("Calix", isPresented: Binding(get: { library.issue != nil }, set: { if !$0 { library.issue = nil } })) {
            Button("확인", role: .cancel) { library.issue = nil }
        } message: {
            Text(library.issue ?? "")
        }
    }

    private func changeTab(_ value: Int) {
        guard tab != value else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.78)) { tab = value }
    }

}

private struct CalixSchoolProfileSetup: View {
    let library: CalixLibrary
    @State private var department: String
    @State private var studentNumber: String
    @State private var nickname: String
    @FocusState private var editing: Field?
    private enum Field { case department, studentNumber, nickname }

    init(library: CalixLibrary) {
        self.library = library
        _department = State(initialValue: library.data.preferences.department ?? "")
        _studentNumber = State(initialValue: library.data.preferences.studentNumber ?? "")
        _nickname = State(initialValue: library.data.preferences.nickname)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("학교 정보") {
                    TextField("학과", text: $department).focused($editing, equals: .department)
                        .submitLabel(.next).onSubmit { editing = .studentNumber }
                    TextField("학번", text: $studentNumber).keyboardType(.asciiCapableNumberPad)
                        .focused($editing, equals: .studentNumber)
                }
                Section("프로필") {
                    TextField("닉네임 (선택)", text: $nickname).focused($editing, equals: .nickname)
                }
                Button {
                    library.update {
                        $0.preferences.department = department.trimmed
                        $0.preferences.studentNumber = studentNumber.trimmed
                        $0.preferences.nickname = CalixPreferences.cleanedNickname(nickname)
                    }
                } label: {
                    Text("시작하기").frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .disabled(!CalixPreferences.validSchoolProfile(department: department, studentNumber: studentNumber))
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Calix Vesper")
        }
    }
}

private struct VesperThemeKey: EnvironmentKey { static let defaultValue = CalixTheme.aurora }
private extension EnvironmentValues {
    var vesperTheme: CalixTheme {
        get { self[VesperThemeKey.self] }
        set { self[VesperThemeKey.self] = newValue }
    }
}

extension CalixTheme {
    var accentSource: UIColor {
        UIColor(hue: hue, saturation: forcesDark ? 0.32 : 0.57, brightness: forcesDark ? 0.94 : 0.57, alpha: 1)
    }

    var accent: Color {
        let surface = UIColor(white: forcesDark ? 0.20 : 0.88, alpha: 1)
        return Color(uiColor: CalixContrast.foreground(accentSource, on: surface))
    }

    var swatch: LinearGradient {
        LinearGradient(colors: [
            Color(hue: hue, saturation: 0.50, brightness: 0.76),
            Color(hue: secondaryHue, saturation: 0.42, brightness: 0.49),
        ], startPoint: .bottomLeading, endPoint: .topTrailing)
    }
}

enum CalixContrast {
    static func ratio(_ first: UIColor, _ second: UIColor) -> Double {
        func luminance(_ color: UIColor) -> Double {
            let values = channels(color).map { value in
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * values[0] + 0.7152 * values[1] + 0.0722 * values[2]
        }
        let left = luminance(first), right = luminance(second)
        return (max(left, right) + 0.05) / (min(left, right) + 0.05)
    }

    static func foreground(_ color: UIColor, on surface: UIColor, minimum: Double = 4.5) -> UIColor {
        guard ratio(color, surface) < minimum else { return color }
        let target: Double = ratio(.white, surface) > ratio(.black, surface) ? 1 : 0
        let source = channels(color)
        func mix(_ weight: Double) -> UIColor {
            let values = source.map { $0 + (target - $0) * weight }
            return UIColor(red: values[0], green: values[1], blue: values[2], alpha: 1)
        }
        var low = 0.0, high = 1.0
        for _ in 0..<10 {
            let middle = (low + high) / 2
            if ratio(mix(middle), surface) < minimum { low = middle }
            else { high = middle }
        }
        return mix(high)
    }

    private static func channels(_ color: UIColor) -> [Double] {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [Double(red), Double(green), Double(blue)]
    }
}

private struct VesperBackdrop: View {
    let theme: CalixTheme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { proxy in
            let dark = colorScheme == .dark
            let radius = max(140, min(proxy.size.width, proxy.size.height))
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                if !reduceTransparency {
                    RadialGradient(
                        colors: [Color(hue: theme.hue, saturation: 0.57, brightness: dark ? 0.57 : 0.91)
                            .opacity(dark ? 0.20 : 0.15), .clear],
                        center: UnitPoint(x: 0.15, y: 0.10), startRadius: 0, endRadius: radius
                    )
                    RadialGradient(
                        colors: [Color(hue: theme.secondaryHue, saturation: 0.48, brightness: dark ? 0.61 : 0.94)
                            .opacity(dark ? 0.23 : 0.18), .clear],
                        center: UnitPoint(x: 0.95, y: 0.64), startRadius: 0, endRadius: radius * 0.88
                    )
                }
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct CalixHome: View {
    let library: CalixLibrary
    let openDeadlines: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            let pending = library.data.events.filter { !$0.done }
            let today = pending.filter { DeadlineGroup.classify($0.due, now: now) == .today }.ordered
            let overdue = pending.filter { DeadlineGroup.classify($0.due, now: now) == .overdue }.ordered
            let upcoming = pending.filter { DeadlineGroup.classify($0.due, now: now) == .week }.ordered
            VesperPage {
                HomeScheduleCard(date: now, preference: library.data.preferences, today: today.count, overdue: overdue.count, openDeadlines: openDeadlines)
                VesperSection(title: "오늘의 학습 계획") {
                    if today.count + overdue.count >= 3 {
                        Label("오늘 마감과 기한 경과 일정이 몰려 있습니다.", systemImage: "exclamationmark.triangle").font(.subheadline)
                    }
                    if today.isEmpty && overdue.isEmpty {
                        Text("오늘 확인할 일정이 없습니다.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach((overdue + today).prefix(5)) { EventLink(id: $0.id, library: library, card: true) }
                }
                if !upcoming.isEmpty {
                    VesperSection(title: "다가오는 일정") {
                        ForEach(upcoming.prefix(5)) { EventLink(id: $0.id, library: library, card: true) }
                    }
                }
                NavigationLink {
                    CalixCanvas(library: library)
                } label: {
                    Label(library.data.canvasID == nil ? "학교 계정 연결" : "학교 동기화", systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .vesperSurface()
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("Calix Vesper")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { NavigationLink { CalixCanvas(library: library) } label: { Label("학교 동기화", systemImage: "arrow.triangle.2.circlepath") } }
    }
}

struct VesperPage<Content: View>: View {
    @Environment(\.vesperTheme) private var theme
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) { content }
                .padding(.horizontal, 17)
                .padding(.top, 12)
                .padding(.bottom, 15)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .background { VesperBackdrop(theme: theme).ignoresSafeArea() }
    }
}

struct VesperSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.headline.weight(.semibold)).accessibilityAddTraits(.isHeader)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    func vesperSurface() -> some View {
        self.background(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.92), in: RoundedRectangle(cornerRadius: 15))
            .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(.primary.opacity(0.07)).allowsHitTesting(false) }
    }
}

private struct HomeScheduleCard: View {
    @Environment(\.locale) private var locale
    let date: Date
    let preference: CalixPreferences
    let today: Int
    let overdue: Int
    let openDeadlines: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(date.formatted(.dateTime.month().day().weekday().locale(locale)))
                .font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.80))
            VStack(alignment: .leading, spacing: 4) {
                if !preference.nickname.isEmpty { Text("\(preference.nickname)님").font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.86)) }
                Group {
                    if preference.homeMessage == "오늘의 학습 일정" { Text("오늘의 학습 일정") }
                    else { Text(preference.homeMessage) }
                }.font(.largeTitle.weight(.semibold)).tracking(-0.7).accessibilityAddTraits(.isHeader)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    metric("오늘 마감", today, "clock")
                    metric("기한 경과", overdue, "exclamationmark.circle")
                }
                VStack(spacing: 8) {
                    metric("오늘 마감", today, "clock")
                    metric("기한 경과", overdue, "exclamationmark.circle")
                }
            }
            Button(action: openDeadlines) {
                HStack(spacing: 7) {
                    Text("마감 보드 열기").font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                }.padding(.vertical, 7).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(21)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.white)
        .background { AuroraRibbons(theme: preference.theme).clipShape(RoundedRectangle(cornerRadius: 25)) }
        .overlay { RoundedRectangle(cornerRadius: 25).strokeBorder(.white.opacity(0.15)).allowsHitTesting(false) }
    }

    private func metric(_ title: LocalizedStringKey, _ count: Int, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol).font(.footnote)
            Text(count.formatted()).font(.title2.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 13))
        .accessibilityElement(children: .combine)
    }
}

private struct AuroraRibbons: View {
    let theme: CalixTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.scenePhase) private var scene

    var body: some View {
        ZStack {
            LinearGradient(colors: [
                Color(hue: theme.secondaryHue, saturation: 0.49, brightness: 0.29),
                Color(red: 0.07, green: 0.085, blue: 0.145)
            ], startPoint: .topTrailing, endPoint: .bottomLeading)
            if !reduceTransparency {
                TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduceMotion || scene != .active)) { frame in
                    Canvas { context, size in
                        let seconds = reduceMotion ? 0 : frame.date.timeIntervalSinceReferenceDate
                        let glide = CGFloat(sin(seconds * 0.43)) * size.height * 0.075
                        let hues = [theme.hue, theme.secondaryHue]
                        for (band, hue) in hues.enumerated() {
                            let offset = CGFloat(band) * size.height * 0.16
                            var path = Path()
                            path.move(to: CGPoint(x: size.width * 0.34, y: size.height * 0.86 + glide + offset))
                            path.addCurve(
                                to: CGPoint(x: size.width * 1.18, y: size.height * 0.15 + offset - glide),
                                control1: CGPoint(x: size.width * 0.61, y: size.height * 0.48 + offset - glide),
                                control2: CGPoint(x: size.width * 0.54, y: size.height * 0.18 + glide)
                            )
                            let color = Color(hue: hue, saturation: 0.51, brightness: 0.91)
                            context.drawLayer { glow in
                                glow.addFilter(.blur(radius: 19))
                                glow.stroke(path, with: .color(color.opacity(0.26)),
                                            style: StrokeStyle(lineWidth: size.width * 0.15, lineCap: .round))
                            }
                            context.drawLayer { edge in
                                edge.addFilter(.blur(radius: 7))
                                edge.stroke(path, with: .color(color.opacity(0.25)),
                                            style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            }
                        }
                    }
                }
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct CalixEvents: View {
    let library: CalixLibrary
    @State private var search = ""
    @State private var kind: EventKind?
    @State private var showCompleted = false
    @State private var starredOnly = false
    @State private var adding = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let visible = library.data.events.filter {
                (showCompleted || !$0.done) && (!starredOnly || $0.starred) && (kind == nil || kind == $0.kind) &&
                    (search.isEmpty || "\($0.title) \($0.course)".localizedCaseInsensitiveContains(search))
            }.ordered
            VesperPage {
                ForEach(DeadlineGroup.allCases) { group in
                    let items = visible.filter { DeadlineGroup.classify($0.due, now: context.date) == group }
                    if !items.isEmpty {
                        VesperSection(title: LocalizedStringKey(group.rawValue)) {
                            ForEach(items) { EventLink(id: $0.id, library: library, card: true) }
                        }
                    }
                }
                if visible.isEmpty { ContentUnavailableView("표시할 일정이 없습니다", systemImage: "calendar") }
            }
        }
        .navigationTitle("마감 보드")
        .searchable(text: $search, prompt: "일정, 과목 검색")
        .toolbar {
            Menu {
                Picker("일정 종류", selection: $kind) {
                    Text("전체").tag(nil as EventKind?)
                    ForEach(EventKind.allCases) { Text($0.rawValue).tag(Optional($0)) }
                }
                Toggle("완료 일정 포함", isOn: $showCompleted)
                Toggle("별표만 표시", isOn: $starredOnly)
            } label: { Label("필터", systemImage: "line.3.horizontal.decrease.circle") }
            Button { adding = true } label: { Label("일정 추가", systemImage: "plus") }
        }
        .sheet(isPresented: $adding) { NavigationStack { EventEditor(library: library, draft: CalixEvent(kind: .personal)) } }
    }
}

struct EventLink: View {
    @Environment(\.locale) private var locale
    let id: String
    let library: CalixLibrary
    var card = false

    var body: some View {
        if let event = library.data.events.first(where: { $0.id == id }) {
            NavigationLink {
                EventDetails(id: id, library: library)
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: event.done ? "checkmark.circle.fill" : event.starred ? "star.fill" : event.kind.symbol)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(library.data.preferences.theme.accent)
                        .frame(width: 35, height: 35)
                        .background(library.data.preferences.theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        let due = event.due?.formatted(.dateTime.month().day().hour().minute().locale(locale))
                            ?? String(localized: "기한 없음", locale: locale)
                        let detail = [event.course, due, event.done ? String(localized: "완료", locale: locale) : ""]
                        Text(detail.filter { !$0.isEmpty }.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if card { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
                }
                .padding(card ? 11 : 0)
                .contentShape(Rectangle())
                .background {
                    if card { RoundedRectangle(cornerRadius: 15).fill(Color(uiColor: .secondarySystemGroupedBackground)) }
                }
                .overlay {
                    if card { RoundedRectangle(cornerRadius: 15).strokeBorder(.primary.opacity(0.07)).allowsHitTesting(false) }
                }
            }
            .buttonStyle(.plain)
        }
    }
}

private struct EventDetails: View {
    @Environment(\.locale) private var locale
    let id: String
    let library: CalixLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var deleting = false

    var body: some View {
        if let event = library.data.events.first(where: { $0.id == id }) {
            Form {
                Section {
                    LabeledContent("과목", value: event.course.isEmpty ? "개인 일정" : event.course)
                    LabeledContent("유형", value: event.kind.rawValue)
                    LabeledContent("마감", value: event.due?.formatted(.dateTime.month().day().hour().minute().locale(locale)) ?? "기한 없음")
                    if let status = event.syncStatus {
                        let labels = ["missing": "미제출", "graded": "채점 완료", "late": "지각", "submitted": "제출 완료",
                                      "attendance": "출석", "present": "출석", "excused": "공결", "absent": "결석",
                                      "unverified": "시청 미확인"]
                        if let label = labels[status] { LabeledContent("상태", value: label) }
                    }
                    if let url = event.url { Link("Canvas에서 열기", destination: url) }
                    if let feedback = event.feedback { Text(feedback) }
                    if !event.note.isEmpty { Text(event.note) }
                }
                Section {
                    Button(event.done ? "완료 취소" : "완료로 표시") {
                        change { item in
                            item.done.toggle()
                            if item.remote { item.manualCompletion = item.done }
                        }
                    }
                    Button(event.starred ? "별표 해제" : "별표 표시") { change { $0.starred.toggle() } }
                    if !event.remote { Button("일정 삭제", role: .destructive) { deleting = true } }
                }
            }
            .navigationTitle(event.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("편집") { editing = true } }
            .sheet(isPresented: $editing) { NavigationStack { EventEditor(library: library, draft: event) } }
            .confirmationDialog("이 일정을 삭제할까요?", isPresented: $deleting, titleVisibility: .visible) {
                Button("삭제", role: .destructive) {
                    if library.update({ $0.events.removeAll { $0.id == id } }) { dismiss() }
                }
                if let series = event.seriesID {
                    Button("반복 일정 전체 삭제", role: .destructive) {
                        if library.update({ $0.events.removeAll { $0.seriesID == series } }) { dismiss() }
                    }
                }
            }
        }
    }

    private func change(_ edit: (inout CalixEvent) -> Void) {
        library.update { draft in
            if let index = draft.events.firstIndex(where: { $0.id == id }) { edit(&draft.events[index]) }
        }
    }
}

struct EventEditor: View {
    let library: CalixLibrary
    @State var draft: CalixEvent
    @State private var copies = 1
    @State private var interval = 7
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("일정") {
                TextField("제목", text: $draft.title)
                if !draft.remote {
                    TextField("과목", text: $draft.course)
                    Picker("유형", selection: $draft.kind) { ForEach(EventKind.allCases) { Text($0.rawValue).tag($0) } }
                    Toggle("마감 설정", isOn: Binding(get: { draft.due != nil }, set: {
                        draft.due = $0 ? .now : nil
                        if !$0 { draft.starts = nil }
                    }))
                    if draft.due != nil {
                        DatePicker("마감", selection: Binding(get: { draft.due ?? .now }, set: { draft.due = $0 }))
                        Toggle("시작일 설정", isOn: Binding(get: { draft.starts != nil }, set: {
                            draft.starts = $0 ? Calendar.current.startOfDay(for: draft.due ?? .now) : nil
                        }))
                        if let due = draft.due, draft.starts != nil {
                            DatePicker("시작일", selection: Binding(get: { draft.starts ?? due }, set: { draft.starts = $0 }),
                                       in: ...due, displayedComponents: .date)
                        }
                        if !library.data.events.contains(where: { $0.id == draft.id }) {
                            Stepper("반복 횟수 \(copies)회", value: $copies, in: 1...52)
                            if copies > 1 {
                                Picker("반복 간격", selection: $interval) {
                                    Text("매일").tag(1)
                                    Text("매주").tag(7)
                                    Text("격주").tag(14)
                                }
                            }
                        }
                    }
                }
                TextField("메모", text: $draft.note, axis: .vertical)
            }
        }
        .navigationTitle("일정 편집")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("저장") {
                    draft.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    if library.update({ data in
                        if let index = data.events.firstIndex(where: { $0.id == draft.id }) {
                            if draft.remote {
                                if data.events[index].title != draft.title {
                                    data.events[index].customTitle = draft.title
                                    data.events[index].title = draft.title
                                }
                                data.events[index].note = draft.note
                            }
                            else { data.events[index] = draft }
                        } else if !draft.remote {
                            guard copies > 1, let date = draft.due else { data.events.append(draft); return }
                            let series = UUID().uuidString
                            for index in 0..<copies {
                                guard let due = Calendar.current.date(byAdding: .day, value: index * interval, to: date) else { continue }
                                var item = draft
                                item.id = index == 0 ? draft.id : UUID().uuidString
                                item.due = due
                                item.starts = draft.starts.flatMap { Calendar.current.date(byAdding: .day, value: index * interval, to: $0) }
                                item.seriesID = series
                                data.events.append(item)
                            }
                        }
                    }) { dismiss() }
                }.disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                           (draft.starts ?? .distantPast) > (draft.due ?? .distantFuture))
            }
        }
    }
}

struct CalixCourseList: View {
    let library: CalixLibrary
    @State private var search = ""
    @State private var pendingOnly = false

    var body: some View {
        let groups = Dictionary(grouping: library.data.events) { $0.course.isEmpty ? "개인 일정" : $0.course }
        let names = groups.keys.sorted { $0.localizedCompare($1) == .orderedAscending }.filter { name in
            (search.isEmpty || name.localizedCaseInsensitiveContains(search)) &&
                (!pendingOnly || groups[name, default: []].contains { !$0.done })
        }
        VesperPage {
            Toggle("미완료 있는 과목", isOn: $pendingOnly)
                .font(.subheadline.weight(.medium))
                .padding(13).vesperSurface()
            ForEach(names, id: \.self) { name in
                let events = groups[name, default: []].ordered
                let done = events.filter(\.done).count
                VesperSection(title: LocalizedStringKey(name)) {
                    ProgressView(value: Double(done), total: Double(max(1, events.count))) {
                        Text("완료 \(done)/\(events.count)").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(13).vesperSurface()
                    ForEach(events) { EventLink(id: $0.id, library: library, card: true) }
                }
            }
            if names.isEmpty { ContentUnavailableView("표시할 과목이 없습니다", systemImage: "books.vertical") }
        }
        .navigationTitle("과목별 현황")
        .searchable(text: $search, prompt: "과목 검색")
    }
}

struct CalixCalendar: View {
    @Environment(\.locale) private var locale
    let library: CalixLibrary
    @State private var date = Date()
    @State private var holiday = ""
    @State private var editingHoliday = false
    @State private var adding = false

    var body: some View {
        let key = CalixData.dayKey(date)
        let events = library.data.events.filter { item in
            guard let due = item.due else { return false }
            let end = CalixData.dayKey(due)
            let start = item.starts.map(CalixData.dayKey) ?? end
            return start <= key && key <= end
        }.ordered
        VesperPage {
            DatePicker("날짜", selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding(12)
                .vesperSurface()
            VesperSection(title: LocalizedStringKey(date.formatted(.dateTime.month().day().weekday().locale(locale)))) {
                if let name = library.data.holidays[key] { Label(name, systemImage: "calendar.badge.checkmark") }
                if let name = library.data.offDays[key] { Label(name, systemImage: "moon.zzz") }
                if events.isEmpty { Text("일정 없음").foregroundStyle(.secondary) }
                ForEach(events) { EventLink(id: $0.id, library: library, card: true) }
            }
            Button("휴일 이름 편집") { holiday = library.data.holidays[key] ?? ""; editingHoliday = true }
                .font(.subheadline)
        }
        .navigationTitle("달력")
        .toolbar { Button { adding = true } label: { Label("일정 추가", systemImage: "plus") } }
        .alert("휴일 이름", isPresented: $editingHoliday) {
            TextField("이름", text: $holiday)
            Button("저장") { library.update { $0.holidays[key] = holiday.isEmpty ? nil : holiday } }
            Button("취소", role: .cancel) {}
        }
        .sheet(isPresented: $adding) { NavigationStack { EventEditor(library: library, draft: CalixEvent(kind: .personal, due: date)) } }
    }
}

private extension Array where Element == CalixEvent {
    var ordered: Self {
        sorted { a, b in
            let earlier = a.due ?? .distantFuture
            let later = b.due ?? .distantFuture
            return earlier == later ? a.title.localizedCompare(b.title) == .orderedAscending : earlier < later
        }
    }
}
