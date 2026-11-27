import CryptoKit
import Foundation

enum AuroraLinkError: Error {
    case code, expired, connection, response, workspace, save
}

struct AuroraPairing {
    let endpoint: URL
    let workspace: String
    let expires: Date
    let key: SymmetricKey

    init(_ value: String, simulatorFixture: Bool = false) throws {
        guard value.utf8.count <= 1024,
              let parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "calix-vesper", parts.host == "pair", parts.path.isEmpty,
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              let items = parts.queryItems,
              items.count == 6, Set(items.map(\.name)).count == 6 else { throw AuroraLinkError.code }
        let fields = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard let host = fields["host"] else { throw AuroraLinkError.code }
        var allowedHost = Self.isPrivate(host)
        #if DEBUG && targetEnvironment(simulator)
        allowedHost = allowedHost || (simulatorFixture && host == "127.0.0.1")
        #endif
        guard fields["v"] == "2", allowedHost,
              let port = fields["port"].flatMap(Int.init), (1024...65535).contains(port),
              let computer = fields["computer"], computer.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil,
              let unix = fields["expires"].flatMap(Double.init), unix.isFinite,
              let encoded = fields["key"], encoded.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
              let secret = Data(base64Encoded: encoded.replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/") + "="), secret.count == 32 else { throw AuroraLinkError.code }
        let expiry = Date(timeIntervalSince1970: unix)
        guard expiry.timeIntervalSinceNow > 0, expiry.timeIntervalSinceNow < 360 else { throw AuroraLinkError.expired }
        var endpoint = URLComponents()
        endpoint.scheme = "http"
        endpoint.host = host
        endpoint.port = port
        guard let url = endpoint.url else { throw AuroraLinkError.code }
        self.endpoint = url
        workspace = computer
        expires = expiry
        key = SymmetricKey(data: secret)
    }

    private static func isPrivate(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        let bytes = parts.compactMap { UInt8($0) }
        guard parts.count == 4, bytes.count == 4, bytes.map(String.init).joined(separator: ".") == value else { return false }
        return bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1])) ||
            (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 169 && bytes[1] == 254)
    }
}

enum AuroraValue: Codable {
    case text(String), integer(Int), decimal(Double), flag(Bool), empty

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .empty }
        else if let string = try? value.decode(String.self) { self = .text(string) }
        else if let bool = try? value.decode(Bool.self) { self = .flag(bool) }
        else if let integer = try? value.decode(Int.self) { self = .integer(integer) }
        else { self = .decimal(try value.decode(Double.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .text(let text): try value.encode(text)
        case .integer(let number): try value.encode(number)
        case .decimal(let number): try value.encode(number)
        case .flag(let flag): try value.encode(flag)
        case .empty: try value.encodeNil()
        }
    }
}

typealias AuroraRecord = [String: AuroraValue]

private extension Dictionary where Key == String, Value == AuroraValue {
    func string(_ key: String, _ fallback: String = "") -> String {
        if case .text(let value)? = self[key] { return value }
        return fallback
    }
    func int(_ key: String, _ fallback: Int = 0) -> Int {
        if case .integer(let value)? = self[key] { return value }
        return fallback
    }
    func double(_ key: String) -> Double {
        if case .decimal(let value)? = self[key] { return value }
        return Double(int(key))
    }
    func bool(_ key: String) -> Bool {
        if case .flag(let value)? = self[key] { return value }
        return false
    }
}

struct AuroraLinkState: Codable {
    struct Anchor: Codable {
        let revision: String
        let local: String
    }
    var workspace: String
    var anchors: [String: [String: Anchor]] = [:]
    var native: [String: [String: String]] = [:]
    var lastSync: Date?
    var conflicts = 0
}

struct AuroraSnapshot: Decodable {
    struct Row: Decodable {
        let revision: String
        let value: AuroraRecord
        let courseID: Int?
    }
    struct School: Decodable {
        let id, title, course, kind, note: String
        let due, url, status, feedback: String?
        let done: Bool
    }
    struct Attendance: Decodable {
        let id, course, title, status: String
        let date: String?
    }
    let records: [String: [String: Row]]
    let conflicts: [String]
    let school: [School]
    let attendance: [Attendance]
    let owner, mainTerm: String
    let timetableColors: AuroraTimetableColors?
}

