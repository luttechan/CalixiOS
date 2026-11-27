import SwiftUI
import UIKit

struct CalixChecklist: View {
    let library: CalixLibrary
    @State private var editing: CalixTask?
    @State private var search = ""
    @State private var importEvents = false
    @State private var editStatuses = false
    @State private var sortField = TaskSort.title
    @State private var ascending = true

    private enum TaskSort: String, CaseIterable, Identifiable {
        case title = "할 일", due = "기한", section = "분류", role = "내 역할", instructor = "담당 교수", status = "상태", note = "비고"
        var id: Self { self }
        func compare(_ left: CalixTask, _ right: CalixTask) -> ComparisonResult {
            switch self {
            case .title: left.title.localizedStandardCompare(right.title)
            case .due: (left.due ?? .distantFuture).compare(right.due ?? .distantFuture)
            case .section: left.section.localizedStandardCompare(right.section)
            case .role: (left.role ?? "").localizedStandardCompare(right.role ?? "")
            case .instructor: (left.instructor ?? "").localizedStandardCompare(right.instructor ?? "")
            case .status: (left.status ?? "").localizedStandardCompare(right.status ?? "")
            case .note: (left.note ?? "").localizedStandardCompare(right.note ?? "")
            }
        }
    }

    private var statuses: [CalixTaskStatus] { library.data.taskStatuses ?? CalixTaskStatus.defaults }

    var body: some View {
        let visible = library.data.tasks.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
        let sorted = visible.sorted { left, right in
            let order = sortField.compare(left, right)
            if order == .orderedSame { return left.id.uuidString < right.id.uuidString }
            return order == (ascending ? .orderedAscending : .orderedDescending)
        }
        let groups = Dictionary(grouping: sorted, by: \.section)
        List {
            ForEach(groups.keys.sorted(), id: \.self) { section in
                Section(section) {
                    ForEach(groups[section, default: []]) { task in
                        Button { editing = task } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(task.title).foregroundStyle(.primary)
                                    let name = task.status ?? (task.done ? "완료" : "계획")
                                    let tint = statuses.first { $0.name == name }?.tint
                                    Text(name).font(.caption).foregroundStyle(.secondary)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(CalixStatusEditor.color(tint ?? "gray").opacity(0.15), in: Capsule())
                                }
                            } icon: { Image(systemName: task.done ? "checkmark.circle.fill" : "circle") }
                        }
                        .swipeActions(edge: .leading) { Button(task.done ? "완료 취소" : "완료") { toggle(task) } }
                        .swipeActions {
                            Button("삭제", role: .destructive) { library.update { $0.tasks.removeAll { $0.id == task.id } } }
                        }
                    }
                }
            }
            if groups.isEmpty { ContentUnavailableView("표시할 할 일이 없습니다", systemImage: "checklist") }
        }
        .navigationTitle("체크리스트")
        .searchable(text: $search)
        .toolbar {
            Menu {
                Picker("정렬", selection: $sortField) {
                    ForEach(TaskSort.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("오름차순", isOn: $ascending)
                Button("상태 편집") { editStatuses = true }
            } label: { Label("체크리스트 관리", systemImage: "ellipsis.circle") }
            Button { importEvents = true } label: { Label("일정에서 가져오기", systemImage: "square.and.arrow.down") }
            Button { editing = CalixTask() } label: { Label("할 일 추가", systemImage: "plus") }
        }
        .sheet(isPresented: $editStatuses) {
            NavigationStack { CalixStatusEditor(library: library) }
        }
        .sheet(isPresented: $importEvents) {
            NavigationStack {
                let sources = Set(library.data.tasks.compactMap(\.sourceID))
                let available = library.data.events.filter { !sources.contains($0.id) }
                List {
                    ForEach(available) { source in
                        Button { addTasks([source]) } label: { Label(source.title, systemImage: source.kind.symbol) }
                    }
                }
                .navigationTitle("일정에서 가져오기")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("닫기") { importEvents = false } }
                    ToolbarItem(placement: .confirmationAction) { Button("일괄 가져오기") { addTasks(available) }.disabled(available.isEmpty) }
                }
            }
        }
        .sheet(item: $editing) { item in
            EditForm(title: "할 일", initial: item, valid: { !$0.title.trimmed.isEmpty }) { draft in
                TextField("제목", text: draft.title)
                TextField("목록 이름", text: draft.section)
                Picker("상태", selection: Binding(get: { draft.wrappedValue.status ?? (draft.wrappedValue.done ? "완료" : "계획") }, set: { draft.wrappedValue.status = $0 })) {
                    ForEach(statuses) { status in Label(status.name, systemImage: "circle.fill").tag(status.name) }
                }
                Toggle("마감 설정", isOn: Binding(get: { draft.wrappedValue.due != nil }, set: { draft.wrappedValue.due = $0 ? .now : nil }))
                if draft.wrappedValue.due != nil {
                    DatePicker("마감", selection: Binding(get: { draft.wrappedValue.due ?? .now }, set: { draft.wrappedValue.due = $0 }))
                }
                TextField("담당", text: optionalText(draft.role))
                TextField("교수", text: optionalText(draft.instructor))
                TextField("메모", text: optionalText(draft.note), axis: .vertical)
            } save: { item in
                var item = item
                item.title = item.title.trimmed
                item.section = item.section.trimmed.isEmpty ? "기본" : item.section.trimmed
                if let name = item.status, let status = statuses.first(where: { $0.name == name }) { item.done = status.complete }
                return library.update { $0.tasks.replace(item) }
            }
        }
    }

    private func addTasks(_ events: [CalixEvent]) {
        library.update { data in
            var existing = Set(data.tasks.compactMap(\.sourceID))
            for event in events where existing.insert(event.id).inserted {
                data.tasks.append(CalixTask(title: event.title, section: event.course.isEmpty ? "기본" : event.course,
                                           done: event.done, due: event.due, note: event.note, sourceID: event.id))
            }
        }
    }

    private func toggle(_ task: CalixTask) {
        library.update { data in
            if let index = data.tasks.firstIndex(where: { $0.id == task.id }) {
                data.tasks[index].done.toggle()
                data.tasks[index].status = data.tasks[index].done ? "완료" : "계획"
            }
        }
    }

    private func optionalText(_ value: Binding<String?>) -> Binding<String> {
        Binding(get: { value.wrappedValue ?? "" }, set: { value.wrappedValue = $0 })
    }
}

