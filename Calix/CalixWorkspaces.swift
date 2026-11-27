import SwiftUI

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

struct CalixTimetable: View {
    let library: CalixLibrary
    @Environment(\.scenePhase) private var phase
    @State private var term: String?
    @State private var day = Calendar.current.component(.weekday, from: .now)
    @State private var editing: CalixLesson?
    @State private var offDate = Date()
    @State private var showOffDay = false
    @State private var authorized = false
    @State private var showFree = false
    private let days = ["일", "월", "화", "수", "목", "금", "토"]

    init(library: CalixLibrary) {
        self.library = library
        #if DEBUG
        if CalixScreenshot.page == "timetable" { _day = State(initialValue: 2) }
        #endif
    }

    var body: some View {
        let selected = term ?? library.data.preferences.mainTerm
        let terms = Set(library.data.lessons.map(\.term) + [selected, library.data.preferences.mainTerm]).sorted()
        let items = library.data.lessons.filter { $0.term == selected }
        let active = items.filter { $0.weekday == day && !$0.online }.sorted { $0.start < $1.start }
        let online = items.filter(\.online)
        Group {
            if library.data.preferences.lockTimetable && !authorized {
                ProtectedView(library: library, title: "시간표", access: $authorized)
            } else {
                List {
                    Picker("학기", selection: Binding(get: { selected }, set: { term = $0 })) {
                        ForEach(terms, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("요일", selection: $day) {
                        ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { index in Text(days[index - 1]).tag(index) }
                    }.pickerStyle(.segmented)
                    Section("\(days[day - 1])요일") {
                        if active.isEmpty { Text("등록된 수업이 없습니다.").foregroundStyle(.secondary) }
                        ForEach(active) { row($0) }
                    }
                    Section("비대면") {
                        if online.isEmpty { Text("등록된 비대면 수업이 없습니다.").foregroundStyle(.secondary) }
                        ForEach(online) { row($0) }
                    }
                    DisclosureGroup("공강 찾기", isExpanded: $showFree) {
                        let intervals = freeSlots(active)
                        if intervals.isEmpty { Text("30분 이상 비어 있는 시간이 없습니다.") }
                        ForEach(intervals, id: \.self) { Text($0).monospacedDigit() }
                    }
                    Button("휴강일 관리") { showOffDay = true }
                    if selected != library.data.preferences.mainTerm {
                        Button("기본 학기로 설정") { library.update { $0.preferences.mainTerm = selected } }
                    }
                }
                .toolbar {
                    Button { editing = CalixLesson(term: selected, weekday: day) } label: { Label("수업 추가", systemImage: "plus") }
                }
            }
        }
        .navigationTitle("시간표")
        .onChange(of: phase) { _, newPhase in if newPhase == .background { authorized = false; editing = nil; showOffDay = false } }
        .sheet(item: $editing) { lesson in
            EditForm(title: "수업 편집", initial: lesson, valid: { !$0.title.trimmed.isEmpty && !$0.term.trimmed.isEmpty && ($0.online || $0.start < $0.end) }) { item in
                TextField("수업 이름", text: item.title)
                TextField("학기", text: item.term)
                TextField("교수", text: item.lecturer)
                TextField("강의실", text: item.room)
                Toggle("비대면", isOn: item.online)
                if !item.wrappedValue.online {
                    Picker("요일", selection: item.weekday) {
                        ForEach(1...7, id: \.self) { Text("\(days[$0 - 1])요일").tag($0) }
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

    private func row(_ item: CalixLesson) -> some View {
        Button { editing = item } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).foregroundStyle(.primary)
                if !item.online { Text("\(time(item.start))–\(time(item.end))").monospacedDigit() }
                Text([item.room, item.lecturer].filter { !$0.isEmpty }.joined(separator: " · ")).foregroundStyle(.secondary)
            }
        }
        .swipeActions { Button("삭제", role: .destructive) { library.update { $0.lessons.removeAll { $0.id == item.id } } } }
    }

    private func clock(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0, of: .now) ?? .now
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        })
    }

    private func time(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

    private func freeSlots(_ active: [CalixLesson]) -> [String] {
        var cursor = 8 * 60
        let closing = 20 * 60
        var result: [String] = []
        for lesson in active where lesson.end > cursor && lesson.start < closing {
            if lesson.start - cursor >= 30 { result.append("\(time(cursor))–\(time(lesson.start))") }
            cursor = max(cursor, lesson.end)
        }
        if closing - cursor >= 30 { result.append("\(time(cursor))–\(time(closing))") }
        return result
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
            }.buttonStyle(.borderedProminent)
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