struct AuroraOffer: Encodable {
    struct Change: Encodable {
        let base: String?
        let value: AuroraRecord?
    }
    let receipt, name: String
    let changes: [String: [String: Change]]
    var schoolOwner: String? = nil
}

enum AuroraCodec {
    static let maximumBytes = 8 * 1024 * 1024

    static func fingerprint(_ record: AuroraRecord) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let bytes = try? encoder.encode(record) else { return "" }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func timestamp(_ value: Date?) -> AuroraValue {
        guard let value else { return .empty }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return .text(formatter.string(from: value))
    }

    static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value) ?? dayFormatter.date(from: value)
    }

    private static var dayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    static func day(_ value: Date) -> String { dayFormatter.string(from: value) }
}

@MainActor
enum AuroraWorkspace {
    typealias Entries = [String: [String: AuroraRecord]]
    static let kinds = ["event", "canvasEdit", "task", "lesson", "grade", "journal", "focus", "holiday"]

    static func uuid(_ identifier: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(identifier.utf8)))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func mobile(_ id: UUID) -> String {
        "m:" + id.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }

    static func collect(_ data: CalixData, _ link: AuroraLinkState) -> Entries {
        var rows: Entries = [:]
        func put(_ kind: String, _ native: String, _ fallback: String, _ row: AuroraRecord) {
            rows[kind, default: [:]][link.native[kind]?[native] ?? fallback] = row
        }
        for item in data.events where !item.remote {
            let fallback = item.id.hasPrefix("desktop:manual:") ? String(item.id.dropFirst(8)) :
                mobile(UUID(uuidString: item.id) ?? uuid(item.id))
            put("event", item.id, fallback, [
                "title": .text(item.title), "course": .text(item.course), "start": AuroraCodec.timestamp(item.starts),
                "due": AuroraCodec.timestamp(item.due), "note": .text(item.note), "done": .flag(item.done),
                "starred": .flag(item.starred), "category": .text(item.auroraCategory ?? ""),
                "color": .text(item.auroraColor ?? ""), "series": item.seriesID.map(AuroraValue.text) ?? .empty,
            ])
        }
        for item in data.events where item.remote && item.id.hasPrefix("canvas:") &&
            (item.customTitle != nil || !item.note.isEmpty) {
            put("canvasEdit", item.id, item.id, [
                "title": item.customTitle.map(AuroraValue.text) ?? .empty,
                "note": .text(item.note),
            ])
        }
        for item in data.tasks where item.sourceID == nil {
            let choice = data.taskStatuses?.first { $0.name == item.status }
            put("task", item.id.uuidString, mobile(item.id), [
                "title": .text(item.title), "section": .text(item.section), "status": .text(item.status ?? (item.done ? "완료" : "계획")),
                "statusColor": .text(item.auroraStatusColor ?? choice?.tint ?? ""), "done": .flag(item.done),
                "due": AuroraCodec.timestamp(item.due), "note": .text(item.note ?? ""), "role": .text(item.role ?? ""),
                "instructor": .text(item.instructor ?? ""), "category": .text(item.auroraCategory ?? ""),
            ])
        }
        for item in data.lessons {
            put("lesson", item.id.uuidString, mobile(item.id), [
                "title": .text(item.title), "term": .text(item.term), "weekday": .integer(item.weekday),
                "start": .integer(item.start), "end": .integer(item.end), "room": .text(item.room),
                "lecturer": .text(item.lecturer), "online": .flag(item.online), "color": .text(item.auroraColor ?? ""),
            ])
        }
        for item in data.grades where item.canvasCourseID == nil {
            put("grade", item.id.uuidString, mobile(item.id), [
                "title": .text(item.title), "term": .text(item.term), "credits": .decimal(item.credits),
                "mark": .text(item.mark), "category": .text(item.category ?? "일반"), "excluded": .flag(item.excluded ?? false),
            ])
        }
        for item in data.journals where !item.secret {
            put("journal", item.id.uuidString, mobile(item.id), [
                "date": .text(AuroraCodec.day(item.date)), "title": .text(item.title), "body": .text(item.body),
            ])
        }
        for item in data.focusHistory {
            put("focus", item.id.uuidString, mobile(item.id), [
                "day": .text(AuroraCodec.day(item.started)), "seconds": .integer(item.seconds),
            ])
        }
        for (key, title) in data.holidays {
            put("holiday", key, "holiday:" + key, ["day": .text(key), "title": .text(title), "enabled": .flag(true)])
        }
        return rows
    }

    static func offer(_ data: CalixData, _ link: AuroraLinkState, receipt: String, name: String) -> AuroraOffer {
        let local = collect(data, link)
        var changes: [String: [String: AuroraOffer.Change]] = [:]
        for kind in kinds {
            let rows = local[kind] ?? [:]
            let anchors = link.anchors[kind] ?? [:]
            for (id, row) in rows where anchors[id]?.local != AuroraCodec.fingerprint(row) {
                changes[kind, default: [:]][id] = .init(base: anchors[id]?.revision, value: row)
            }
            for (id, original) in anchors where rows[id] == nil {
                changes[kind, default: [:]][id] = .init(base: original.revision, value: nil)
            }
        }
        return AuroraOffer(receipt: receipt, name: name, changes: changes,
                           schoolOwner: data.canvasID ?? data.auroraSchoolOwner)
    }

    static func apply(_ snapshot: AuroraSnapshot, baseline: Entries, data: inout CalixData, link: inout AuroraLinkState) {
        let before = collect(data, link)
        mergeSchool(snapshot, data: &data)
        if let colors = snapshot.timetableColors { data.auroraTimetableColors = colors }
        let matchingSchool = !snapshot.owner.isEmpty && (data.canvasID ?? data.auroraSchoolOwner) == snapshot.owner
        var conflicts = Set(snapshot.conflicts)
        for kind in kinds {
            if kind == "canvasEdit" && !matchingSchool { continue }
            guard let rows = snapshot.records[kind] else { continue }
            let anchors = link.anchors[kind] ?? [:]
            let known = Set(rows.keys).union(anchors.keys)
            for id in known {
                let key = kind + "/" + id
                guard !conflicts.contains(key) else { continue }
                let original = baseline[kind]?[id].map(AuroraCodec.fingerprint)
                let actual = before[kind]?[id].map(AuroraCodec.fingerprint)
                guard original == actual else { conflicts.insert(key); continue }
                let native = localID(kind, id, link)
                if let row = rows[id] {
                    write(kind, native, row.value, courseID: row.courseID, data: &data)
                    link.native[kind, default: [:]][native] = id
                } else {
                    remove(kind, native, data: &data)
                    link.native[kind]?[native] = nil
                    link.anchors[kind]?[id] = nil
                }
            }
        }
        let merged = collect(data, link)
        for (kind, rows) in snapshot.records where kinds.contains(kind) {
            if kind == "canvasEdit" && !matchingSchool { continue }
            for (id, row) in rows where !conflicts.contains(kind + "/" + id) {
                if let value = merged[kind]?[id] {
                    link.anchors[kind, default: [:]][id] = .init(revision: row.revision, local: AuroraCodec.fingerprint(value))
                }
            }
        }
        if data.lessons.contains(where: { $0.term == snapshot.mainTerm }) && data.preferences.mainTerm == "기본 학기" {
            data.preferences.mainTerm = snapshot.mainTerm
        }
        mergeSchool(snapshot, data: &data)
        link.lastSync = .now
        link.conflicts = conflicts.count
    }

    private static func localID(_ kind: String, _ wire: String, _ link: AuroraLinkState) -> String {
        if let native = link.native[kind]?.first(where: { $0.value == wire })?.key { return native }
        if kind == "holiday" { return String(wire.dropFirst("holiday:".count)) }
        if kind == "canvasEdit" { return wire }
        if kind == "event" && wire.hasPrefix("manual:") { return "desktop:" + wire }
        if wire.hasPrefix("m:"), wire.count == 34 {
            let parts = Array(wire.dropFirst(2))
            let ranges = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32]
            if let value = UUID(uuidString: ranges.map { String(parts[$0]) }.joined(separator: "-")) { return value.uuidString }
        }
        return uuid(wire).uuidString
    }

    private static func write(_ kind: String, _ native: String, _ row: AuroraRecord, courseID: Int?, data: inout CalixData) {
        let title = row.string("title")
        let id = UUID(uuidString: native)
        switch kind {
        case "event":
            let previous = data.events.first { $0.id == native }
            let series = row.string("series")
            let course = row.string("course")
            put(&data.events, CalixEvent(id: native, title: title, course: course.isEmpty ? (previous?.course ?? "") : course,
                kind: previous?.kind ?? .personal,
                due: AuroraCodec.date(row.string("due")), note: row.string("note"), done: row.bool("done"),
                starred: row.bool("starred"), seriesID: previous?.seriesID ?? (series.isEmpty ? nil : series),
                starts: AuroraCodec.date(row.string("start")), auroraCategory: row.string("category"), auroraColor: row.string("color")))
        case "canvasEdit":
            if let index = data.events.firstIndex(where: { $0.id == native && $0.remote }) {
                data.events[index].customTitle = title.isEmpty ? nil : title
                data.events[index].note = row.string("note")
            }
        case "task":
            guard let id else { return }
            put(&data.tasks, CalixTask(id: id, title: title, section: row.string("section"), done: row.bool("done"),
                status: row.string("status"), due: AuroraCodec.date(row.string("due")), note: row.string("note"),
                role: row.string("role"), instructor: row.string("instructor"), auroraCategory: row.string("category"),
                auroraStatusColor: row.string("statusColor")))
        case "lesson":
            guard let id else { return }
            let previous = data.lessons.first { $0.id == id }
            put(&data.lessons, CalixLesson(id: id, title: title, term: row.string("term"), weekday: row.int("weekday", 2),
                start: row.int("start", 540), end: row.int("end", 600), room: row.string("room"),
                lecturer: row.string("lecturer"), online: row.bool("online"), auroraColor: row.string("color"),
                auroraCourseID: courseID ?? previous?.auroraCourseID))
        case "grade":
            guard let id else { return }
            put(&data.grades, CalixGrade(id: id, title: title, term: row.string("term"), credits: row.double("credits"),
                mark: row.string("mark"), category: row.string("category"), excluded: row.bool("excluded")))
        case "journal":
            guard let id, let date = AuroraCodec.date(row.string("date")) else { return }
            let previous = data.journals.first { $0.id == id }
            guard previous?.secret != true else { return }
            let body = row.string("body")
            put(&data.journals, CalixJournal(id: id, date: date, title: title, body: body,
                formatting: previous?.body == body ? previous?.formatting : nil))
        case "focus":
            guard let id, let date = AuroraCodec.date(row.string("day")) else { return }
            let previous = data.focusHistory.first { $0.id == id }
            put(&data.focusHistory, CalixFocusRecord(id: id, started: previous?.started ?? date, seconds: row.int("seconds")))
        case "holiday":
            data.holidays[native] = row.bool("enabled") ? title : nil
        default: break
        }
    }

    private static func put<T: Identifiable>(_ rows: inout [T], _ item: T) {
        if let index = rows.firstIndex(where: { $0.id == item.id }) { rows[index] = item }
        else { rows.append(item) }
    }

    private static func remove(_ kind: String, _ native: String, data: inout CalixData) {
        let id = UUID(uuidString: native)
        switch kind {
        case "event": data.events.removeAll { $0.id == native && !$0.remote }
        case "canvasEdit":
            if let index = data.events.firstIndex(where: { $0.id == native && $0.remote }) {
                data.events[index].customTitle = nil
                data.events[index].note = ""
            }
        case "task": data.tasks.removeAll { $0.id == id && $0.sourceID == nil }
        case "lesson": data.lessons.removeAll { $0.id == id }
        case "grade": data.grades.removeAll { $0.id == id && $0.canvasCourseID == nil }
        case "journal": data.journals.removeAll { $0.id == id && !$0.secret }
        case "focus": data.focusHistory.removeAll { $0.id == id }
        case "holiday": data.holidays[native] = nil
        default: break
        }
    }

    private static func mergeSchool(_ snapshot: AuroraSnapshot, data: inout CalixData) {
        guard !snapshot.owner.isEmpty, data.canvasID == nil || data.canvasID == snapshot.owner,
              data.auroraSchoolOwner == nil || data.auroraSchoolOwner == snapshot.owner else { return }
        data.auroraSchoolOwner = snapshot.owner
        var imported = Set(data.auroraSchoolEvents ?? [])
        for row in snapshot.school {
            let previous = data.events.first { $0.id == row.id }
            if previous == nil { imported.insert(row.id) }
            let url = row.url.flatMap(URL.init(string:)).flatMap { CanvasBrowser.isCampus($0) ? $0 : nil }
            put(&data.events, CalixEvent(id: row.id, title: previous?.customTitle ?? row.title,
                course: row.course, kind: row.kind == "movie" ? .video : .assignment,
                due: AuroraCodec.date(row.due ?? "") ?? previous?.due, note: previous?.note ?? row.note,
                done: previous?.manualCompletion ?? row.done, starred: previous?.starred ?? false,
                remote: true, manualCompletion: previous?.manualCompletion, url: url, feedback: row.feedback ?? previous?.feedback,
                customTitle: previous?.customTitle, syncStatus: row.status))
        }
        data.auroraSchoolEvents = imported.sorted()
        for row in snapshot.attendance {
            if !row.id.isEmpty {
                put(&data.attendance, CalixAttendance(id: row.id, course: row.course, title: row.title,
                    status: row.status, date: AuroraCodec.date(row.date ?? "")))
            }
        }
    }
}