private struct CalixStatusEditor: View {
    let library: CalixLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var tint = "blue"
    @State private var complete = false
    private let colors = ["gray", "blue", "purple", "green", "orange", "pink"]
    private var statuses: [CalixTaskStatus] { library.data.taskStatuses ?? CalixTaskStatus.defaults }

    static func color(_ value: String) -> Color {
        switch value {
        case "blue": .blue
        case "purple": .purple
        case "green": .green
        case "orange": .orange
        case "pink": .pink
        default: .gray
        }
    }

    var body: some View {
        Form {
            Section("등록된 상태") {
                ForEach(statuses) { status in
                    Label {
                        Text(status.name)
                    } icon: {
                        Image(systemName: "circle.fill").foregroundStyle(Self.color(status.tint))
                    }
                }
            }
            Section("상태 추가") {
                TextField("이름", text: $name)
                Picker("색상", selection: $tint) {
                    ForEach(colors, id: \.self) { value in
                        Label(value.capitalized, systemImage: "circle.fill").tint(Self.color(value)).tag(value)
                    }
                }
                Toggle("완료 상태", isOn: $complete)
                Button("추가") {
                    let label = String(name.trimmed.prefix(32))
                    let choice = CalixTaskStatus(name: label, tint: tint, complete: complete)
                    if library.update({ $0.taskStatuses = statuses + [choice] }) { name = "" }
                }.disabled(name.trimmed.isEmpty || statuses.count >= 30 || statuses.contains { $0.name == String(name.trimmed.prefix(32)) })
            }
        }
        .navigationTitle("상태 편집")
        .toolbar { Button("닫기") { dismiss() } }
    }
}

struct TimetableAppearance: Codable, Equatable {
    enum Mode: String, Codable { case auto, manual, custom }
    var theme: Int
    var mode: Mode = .auto
    var colors: [String: String] = [:]
    var slots: [String] = []

    var palette: TimetablePalette { TimetablePalette.all.indices.contains(theme) ? TimetablePalette.all[theme] : TimetablePalette.all[0] }

    func color(_ lesson: CalixLesson, slot: Int) -> Color {
        let fallback = palette.swatch(slot)
        let color: UIColor
        switch mode {
        case .auto: color = fallback
        case .manual: color = TimetablePalette.hex(lesson.auroraColor) ?? fallback
        case .custom:
            let key = lesson.auroraCourseID.map { "course:" + String($0) } ?? "title:" + String(lesson.title.trimmed.prefix(200))
            color = TimetablePalette.hex(colors[key]) ??
                (slots.indices.contains(slot) ? TimetablePalette.hex(slots[slot]) : nil) ?? fallback
        }
        return Color(uiColor: CalixContrast.foreground(color, on: palette.rowSurface, minimum: 3))
    }
}

struct AuroraTimetableColors: Codable {
    let base: TimetableAppearance
    let terms: [String: TimetableAppearance]
    let presets: [String: TimetableAppearance]
}

struct TimetablePalette {
    let name: String
    let surface: String
    let accent: String
    let hues: [Double]
    let dark: Bool

    static let all = [
        Self(name: "오로라", surface: "#171c2d", accent: "#b6a3f2", hues: [282, 195, 160, 330, 215, 32, 256, 130], dark: true),
        Self(name: "새벽", surface: "#fff3ef", accent: "#a45573", hues: [348, 28, 274, 18, 315, 44, 220, 162], dark: false),
        Self(name: "조수", surface: "#edf8fb", accent: "#207b92", hues: [195, 221, 165, 242, 139, 274, 31, 321], dark: false),
        Self(name: "자정", surface: "#151b2c", accent: "#9aa7ff", hues: [234, 196, 276, 319, 166, 28, 355, 86], dark: true),
        Self(name: "장미", surface: "#fff1f5", accent: "#ad4871", hues: [340, 20, 291, 357, 310, 35, 200, 157], dark: false),
        Self(name: "라벤더", surface: "#f6f1fd", accent: "#7855aa", hues: [273, 320, 228, 145, 299, 30, 191, 357], dark: false),
        Self(name: "민트", surface: "#edf9f3", accent: "#287856", hues: [151, 183, 112, 219, 82, 270, 33, 320], dark: false),
        Self(name: "숲", surface: "#1b2921", accent: "#a7cb84", hues: [91, 151, 45, 183, 119, 25, 209, 320], dark: true),
        Self(name: "모래", surface: "#faf4e8", accent: "#98662f", hues: [33, 54, 17, 143, 75, 200, 341, 268], dark: false),
        Self(name: "호박색", surface: "#fff5dd", accent: "#96600b", hues: [40, 23, 64, 352, 92, 186, 285, 140], dark: false),
        Self(name: "테라코타", surface: "#faede6", accent: "#a45137", hues: [17, 354, 46, 125, 326, 187, 254, 74], dark: false),
        Self(name: "오디", surface: "#2b1e30", accent: "#e1a4cf", hues: [315, 271, 354, 20, 227, 163, 191, 50], dark: true),
        Self(name: "슬레이트", surface: "#eef2f6", accent: "#546980", hues: [215, 192, 260, 155, 316, 26, 345, 90], dark: false),
        Self(name: "먹색", surface: "#202228", accent: "#b4bac7", hues: [217, 278, 166, 37, 331, 193, 113, 10], dark: true),
        Self(name: "라임", surface: "#f6f8e6", accent: "#617521", hues: [78, 133, 51, 178, 107, 29, 223, 313], dark: false),
        Self(name: "종이", surface: "#f7f5f0", accent: "#786d65", hues: [26, 210, 155, 289, 352, 78, 185, 239], dark: false),
    ]

    static func matching(_ theme: CalixTheme) -> Int {
        switch theme {
        case .aurora: return 0
        case .glacier, .sky: return 2
        case .vesper: return 3
        case .pink: return 4
        case .purple, .lavender: return 5
        case .mint: return 6
        case .amber: return 9
        case .peach: return 10
        case .dark: return 13
        case .olive: return 14
        }
    }

    var rowSurface: UIColor { UIColor(white: dark ? 0.16 : 1, alpha: 1) }

    var readableAccent: UIColor {
        let background = UIColor(white: dark ? 0.20 : 0.87, alpha: 1)
        return CalixContrast.foreground(Self.hex(accent) ?? .label, on: background)
    }

    static func hex(_ text: String?) -> UIColor? {
        guard let text, text.count == 7, text.first == "#", let value = UInt32(text.dropFirst(), radix: 16) else { return nil }
        return UIColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    }

    func swatch(_ index: Int) -> UIColor {
        let hue = hues[index % hues.count]
        func channel(_ offset: Double) -> Double {
            let wave = (offset + hue / 30).truncatingRemainder(dividingBy: 12)
            return (dark ? 0.68 : 0.43) - (dark ? 0.22 : 0.19) * max(-1, min(wave - 3, 9 - wave, 1))
        }
        return UIColor(red: channel(0), green: channel(8), blue: channel(4), alpha: 1)
    }
}

struct CalixTimetable: View {
    let library: CalixLibrary
    @Environment(\.scenePhase) private var phase
    @Environment(\.locale) private var locale
    @State private var term: String?
    @State private var day = Calendar.current.component(.weekday, from: .now)
    @State private var editing: CalixLesson?
    @State private var offDate = Date()
    @State private var showOffDay = false
    @State private var showTheme = false
    @State private var authorized = false
    @State private var showWeeklyOffDays = false
    @State private var weeklyOffDays: Set<Int> = []
    @State private var detail: CalixLesson?
    @State private var editAfterDetail: CalixLesson?
    @State private var showTerm = false
    @State private var termName = ""

    init(library: CalixLibrary) {
        self.library = library
        #if DEBUG
        if CalixScreenshot.page == "timetable" { _day = State(initialValue: 2) }
        #endif
    }