private final class AuroraNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum AuroraConnection {
    private struct Reply: Decodable {
        let receipt: String
        let phase: String
        let snapshot: AuroraSnapshot?
    }

    static func sync(_ code: AuroraPairing, offer: AuroraOffer) async throws -> AuroraSnapshot {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        let session = URLSession(configuration: configuration, delegate: AuroraNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let first = try await exchange("offer", offer, code, session)
        guard first.receipt == offer.receipt else { throw AuroraLinkError.response }
        while code.expires > .now {
            try Task.checkCancellation()
            let reply = try await exchange("result", ["receipt": offer.receipt], code, session)
            guard reply.receipt == offer.receipt else { throw AuroraLinkError.response }
            if let snapshot = reply.snapshot, reply.phase == "complete" { return snapshot }
            guard reply.phase == "approval" else { throw AuroraLinkError.response }
            try await Task.sleep(for: .seconds(1.25))
        }
        throw AuroraLinkError.expired
    }

    private static func exchange<Request: Encodable>(_ route: String, _ message: Request, _ code: AuroraPairing,
                                                       _ session: URLSession) async throws -> Reply {
        let payload = try JSONEncoder().encode(message)
        guard payload.count <= AuroraCodec.maximumBytes,
              let sealed = try AES.GCM.seal(payload, using: code.key,
                  authenticating: Data("calix-vesper-v2:\(route)".utf8)).combined else { throw AuroraLinkError.response }
        var request = URLRequest(url: code.endpoint.appendingPathComponent(route))
        request.httpMethod = "POST"
        request.httpBody = sealed
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw AuroraLinkError.connection }
        if http.statusCode == 410 { throw AuroraLinkError.expired }
        let limit = AuroraCodec.maximumBytes + 28
        guard http.statusCode == 200, response.expectedContentLength <= Int64(limit) else { throw AuroraLinkError.response }
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
        for try await byte in stream {
            guard data.count < limit else { throw AuroraLinkError.response }
            data.append(byte)
        }
        let body = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: code.key,
                                    authenticating: Data("calix-vesper-v2:reply".utf8))
        return try JSONDecoder().decode(Reply.self, from: body)
    }
}