    var body: some View {
        let selected = term ?? library.data.preferences.mainTerm
        let terms = Set(library.data.lessons.map(\.term) + [selected, library.data.preferences.mainTerm] +
            Array((library.data.preferences.timetableOffDays ?? [:]).keys)).sorted()
        let items = library.data.lessons.filter { $0.term == selected }
        let offDays = Set((library.data.preferences.timetableOffDays?[selected] ?? []).filter { (1...7).contains($0) })
        let online = items.filter(\.online).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let imported = library.data.auroraTimetableColors
        let override = library.data.preferences.timetableAppearance?[selected]
        let appearance = override ?? imported?.terms[selected] ?? imported?.base ??
            TimetableAppearance(theme: TimetablePalette.matching(library.data.preferences.theme))
        let courseSlots: [String: Int] = {
            var slots: [String: Int] = [:]
            for item in items where slots[courseKey(item)] == nil { slots[courseKey(item)] = slots.count % 8 }
            return slots
        }()
        Group {
            if library.data.preferences.lockTimetable && !authorized {
                ProtectedView(library: library, title: "시간표", access: $authorized)
            } else {
                VesperPage {
                    HStack(spacing: 8) {
                        Menu {
                            ForEach(terms, id: \.self) { name in
                                Button { term = name } label: {
                                    if name == selected { Label(LocalizedStringKey(name), systemImage: "checkmark") }
                                    else { Text(LocalizedStringKey(name)) }
                                }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Text(LocalizedStringKey(selected))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .font(.subheadline.weight(.semibold))
                                    .layoutPriority(1)
                                Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.leading, 7)
                            .contentShape(Rectangle())
                        }
                        .accessibilityLabel("학기")
                        .accessibilityValue(Text(LocalizedStringKey(selected)))
                        Menu {
                            Button("공강 설정", systemImage: "sun.max") {
                                weeklyOffDays = offDays
                                showWeeklyOffDays = true
                            }
                            Button("시간표 테마", systemImage: "paintpalette") { showTheme = true }
                            Button("학기 추가", systemImage: "calendar.badge.plus") { termName = ""; showTerm = true }
                            Button("휴강일 관리", systemImage: "calendar.badge.clock") { showOffDay = true }
                            if selected != library.data.preferences.mainTerm {
                                Button("기본 학기로 설정", systemImage: "pin") { library.update { $0.preferences.mainTerm = selected } }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle").font(.title3).frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel("시간표 설정")
                    }
                    .padding(.horizontal, 8)
                    .vesperSurface()
                    TimetableWeekGrid(layout: TimetableGridLayout(lessons: items, offDays: offDays), offDays: offDays,
                                      palette: appearance.palette) { item in
                        appearance.color(item, slot: courseSlots[courseKey(item)] ?? 0)
                    } open: { detail = $0 }
                    if !online.isEmpty {
                        VesperSection(title: "비대면") {
                            ForEach(online) { item in
                                row(item, color: appearance.color(item, slot: courseSlots[courseKey(item)] ?? 0))
                                    .padding(12).vesperSurface()
                            }
                        }
                    }
                }
                .toolbar { Button { editing = CalixLesson(term: selected, weekday: day) } label: { Label("수업 추가", systemImage: "plus") } }
            }
        }
        .navigationTitle("시간표")
        .onChange(of: phase) { _, newPhase in
            if newPhase == .background {
                authorized = false; editing = nil; detail = nil; editAfterDetail = nil
                showOffDay = false; showTheme = false; showWeeklyOffDays = false; showTerm = false
            }
        }
        .sheet(isPresented: $showWeeklyOffDays) {
            NavigationStack {
                Form {
                    ForEach(TimetableGridLayout.weekdays, id: \.self) { index in
                        Toggle(dayLabel(index), isOn: Binding(get: { weeklyOffDays.contains(index) }, set: { enabled in
                            if enabled { weeklyOffDays.insert(index) } else { weeklyOffDays.remove(index) }
                        }))
                    }
                }
                .navigationTitle("공강 설정")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("취소") { showWeeklyOffDays = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("저장") {
                            if library.update({ data in
                                var settings = data.preferences.timetableOffDays ?? [:]
                                settings[selected] = weeklyOffDays.sorted()
                                data.preferences.timetableOffDays = settings
                            }) { showWeeklyOffDays = false }
                        }
                    }
                }
            }
        }
        .alert("학기 추가", isPresented: $showTerm) {
            TextField("학기 이름", text: $termName)
            Button("취소", role: .cancel) {}
            Button("추가") {
                let name = String(termName.trimmed.prefix(40))
                if library.update({ data in
                    var settings = data.preferences.timetableOffDays ?? [:]
                    settings[name] = settings[name] ?? []
                    data.preferences.timetableOffDays = settings
                }) { term = name }
            }.disabled(termName.trimmed.isEmpty)
        }
        .sheet(item: $detail, onDismiss: {
            if let item = editAfterDetail { editing = item; editAfterDetail = nil }
        }) { item in
            TimetableLessonDetails(library: library, lesson: item, day: dayLabel(item.weekday)) {
                editAfterDetail = item
                detail = nil
            } remove: {
                if library.update({ $0.lessons.removeAll { $0.id == item.id } }) { detail = nil }
            }
        }
        .sheet(isPresented: $showTheme) {
            NavigationStack {
                List {
                    themeButton(imported == nil ? "화면 테마에 맞춤" : "Aurora 테마 사용",
                                style: nil, current: override, term: selected)
                    if let imported, !imported.presets.isEmpty {
                        Section("Aurora 프리셋") {
                            ForEach(imported.presets.keys.sorted(), id: \.self) { name in
                                themeButton(LocalizedStringKey(name), style: imported.presets[name], current: override, term: selected)
                            }
                        }
                    }
                    ForEach([false, true], id: \.self) { dark in
                        Section(dark ? LocalizedStringKey("어두운 테마") : LocalizedStringKey("밝은 테마")) {
                            ForEach(TimetablePalette.all.indices.filter { TimetablePalette.all[$0].dark == dark }, id: \.self) { index in
                                themeButton(LocalizedStringKey(TimetablePalette.all[index].name),
                                            style: TimetableAppearance(theme: index), current: override, term: selected)
                            }
                        }
                    }
                }
                .navigationTitle("시간표 테마")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { showTheme = false } } }
            }
        }
        .sheet(item: $editing) { lesson in
            EditForm(title: "수업 편집", initial: lesson, valid: { !$0.title.trimmed.isEmpty && !$0.term.trimmed.isEmpty && ($0.online || $0.start < $0.end) }) { item in
                TextField("수업 이름", text: item.title)
                TextField("학기", text: item.term)
                TextField("교수", text: item.lecturer)
                TextField("강의실", text: item.room)
                Toggle("비대면", isOn: item.online)
                if !item.wrappedValue.online {
                    Picker("요일", selection: item.weekday) {
                        ForEach(TimetableGridLayout.weekdays, id: \.self) { Text(dayLabel($0)).tag($0) }
                    }
                    DatePicker("시작", selection: clock(item.start), displayedComponents: .hourAndMinute)
                    DatePicker("종료", selection: clock(item.end), displayedComponents: .hourAndMinute)
                }
            } save: { item in
                var item = item
                item.title = item.title.trimmed
                item.term = item.term.trimmed
                if library.update({ $0.lessons.replace(item) }) { term = item.term; day = item.weekday; return true }
                return false
            }
        }
        .sheet(isPresented: $showOffDay) {
            NavigationStack {
                Form {
                    DatePicker("날짜", selection: $offDate, displayedComponents: .date)
                    let key = CalixData.dayKey(offDate)
                    if library.data.offDays[key] == nil {
                        Button("휴강일로 지정") { library.update { $0.offDays[key] = "휴강" } }
                    } else {
                        Button("휴강일 지정 해제") { library.update { $0.offDays[key] = nil } }
                    }
                }
                .navigationTitle("휴강일")
                .toolbar { Button("닫기") { showOffDay = false } }
            }
        }
    }

    private func courseKey(_ item: CalixLesson) -> String {
        item.auroraCourseID.map { "course:" + String($0) } ?? "title:" + item.title.trimmed
    }

    private func themeButton(_ title: LocalizedStringKey, style: TimetableAppearance?,
                             current: TimetableAppearance?, term: String) -> some View {
        Button {
            if library.update({ data in
                var appearances = data.preferences.timetableAppearance ?? [:]
                appearances[term] = style
                data.preferences.timetableAppearance = appearances.isEmpty ? nil : appearances
            }) { showTheme = false }
        } label: {
            HStack(spacing: 12) {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if let style {
                    HStack(spacing: 4) {
                        ForEach(0..<3) { index in
                            let swatch = TimetablePalette.hex(style.slots.indices.contains(index) ? style.slots[index] : nil)
                                ?? style.palette.swatch(index)
                            Circle().fill(Color(uiColor: swatch)).frame(width: 13, height: 13)
                        }
                    }
                    .accessibilityHidden(true)
                }
                if style == current { Image(systemName: "checkmark").fontWeight(.semibold) }
            }
        }
        .accessibilityAddTraits(style == current ? .isSelected : [])
    }

    private func row(_ item: CalixLesson, color: Color) -> some View {
        Button { detail = item } label: {
            HStack(spacing: 11) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3, height: 30).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).foregroundStyle(.primary)
                    if !item.online { Text("\(timetableTime(item.start))–\(timetableTime(item.end))").monospacedDigit().foregroundStyle(.secondary) }
                    let details = [item.room, item.lecturer].filter { !$0.isEmpty }
                    if !details.isEmpty { Text(details.joined(separator: ", ")).foregroundStyle(.secondary) }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func clock(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0, of: .now) ?? .now
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        })
    }

    private func dayLabel(_ day: Int) -> String {
        Calendar(identifier: .gregorian).localizedWeekday(day, locale: locale, short: false)
    }
}

private extension Calendar {
    func localizedWeekday(_ index: Int, locale: Locale, short: Bool) -> String {
        var calendar = self
        calendar.locale = locale
        let symbols = short ? calendar.shortStandaloneWeekdaySymbols : calendar.standaloneWeekdaySymbols
        return symbols.indices.contains(index - 1) ? symbols[index - 1] : ""
    }
}

private func timetableTime(_ minutes: Int) -> String {
    String(format: "%02d:%02d", minutes / 60, minutes % 60)
}

private struct TimetableWeekGrid: View {
    @Environment(\.locale) private var locale
    @ScaledMetric(relativeTo: .subheadline) private var hour: CGFloat = 46
    @ScaledMetric(relativeTo: .caption2) private var minimumDayWidth: CGFloat = 56
    let layout: TimetableGridLayout
    let offDays: Set<Int>
    let palette: TimetablePalette
    let color: (CalixLesson) -> Color
    let open: (CalixLesson) -> Void
    private let gutter: CGFloat = 39

    private var hours: Int { (layout.end - layout.start) / 60 }
    private var accent: Color { Color(uiColor: palette.readableAccent) }
    private var divider: Color { Color.primary.opacity(palette.dark ? 0.16 : 0.12) }

    var body: some View {
        let dayHeight = CGFloat(hours) * hour
        GeometryReader { geometry in
            let width = max(minimumDayWidth, (geometry.size.width - gutter) / CGFloat(layout.days.count))
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Color.clear.frame(height: 38)
                        ForEach(0..<hours, id: \.self) { index in
                            Text(timetableTime(layout.start + index * 60))
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: hour, alignment: .topTrailing)
                                .padding(.trailing, 4)
                        }
                    }
                    .frame(width: gutter)
                    .accessibilityHidden(true)
                    ForEach(layout.days, id: \.self) { day in
                        column(day, width: width, height: dayHeight)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .frame(height: dayHeight + 38)
        .background(Color(uiColor: TimetablePalette.hex(palette.surface) ?? palette.rowSurface))
        .clipShape(RoundedRectangle(cornerRadius: 15))
        .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(divider).allowsHitTesting(false) }
        .environment(\.colorScheme, palette.dark ? .dark : .light)
    }

    private func column(_ day: Int, width: CGFloat, height: CGFloat) -> some View {
        let free = offDays.contains(day)
        let name = Calendar(identifier: .gregorian).localizedWeekday(day, locale: locale, short: true)
        return VStack(spacing: 0) {
            Text(name).font(.caption.weight(.semibold)).lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 38)
                .foregroundStyle(free ? accent : Color.primary)
                .background(divider.opacity(0.32))
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(0..<hours, id: \.self) { _ in
                        Rectangle().fill(divider).frame(height: 1)
                            .frame(height: hour, alignment: .top)
                    }
                }
                .accessibilityHidden(true)
                if free {
                    VStack(spacing: 6) {
                        Image(systemName: "sun.max").font(.headline).accessibilityHidden(true)
                        Text("공강").font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(accent)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 18)
                }
                ForEach(layout.slots[day, default: []]) { slot in
                    let segment = width / CGFloat(slot.lanes)
                    let duration = CGFloat(slot.lesson.end - slot.lesson.start) / 60 * hour
                    lessonTile(slot.lesson, width: max(1, segment - 4), height: max(1, duration - 3))
                        .offset(x: CGFloat(slot.lane) * segment + 2,
                                y: CGFloat(slot.lesson.start - layout.start) / 60 * hour + 1.5)
                }
            }
            .frame(height: height)
        }
        .frame(width: width)
        .background(free ? accent.opacity(0.095) : .clear)
        .overlay(alignment: .leading) { Rectangle().fill(divider).frame(width: 1).allowsHitTesting(false) }
    }

    private func lessonTile(_ lesson: CalixLesson, width: CGFloat, height: CGFloat) -> some View {
        let tint = color(lesson)
        let time = "\(timetableTime(lesson.start))–\(timetableTime(lesson.end))"
        return Button { open(lesson) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(lesson.title).font(.caption2.weight(.semibold))
                    .lineLimit(height >= 43 ? 2 : 1)
                if height >= 62, width >= 53 {
                    Text(timetableTime(lesson.start)).font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .minimumScaleFactor(0.82)
            .padding(.horizontal, 5)
            .frame(width: width, height: height, alignment: .leading)
            .background { Color(uiColor: palette.rowSurface).overlay(tint.opacity(0.12)) }
            .overlay(alignment: .leading) { Rectangle().fill(tint).frame(width: 2) }
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(lesson.title))
        .accessibilityValue(Text(time))
    }
}

private struct TimetableLessonDetails: View {
    @Environment(\.dismiss) private var dismiss
    let library: CalixLibrary
    let lesson: CalixLesson
    let day: String
    let edit: () -> Void
    let remove: () -> Void
    @State private var showDelete = false
    @State private var filter = 0

    var body: some View {
        let className = library.data.canvasCourses?[lesson.auroraCourseID.map(String.init) ?? ""]?.name ?? lesson.title
        let related = library.data.events.filter { event in
            let courseID = event.id.split(separator: ":").dropFirst().first.map(String.init)
            let matches = lesson.auroraCourseID.map { courseID == String($0) } ?? false
            return event.remote && (matches || event.course == className) &&
                (filter == 1 || event.done == (filter == 2))
        }.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
        NavigationStack {
            List {
                Section {
                    LabeledContent("교수", value: lesson.lecturer.isEmpty ? "—" : lesson.lecturer)
                    if lesson.online { LabeledContent("시간") { Text("비대면") } }
                    else { LabeledContent("시간", value: "\(day) \(timetableTime(lesson.start))–\(timetableTime(lesson.end))") }
                    LabeledContent("강의실", value: lesson.room.isEmpty ? "—" : lesson.room)
                }
                Picker("상태", selection: $filter) {
                    Text("미완료").tag(0); Text("전체").tag(1); Text("완료").tag(2)
                }.pickerStyle(.segmented)
                ForEach([EventKind.assignment, .video], id: \.self) { kind in
                    Section(LocalizedStringKey(kind.rawValue)) {
                        let events = related.filter { $0.kind == kind }
                        if events.isEmpty { Text("일정 없음").foregroundStyle(.secondary) }
                        ForEach(events) { item in EventLink(id: item.id, library: library) }
                    }
                }
                Button("수업 삭제", role: .destructive) { showDelete = true }
            }
            .navigationTitle(lesson.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("편집", action: edit) }
            }
            .confirmationDialog("수업을 삭제하시겠습니까?", isPresented: $showDelete, titleVisibility: .visible) {
                Button("삭제", role: .destructive, action: remove)
            }
        }
    }
}

struct CalixGrades: View {
    let library: CalixLibrary
    @Environment(\.scenePhase) private var phase
    @State private var authorized = false
    @State private var term: String?
    @State private var editing: CalixGrade?
    @State private var search = ""
    @State private var showReset = false

    init(library: CalixLibrary) {
        self.library = library
        #if DEBUG
        if CalixScreenshot.page == "grades" { _authorized = State(initialValue: true) }
        #endif
    }

    var body: some View {
        let selected = term ?? library.data.preferences.mainTerm
        let scale = library.data.gradeScales?[selected] ?? library.data.preferences.gradeScale
        let items = library.data.grades.filter { $0.term == selected }
        let roster = Array((library.data.canvasCourses ?? [:]).values)
        let terms = Set(library.data.grades.map(\.term) + roster.map(\.term) + [selected, library.data.preferences.mainTerm]).sorted()
        let registeredIDs = Set(items.compactMap(\.canvasCourseID))
        let registeredNames = Set(items.filter { $0.canvasCourseID == nil }.map { $0.title.trimmed })
        let importable = roster.filter { $0.term == selected && !registeredIDs.contains($0.id) && !registeredNames.contains($0.name.trimmed) }
        let included = items.filter { $0.excluded != true }
        let credits = included.filter { gradePoints($0.mark, scale: scale) != nil }.reduce(0.0) { $0 + $1.credits }
        let points = included.reduce(0.0) { $0 + (gradePoints($1.mark, scale: scale) ?? 0) * $1.credits }
        Group {
            if authorized {
                List {
                    Picker("학기", selection: Binding(get: { selected }, set: { term = $0 })) {
                        ForEach(terms, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("평점 기준", selection: Binding(get: { scale }, set: { value in
                        library.update {
                            var scales = $0.gradeScales ?? [:]
                            scales[selected] = value
                            $0.gradeScales = scales
                        }
                    })) {
                        ForEach([4.5, 4.3, 4.0], id: \.self) { Text($0.formatted(.number.precision(.fractionLength(1)))).tag($0) }
                    }
                    LabeledContent("평균 평점", value: credits > 0 ? (points / credits).formatted(.number.precision(.fractionLength(2))) : "–")
                    LabeledContent("등록 학점", value: included.reduce(0.0) { $0 + $1.credits }.formatted())
                    LabeledContent("취득 학점", value: included.filter { $0.mark == "P" || (gradePoints($0.mark, scale: scale) ?? 0) > 0 }.reduce(0.0) { $0 + $1.credits }.formatted())
                    ForEach(items.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }.sorted { $0.title < $1.title }) { item in
                        Button { editing = item } label: { LabeledContent(item.title, value: "\(item.mark) · \(item.credits.formatted())학점") }
                            .swipeActions { Button("삭제", role: .destructive) { library.update { $0.grades.removeAll { $0.id == item.id } } } }
                    }
                }
                .searchable(text: $search, prompt: "과목 검색")
                .toolbar {
                    Button { editing = CalixGrade(term: selected) } label: { Label("과목 추가", systemImage: "plus") }
                    Menu {
                        Button("Canvas 과목 일괄 가져오기") {
                            library.update { data in
                                data.grades.append(contentsOf: importable.sorted { $0.name < $1.name }.map {
                                    CalixGrade(title: $0.name, term: selected, credits: 0, mark: "", canvasCourseID: $0.id)
                                })
                            }
                        }.disabled(importable.isEmpty)
                        Button("초기화", role: .destructive) { showReset = true }.disabled(library.data.grades.isEmpty)
                    } label: { Label("학점 관리", systemImage: "ellipsis.circle") }
                }
                .confirmationDialog("학점 기록을 초기화할까요?", isPresented: $showReset, titleVisibility: .visible) {
                    Button("현재 학기 초기화", role: .destructive) {
                        library.update { data in
                            data.grades.removeAll { $0.term == selected }
                            data.gradeScales?.removeValue(forKey: selected)
                        }
                    }
                    Button("전체 초기화", role: .destructive) {
                        library.update { data in data.grades.removeAll(); data.gradeScales = nil }
                    }
                }
            } else {
                ProtectedView(library: library, title: "학점 계산기", access: $authorized)
            }
        }
        .navigationTitle("학점 계산기")
        .onChange(of: phase) { _, value in if value == .background { authorized = false; editing = nil } }
        .sheet(item: $editing) { item in
            EditForm(title: "학점 편집", initial: item, valid: { !$0.title.trimmed.isEmpty && !$0.term.trimmed.isEmpty }) { draft in
                TextField("과목", text: draft.title)
                TextField("학기", text: draft.term)
                Stepper("\(draft.wrappedValue.credits.formatted())학점", value: draft.credits, in: 0...30, step: 0.5)
                Picker("분류", selection: Binding(get: { draft.wrappedValue.category ?? "일반" }, set: { draft.wrappedValue.category = $0 })) {
                    ForEach(["일반", "교양", "전공"], id: \.self) { Text($0).tag($0) }
                }
                Toggle("평점에서 제외", isOn: Binding(get: { draft.wrappedValue.excluded == true }, set: { draft.wrappedValue.excluded = $0 }))
                Picker("성적", selection: draft.mark) {
                    Text("미입력").tag("")
                    ForEach(gradeMarks.filter { scale != 4.5 || !$0.hasSuffix("-") || draft.wrappedValue.mark == $0 }, id: \.self) { Text($0).tag($0) }
                }
            } save: { item in
                var item = item
                item.title = item.title.trimmed
                item.term = item.term.trimmed
                if library.update({ $0.grades.replace(item) }) { term = item.term; return true }
                return false
            }
        }
    }
}

private let gradeMarks = ["A+", "A", "A-", "B+", "B", "B-", "C+", "C", "C-", "D+", "D", "D-", "F", "P", "NP"]

private func gradePoints(_ mark: String, scale: Double) -> Double? {
    guard let index = gradeMarks.firstIndex(of: mark), index < 13 else { return nil }
    switch scale {
    case 4.5: return [4.5, 4, 4, 3.5, 3, 3, 2.5, 2, 2, 1.5, 1, 1, 0][index]
    case 4.3: return [4.3, 4, 3.7, 3.3, 3, 2.7, 2.3, 2, 1.7, 1.3, 1, 0.7, 0][index]
    default: return [4, 4, 3.7, 3.3, 3, 2.7, 2.3, 2, 1.7, 1.3, 1, 0.7, 0][index]
    }
}

struct ProtectedView: View {
    let library: CalixLibrary
    let title: String
    @Binding var access: Bool

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "lock")
        } actions: {
            Button("잠금 해제") {
                Task { access = await library.authenticate("\(title)을 열려면 인증하세요.") }
            }.buttonStyle(VesperPrimaryAction())
        }
    }
}

struct EditForm<Value, Fields: View>: View {
    let title: String
    @State private var value: Value
    let valid: (Value) -> Bool
    let fields: (Binding<Value>) -> Fields
    let save: (Value) -> Bool
    @Environment(\.dismiss) private var dismiss

    init(title: String, initial: Value, valid: @escaping (Value) -> Bool,
         @ViewBuilder fields: @escaping (Binding<Value>) -> Fields, save: @escaping (Value) -> Bool) {
        self.title = title
        _value = State(initialValue: initial)
        self.valid = valid
        self.fields = fields
        self.save = save
    }

    var body: some View {
        NavigationStack {
            Form { fields($value) }
                .navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("저장") { if save(value) { dismiss() } }.disabled(!valid(value))
                    }
                }
        }
    }
}

extension Array where Element: Identifiable {
    mutating func replace(_ item: Element) {
        if let index = firstIndex(where: { $0.id == item.id }) { self[index] = item }
        else { append(item) }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
