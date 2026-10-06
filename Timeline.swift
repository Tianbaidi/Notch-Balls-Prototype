import AppKit
import SwiftUI
import EventKit

enum TimelineDesign {
    static let width: CGFloat = 520
    static let rowHeight: CGFloat = 60
    static let headerHeight: CGFloat = 36
    static let sweepDuration = 0.92
    static let flowColors: [Color] = [
        Color(red: 0.29, green: 0.62, blue: 1.00),
        Color(red: 0.25, green: 0.78, blue: 0.99),
        Color(red: 0.23, green: 0.87, blue: 0.77),
        Color(red: 0.38, green: 0.73, blue: 1.00),
        Color(red: 0.66, green: 0.55, blue: 0.98)
    ]
    static let palette: [Color] = [
        Color(red: 0.39, green: 0.68, blue: 0.86), // 雾蓝
        Color(red: 0.28, green: 0.76, blue: 0.66), // 青绿
        Color(red: 0.57, green: 0.54, blue: 0.89), // 蓝紫
        Color(red: 0.96, green: 0.65, blue: 0.39), // 暖橙
        Color(red: 0.91, green: 0.48, blue: 0.61)  // 玫瑰
    ]
}

/// Shared timing keeps shell geometry, fills and event arrivals in the same sequence.
enum TimelineMotion {
    static let retireDuration = 0.12
    static func smooth(_ value: Double) -> Double {
        let t = min(1, max(0, value)); return t * t * (3 - 2 * t)
    }
    static func rebound(_ value: Double) -> CGFloat {
        let t = min(1, max(0, value)) - 1
        return CGFloat(1 + 1.65 * t * t * t + 0.65 * t * t)
    }
    static func fillPhase(_ phase: Double) -> Double { min(1, max(0, phase / 0.82)) }
    static func eventPhase(start: Double, progress: Double, phase: Double) -> Double {
        let arrival = start <= progress && progress > 0 ? 0.82 * start / progress
            : 0.82 + 0.03 * max(0, start - progress) / max(0.001, 1 - progress)
        return smooth((phase - arrival) / 0.14)
    }
    static func ambientStrength(elapsed: Double, hovered: Bool, passive: Bool) -> Double {
        if hovered { return 0.65 }
        let idle = passive ? 0.06 : 0.14
        return idle + (0.65 - idle) * (1 - smooth((elapsed - 1.1) / 1.5))
    }
}

enum TimelineScale: Int, CaseIterable, Identifiable {
    case day, month, year
    var id: Int { rawValue }
    var title: String { ["日", "月", "年"][rawValue] }
    var component: Calendar.Component { [.day, .month, .year][rawValue] }

    func interval(at date: Date, calendar: Calendar) -> DateInterval {
        calendar.dateInterval(of: component, for: date)!
    }

    func ticks(in interval: DateInterval, calendar: Calendar) -> [(Date, String)] {
        switch self {
        case .day:
            var result: [(Date, String)] = []
            var date = interval.start
            while date < interval.end {
                let hour = calendar.component(.hour, from: date)
                result.append((date, hour.isMultiple(of: 6) ? String(format: "%02d", hour) : ""))
                guard let next = calendar.date(byAdding: .hour, value: 1, to: date), next > date else { break }
                date = next
            }
            return result
        case .month:
            var result: [(Date, String)] = []
            var date = interval.start
            while date < interval.end {
                let number = calendar.component(.day, from: date)
                result.append((date, number == 1 || number.isMultiple(of: 5) ? "\(number)" : ""))
                guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
                date = next
            }
            return result
        case .year:
            return (0..<12).compactMap { offset in
                guard let date = calendar.date(byAdding: .month, value: offset, to: interval.start), date < interval.end else { return nil }
                return (date, "\(offset + 1)月")
            }
        }
    }
}

struct TimelineEvent: Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let calendarID: String
    let calendarTitle: String
    let externalID: String?
    let url: URL?
    var isMultiDay: Bool {
        Calendar.current.startOfDay(for: start) != Calendar.current.startOfDay(for: end.addingTimeInterval(-0.001))
    }
}

private struct TimelineSlice: Identifiable {
    let date: Date
    let scale: TimelineScale
    var id: String { "\(scale.rawValue)-\(date.timeIntervalSince1970)" }
}

protocol TimelineCalendarSource: AnyObject {
    func requestFullAccessToEvents(completion: @escaping @Sendable (Bool, (any Error)?) -> Void)
    func reset()
    func calendars(for entityType: EKEntityType) -> [EKCalendar]
    func predicateForEvents(withStart startDate: Date, end endDate: Date, calendars: [EKCalendar]?) -> NSPredicate
    func events(matching predicate: NSPredicate) -> [EKEvent]
}

extension EKEventStore: TimelineCalendarSource {}

final class TimelineStore: ObservableObject {
    @Published private(set) var level = 1
    @Published private(set) var renderedLevel = 1
    @Published private(set) var retiringFrom: Int?
    @Published private(set) var closing = false
    var interactionChanged: ((Bool) -> Void)?
    private var interactingTracks = Set<TimelineScale>()
    private var transitionWork: DispatchWorkItem?
    @Published private(set) var now = Date()
    @Published private(set) var events: [TimelineEvent] = []
    @Published private(set) var calendars: [EKCalendar] = []
    @Published private(set) var calendarEnabled = false
    @Published private(set) var calendarReady = false
    @Published private(set) var calendarMessage = "打开时间轴后请求日历权限"
    @Published private(set) var visible = false
    var expansionChanged: ((Int) -> Void)?

    private var store: any TimelineCalendarSource
    private let makeCalendarSource: () -> any TimelineCalendarSource
    private let calendarAuthorization: () -> EKAuthorizationStatus
    private var calendarRetry: DispatchWorkItem?
    @Published private(set) var calendarRequestPending = false
    private let defaults: UserDefaults
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    @Published private(set) var selectedCalendarIDs: Set<String>?
    private var paletteMap: [String: Int]
    private var lastBoundaryKey = ""

    init(defaults: UserDefaults = .standard, startTimer: Bool = true,
         calendarAuthorization: @escaping () -> EKAuthorizationStatus = { EKEventStore.authorizationStatus(for: .event) },
         makeCalendarSource: @escaping () -> any TimelineCalendarSource = { EKEventStore() }) {
        self.defaults = defaults
        self.calendarAuthorization = calendarAuthorization
        self.makeCalendarSource = makeCalendarSource
        self.store = makeCalendarSource()
        paletteMap = defaults.dictionary(forKey: "notch.timeline.colors.v1") as? [String: Int] ?? [:]
        calendarEnabled = defaults.bool(forKey: "notch.timeline.calendarEnabled.v1")
        selectedCalendarIDs = defaults.stringArray(forKey: "notch.timeline.selectedCalendars.v1").map(Set.init)
        if startTimer {
            let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshTime() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            let center = NotificationCenter.default
            for name in [Notification.Name("NSSystemTimeZoneDidChangeNotification"), .EKEventStoreChanged] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.refreshTime(forceEvents: true) }
                })
            }
            for name in [NSWorkspace.didWakeNotification, NSWorkspace.didActivateApplicationNotification] {
                workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name,
                    object: nil, queue: .main) { [weak self] _ in
                        Task { @MainActor in self?.refreshTime(forceEvents: name == NSWorkspace.didWakeNotification) }
                    })
            }
            if calendarEnabled { refreshCalendars() }
        }
    }

    deinit {
        timer?.invalidate()
        calendarRetry?.cancel()
        transitionWork?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    func setLevel(_ value: Int) {
        let next = min(3, max(1, value))
        guard next != level || closing else { return }
        transitionWork?.cancel()
        closing = false
        level = next
        if next < renderedLevel && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            retiringFrom = next
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.level == next, !self.closing else { return }
                self.renderedLevel = next
                self.retiringFrom = nil
                self.expansionChanged?(next)
            }
            transitionWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + TimelineMotion.retireDuration, execute: work)
        } else {
            retiringFrom = nil
            renderedLevel = next
            expansionChanged?(next)
        }
        if defaults.bool(forKey: "notch.timeline.rememberLevel.v1") {
            defaults.set(next, forKey: "notch.timeline.level.v1")
        }
    }

    func open(pinned: Bool) {
        transitionWork?.cancel()
        closing = false
        retiringFrom = nil
        visible = true
        let next = pinned ? max(1, defaults.integer(forKey: "notch.timeline.level.v1")) : 1
        setLevel(next)
        renderedLevel = level
        now = Date()
        enableCalendar()
    }

    func hide() {
        transitionWork?.cancel()
        visible = false
        closing = false
        retiringFrom = nil
        renderedLevel = level
        if !interactingTracks.isEmpty { interactingTracks.removeAll(); interactionChanged?(false) }
    }

    func setPresentationVisible(_ value: Bool) {
        guard value != visible else { return }
        visible = value
    }

    func close(_ completion: @escaping () -> Void) {
        transitionWork?.cancel()
        closing = true
        retiringFrom = 0
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { completion(); return }
        let work = DispatchWorkItem { [weak self] in
            guard self?.closing == true else { return }
            completion()
        }
        transitionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + TimelineMotion.retireDuration, execute: work)
    }

    func setInteracting(_ scale: TimelineScale, _ active: Bool) {
        let wasActive = !interactingTracks.isEmpty
        if active { interactingTracks.insert(scale) } else { interactingTracks.remove(scale) }
        if wasActive != !interactingTracks.isEmpty { interactionChanged?(!interactingTracks.isEmpty) }
    }

    func rememberLevel(_ remember: Bool) {
        defaults.set(remember, forKey: "notch.timeline.rememberLevel.v1")
        if remember { defaults.set(level, forKey: "notch.timeline.level.v1") }
    }

    func refreshTime(forceEvents: Bool = false) {
        now = Date()
        let calendar = Calendar.current
        let key = "\(calendar.startOfDay(for: now).timeIntervalSince1970)-\(TimeZone.current.identifier)"
        if forceEvents || key != lastBoundaryKey ||
           (calendarEnabled && (calendarAuthorization() == .fullAccess) != calendarReady) {
            lastBoundaryKey = key
            if calendarEnabled { refreshCalendars() }
        }
    }

    func enableCalendar() {
        calendarEnabled = true
        persistCalendarEnabled()
        guard !calendarRequestPending else { return }
        switch calendarAuthorization() {
        case .fullAccess: refreshCalendars()
        case .notDetermined, .writeOnly:
            calendarRequestPending = true
            calendarMessage = "正在请求日历权限…"
            store.requestFullAccessToEvents { [weak self] granted, error in
                Task { @MainActor in
                    guard let self else { return }
                    self.calendarRequestPending = false
                    guard self.calendarEnabled else { return }
                    if granted {
                        self.calendarMessage = "正在读取日历…"
                        self.reloadCalendars()
                    } else {
                        self.calendarReady = false
                        self.calendars = []
                        self.events = []
                        self.calendarMessage = error?.localizedDescription ?? "请在系统设置中允许访问日历"
                    }
                }
            }
        default:
            calendarReady = false
            calendars = []
            events = []
            calendarMessage = "请在系统设置中允许访问日历"
        }
    }

    func disableCalendar() {
        calendarRetry?.cancel()
        calendarEnabled = false
        calendarReady = false
        calendars = []
        events = []
        calendarMessage = "打开时间轴后请求日历权限"
        persistCalendarEnabled()
    }

    private func persistCalendarEnabled() {
        defaults.set(calendarEnabled, forKey: "notch.timeline.calendarEnabled.v1")
    }

    func isSelected(_ calendar: EKCalendar) -> Bool {
        selectedCalendarIDs?.contains(calendar.calendarIdentifier) ?? true
    }

    func setSelected(_ calendar: EKCalendar, _ selected: Bool) {
        var ids = selectedCalendarIDs ?? Set(calendars.map(\.calendarIdentifier))
        if selected { ids.insert(calendar.calendarIdentifier) } else { ids.remove(calendar.calendarIdentifier) }
        selectedCalendarIDs = ids
        defaults.set(Array(ids).sorted(), forKey: "notch.timeline.selectedCalendars.v1")
        refreshEvents()
    }

    private func reloadCalendars() {
        guard calendarEnabled else { return }
        calendarRetry?.cancel()
        // A new EventKit session must not retain a pre-authorization empty cache.
        calendarReady = false
        refreshCalendars()
        scheduleCalendarRetry(attempt: 0)
    }

    private func scheduleCalendarRetry(attempt: Int) {
        calendarRetry?.cancel()
        let delays = [0.4, 1.2, 2.5]
        guard calendarEnabled, attempt < delays.count else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.calendarEnabled else { return }
            self.refreshCalendars()
            if !self.calendarReady || self.calendars.isEmpty {
                self.scheduleCalendarRetry(attempt: attempt + 1)
            }
        }
        calendarRetry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delays[attempt], execute: work)
    }

    private func refreshCalendars() {
        guard calendarEnabled else { return }
        guard calendarAuthorization() == .fullAccess else {
            calendarReady = false
            calendars = []
            events = []
            calendarMessage = "请在系统设置中允许访问日历"
            return
        }
        if !calendarReady {
            store = makeCalendarSource()
            store.reset()
            scheduleCalendarRetry(attempt: 0)
        }
        calendarReady = true
        calendars = store.calendars(for: .event).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        refreshEvents()
    }

    private func refreshEvents() {
        guard calendarEnabled, calendarAuthorization() == .fullAccess else { return }
        let calendar = Calendar.current
        let span = TimelineScale.year.interval(at: now, calendar: calendar)
        let selected = calendars.filter(isSelected)
        guard !selected.isEmpty else {
            events = []
            calendarMessage = calendars.isEmpty ? "暂无可用日历" : "没有选中的日历"
            return
        }
        let predicate = store.predicateForEvents(withStart: span.start, end: span.end, calendars: selected)
        events = store.events(matching: predicate).map { event in
            TimelineEvent(id: event.eventIdentifier ?? UUID().uuidString,
                          title: event.title ?? "未命名事件", start: event.startDate, end: event.endDate,
                          isAllDay: event.isAllDay, calendarID: event.calendar.calendarIdentifier,
                          calendarTitle: event.calendar.title,
                          externalID: event.calendarItemExternalIdentifier, url: event.url)
        }
        calendarMessage = events.isEmpty ? "所选日历暂无事件" : ""
    }

    func color(for event: TimelineEvent) -> Color {
        let key = event.calendarID
        if let index = paletteMap[key] { return TimelineDesign.palette[index % TimelineDesign.palette.count] }
        let used = Set(paletteMap.values)
        let index = (0..<TimelineDesign.palette.count).first { !used.contains($0) } ?? paletteMap.count % TimelineDesign.palette.count
        paletteMap[key] = index
        defaults.set(paletteMap, forKey: "notch.timeline.colors.v1")
        return TimelineDesign.palette[index]
    }

    func setColor(_ index: Int, for calendar: EKCalendar) {
        paletteMap[calendar.calendarIdentifier] = index
        defaults.set(paletteMap, forKey: "notch.timeline.colors.v1")
        objectWillChange.send()
    }

    func visibleEvents(for scale: TimelineScale) -> [TimelineEvent] {
        let span = scale.interval(at: now, calendar: .current)
        return events.filter { event in
            event.start < span.end && event.end > span.start &&
            (scale != .year || event.isMultiDay || defaults.stringArray(forKey: "notch.timeline.important.v1")?.contains(event.id) == true)
        }.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }

    func isImportant(_ event: TimelineEvent) -> Bool {
        defaults.stringArray(forKey: "notch.timeline.important.v1")?.contains(event.id) == true
    }

    func setImportant(_ event: TimelineEvent, _ important: Bool) {
        var ids = Set(defaults.stringArray(forKey: "notch.timeline.important.v1") ?? [])
        if important { ids.insert(event.id) } else { ids.remove(event.id) }
        defaults.set(Array(ids).sorted(), forKey: "notch.timeline.important.v1")
        objectWillChange.send()
    }

    func openInCalendar(_ event: TimelineEvent) {
        let app = URL(fileURLWithPath: "/System/Applications/Calendar.app")
        guard let uid = event.externalID, !uid.isEmpty else { NSWorkspace.shared.open(app); return }
        func literal(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let script = """
        tell application "Calendar"
            activate
            set chosenCalendar to first calendar whose calendarIdentifier is \(literal(event.calendarID))
            set chosenEvent to first event of chosenCalendar whose uid is \(literal(uid))
            show chosenEvent
        end tell
        """
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            guard let appleScript = NSAppleScript(source: script) else {
                DispatchQueue.main.async { NSWorkspace.shared.open(app) }
                return
            }
            _ = appleScript.executeAndReturnError(&error)
            if error != nil { DispatchQueue.main.async { NSWorkspace.shared.open(app) } }
        }
    }

    func loadPreview(_ samples: [TimelineEvent]) {
        events = samples
        calendarEnabled = true
        calendarReady = true
        calendarMessage = ""
    }
}

struct TimelineCapsule: View {
    @ObservedObject var store: TimelineStore
    @ObservedObject var interaction: CapsuleInteraction
    let onClose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { store.setLevel(store.level + 1) } label: {
                    HStack(spacing: 5) {
                        CapsuleGlyph(moduleID: "timeline", size: 22)
                        Text("时间轴").font(.system(size: 11, weight: .semibold))
                        if store.level < 3 { Image(systemName: "chevron.down").font(.system(size: 9)) }
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).help(store.level < 3 ? "增加下一条轨道" : "已显示全部轨道")
                if !store.calendarReady {
                    Text(store.calendarRequestPending ? "正在授权…" : "未授权日历")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                        .help(store.calendarMessage)
                } else {
                    Menu {
                        ForEach(store.calendars, id: \.calendarIdentifier) { calendar in
                            Button { store.setSelected(calendar, !store.isSelected(calendar)) } label: {
                                Text("\(store.isSelected(calendar) ? "✓ " : "")\(calendar.title)")
                            }
                            Menu("\(calendar.title)颜色") {
                                ForEach(0..<TimelineDesign.palette.count, id: \.self) { index in
                                    Button(["雾蓝", "青绿", "蓝紫", "暖橙", "玫瑰"][index]) { store.setColor(index, for: calendar) }
                                }
                            }
                        }
                        Divider()
                        if !store.calendarMessage.isEmpty { Text(store.calendarMessage) }
                    } label: { Image(systemName: "calendar").frame(width: 22, height: 24) }
                    .menuStyle(.borderlessButton).fixedSize().help("选择日历与颜色")
                }
                control("chevron.up", "收回一条轨道") { store.setLevel(store.level - 1) }
                    .disabled(store.level == 1)
                control(interaction.isPinned("timeline") ? "pin.fill" : "pin", "固定当前层级") {
                    let pinned = !interaction.isPinned("timeline")
                    interaction.setPinned("timeline", pinned)
                    store.rememberLevel(pinned)
                }
                control("xmark", "关闭时间轴") { store.close(onClose) }
            }.frame(height: TimelineDesign.headerHeight)
                .opacity(store.closing ? 0 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: TimelineMotion.retireDuration), value: store.closing)
            ForEach(TimelineScale.allCases.prefix(store.renderedLevel)) { scale in
                TimelineTrack(scale: scale, store: store, animated: !reduceMotion,
                              passive: interaction.isPinned("timeline"))
                    .frame(height: TimelineDesign.rowHeight)
                    .opacity(store.retiringFrom.map { scale.rawValue >= $0 } == true ? 0 : 1)
                    .animation(reduceMotion ? nil : .easeOut(duration: TimelineMotion.retireDuration), value: store.retiringFrom)
            }
        }
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func control(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).frame(width: 24, height: 25) }
            .buttonStyle(CapsuleButtonStyle(subtle: true)).help(label).accessibilityLabel(label)
    }
}

/// A quiet, continuously moving color field. The filled length stays tied to real time;
/// only its surface and soft highlight move after the entrance particles settle.
private struct TimelineFlowField: View {
    let scale: TimelineScale
    let fillWidth: CGFloat
    let time: TimeInterval
    let strength: Double

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let end = min(size.width, max(0, fillWidth))
            guard end > 0 else { return }
            let bar = CGRect(x: 0, y: 16, width: end, height: 27)
            var fill = context
            fill.clip(to: Path(roundedRect: bar, cornerRadius: 7))
            let drift = strength > 0 ? time * 0.30 + Double(scale.rawValue) * 1.3 : 0
            let spectrum = Gradient(stops: [
                .init(color: TimelineDesign.flowColors[0], location: 0),
                .init(color: TimelineDesign.flowColors[1], location: 0.28 + 0.09 * strength * sin(drift)),
                .init(color: TimelineDesign.flowColors[2], location: 0.57 + 0.12 * strength * sin(drift + 1.1)),
                .init(color: TimelineDesign.flowColors[3], location: 0.79 + 0.08 * strength * sin(drift + 2.2)),
                .init(color: TimelineDesign.flowColors[4], location: 1)
            ])
            let colorOffset = CGFloat(0.09 * strength * sin(drift)) * size.width
            let shade = GraphicsContext.Shading.linearGradient(
                spectrum, startPoint: CGPoint(x: colorOffset, y: 0),
                endPoint: CGPoint(x: size.width + colorOffset, y: 0))
            fill.fill(Path(bar), with: .linearGradient(
                Gradient(colors: TimelineDesign.flowColors.map { $0.opacity(0.32) }),
                startPoint: .zero, endPoint: CGPoint(x: size.width, y: 40)))
            // Smooth, translucent layers replace the stepped pixel columns.
            for layer in 0..<2 {
                var wave = Path()
                wave.move(to: CGPoint(x: 0, y: 43))
                var x: CGFloat = 0
                while x <= end + 3 {
                    let waveY = 20 + Double(layer) * 3
                        + strength * (2.1 * sin(Double(x) * 0.021 + time * 0.30 + Double(layer) * 2)
                                      + 1.2 * sin(Double(x) * 0.045 - time * 0.18))
                    wave.addLine(to: CGPoint(x: min(x, end), y: waveY))
                    x += 3
                }
                wave.addLine(to: CGPoint(x: end, y: 43)); wave.closeSubpath()
                var sheet = fill
                sheet.opacity = layer == 0 ? 0.48 : 0.20
                sheet.fill(wave, with: shade)
            }
            let gleam = CGFloat((time * 8 + Double(scale.rawValue) * 29)
                .truncatingRemainder(dividingBy: Double(size.width + 100))) - 100
            fill.fill(Path(CGRect(x: gleam, y: 16, width: 100, height: 27)),
                      with: .linearGradient(Gradient(colors: [.clear, .white.opacity(0.16 * strength), .clear]),
                                            startPoint: CGPoint(x: gleam, y: 0),
                                            endPoint: CGPoint(x: gleam + 100, y: 0)))

        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct TimelineTrack: View {
    let scale: TimelineScale
    @ObservedObject var store: TimelineStore
    let animated: Bool
    let passive: Bool
    @State private var appearedAt = ProcessInfo.processInfo.systemUptime
    @State private var animating = false
    @State private var selected: TimelineEvent?
    @State private var selectedSlice: TimelineSlice?
    @State private var hovered = false
    @State private var showing = false

    var body: some View {
        let interval = scale.interval(at: store.now, calendar: .current)
        let progress = position(store.now, in: interval)
        HStack(spacing: 7) {
            Text(scale.title).font(.system(size: 11, weight: .semibold)).frame(width: 16)
            TimelineView(.animation(minimumInterval: animating ? 1.0 / 30.0 : hovered ? 1.0 / 15.0 : passive ? 0.5 : 0.25,
                                    paused: !animated || !store.visible || ProcessInfo.processInfo.isLowPowerModeEnabled)) { frame in
                let decorative = animated && store.visible && !ProcessInfo.processInfo.isLowPowerModeEnabled
                let phase = decorative
                    ? min(1, max(0, (ProcessInfo.processInfo.systemUptime - appearedAt - 0.14) / TimelineDesign.sweepDuration)) : 1
                track(interval: interval, progress: progress, phase: phase,
                      ambientTime: decorative ? frame.date.timeIntervalSinceReferenceDate : 0,
                      ambientStrength: decorative ? TimelineMotion.ambientStrength(
                          elapsed: ProcessInfo.processInfo.systemUptime - appearedAt, hovered: hovered, passive: passive) : 0)
            }
            .frame(height: 49)
            Text("\(Int(progress * 100))%")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .monospacedDigit().foregroundStyle(.secondary).frame(width: 29, alignment: .trailing)
        }
        .opacity(showing ? 1 : 0)
        .offset(y: animated && !showing ? 3 : 0)
        .task {
            appearedAt = ProcessInfo.processInfo.systemUptime
            animating = animated && !ProcessInfo.processInfo.isLowPowerModeEnabled
            if animated { try? await Task.sleep(nanoseconds: 100_000_000) }
            guard !Task.isCancelled else { return }
            withAnimation(animated ? .easeOut(duration: 0.18) : nil) { showing = true }
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled else { return }
            animating = false
        }
        .onHover { hovered = $0 }
        .onChange(of: selected?.id) { _, _ in updateInteraction() }
        .onChange(of: selectedSlice?.id) { _, next in
            if next == nil { selected = nil }
            updateInteraction()
        }
        .onChange(of: store.events.map(\.id)) { _, ids in
            if let selected, !ids.contains(selected.id) { self.selected = nil }
        }
        .onDisappear { store.setInteracting(scale, false) }
        .popover(item: $selectedSlice, arrowEdge: .bottom) { slice in
            let component: Calendar.Component = slice.scale == .year ? .month : .day
            let span = Calendar.current.dateInterval(of: component, for: slice.date)!
            let matching = store.events.filter { $0.start < span.end && $0.end > span.start }
            if let selected {
                VStack(alignment: .leading, spacing: 0) {
                    Button("返回列表") { self.selected = nil }
                        .buttonStyle(.plain).font(.system(size: 11)).padding(.top, 12)
                    eventDetails(selected)
                }
            } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(slice.date.formatted(.dateTime.year().month().day()))
                    .font(.system(size: 12, weight: .semibold))
                if matching.isEmpty { Text("这段时间没有事件").foregroundStyle(.secondary) }
                ForEach(matching.prefix(8)) { event in
                    Button { selected = event } label: {
                        HStack(spacing: 5) {
                            Circle().fill(store.color(for: event)).frame(width: 6, height: 6)
                            Text(event.title).lineLimit(1)
                        }
                    }.buttonStyle(.plain)
                }
                if matching.count > 8 { Text("还有 \(matching.count - 8) 项").foregroundStyle(.secondary) }
            }.font(.system(size: 10)).padding(12).frame(width: 220, alignment: .leading)
            }
        }
    }

    private func updateInteraction() {
        store.setInteracting(scale, selected != nil || selectedSlice != nil)
    }

    private func eventDetails(_ event: TimelineEvent) -> some View {
            VStack(alignment: .leading, spacing: 7) {
                Text(event.title).font(.system(size: 13, weight: .semibold))
                Text("\(event.start.formatted(date: .abbreviated, time: event.isAllDay ? .omitted : .shortened)) – \(event.end.formatted(date: .abbreviated, time: event.isAllDay ? .omitted : .shortened))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text(event.calendarTitle).font(.system(size: 10)).foregroundStyle(store.color(for: event))
                HStack {
                    Button("在日历中打开") { store.openInCalendar(event) }
                    if let url = event.url { Button("相关链接") { NSWorkspace.shared.open(url) } }
                    Button(store.isImportant(event) ? "取消重要标记" : "标为重要") {
                        store.setImportant(event, !store.isImportant(event))
                    }
                }.font(.system(size: 10))
            }.padding(12).frame(width: 250, alignment: .leading)
            .onExitCommand { selected = nil }
    }

    private func track(interval: DateInterval, progress: Double, phase: Double,
                       ambientTime: TimeInterval, ambientStrength: Double) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            let events = store.visibleEvents(for: scale)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 7).fill(.primary.opacity(0.07))
                    .frame(height: 27).offset(y: 16)
                    .gesture(SpatialTapGesture().onEnded { tap in
                        guard scale != .day else { return }
                        let fraction = min(1, max(0, tap.location.x / max(1, width)))
                        let date = interval.start.addingTimeInterval(interval.duration * fraction)
                        selectedSlice = TimelineSlice(date: date, scale: scale)
                    })
                TimelineFlowField(scale: scale, fillWidth: width * progress * TimelineMotion.fillPhase(phase),
                                  time: ambientTime, strength: ambientStrength)
                    .frame(width: width, height: 49)
                ForEach(Array(scale.ticks(in: interval, calendar: .current).enumerated()), id: \.offset) { _, tick in
                    let x = width * position(tick.0, in: interval)
                    Rectangle().fill(.primary.opacity(0.25)).frame(width: 0.5, height: tick.1.isEmpty ? 4 : 7)
                        .offset(x: x, y: 17).allowsHitTesting(false)
                    if !tick.1.isEmpty {
                        Text(tick.1).font(.system(size: 8, design: .rounded)).foregroundStyle(.secondary)
                            .offset(x: min(width - 19, x), y: 1).allowsHitTesting(false)
                    }
                }
                ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                    let start = position(event.start, in: interval)
                    let end = position(event.end, in: interval)
                    let eventWidth = max(5, width * max(0, end - start))
                    let row = events.prefix(index).filter { $0.end > event.start && $0.start <= event.start }.count
                    let eventPhase = TimelineMotion.eventPhase(start: start, progress: progress, phase: phase)
                    if row < 2 {
                    Button { selected = event } label: {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(store.color(for: event).opacity(event.end < store.now ? 0.58 : 0.95))
                            .overlay {
                                RoundedRectangle(cornerRadius: 3)
                                    .strokeBorder(event.start <= store.now && event.end > store.now
                                        ? .white.opacity(0.7) : .black.opacity(0.42), lineWidth: 0.8)
                            }
                            .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                            .frame(width: event.isAllDay && scale == .day ? 7 : eventWidth, height: 7)
                            .scaleEffect(x: eventPhase, y: 1, anchor: .leading)
                            .overlay(alignment: .leading) {
                                if eventWidth > 54 && row == 0 && scale == .day {
                                    Text(event.title).font(.system(size: 7, weight: .medium)).lineLimit(1)
                                        .padding(.leading, 3).foregroundStyle(.black.opacity(0.8))
                                }
                            }
                    }
                    .buttonStyle(TimelineEventButtonStyle(animated: animated))
                    .popover(isPresented: Binding(get: { selectedSlice == nil && selected?.id == event.id },
                        set: { if !$0 && selected?.id == event.id { selected = nil } }), arrowEdge: .bottom) {
                        eventDetails(event)
                    }
                    .help("\(event.title) · \(event.start.formatted(date: .omitted, time: .shortened))–\(event.end.formatted(date: .omitted, time: .shortened)) · \(event.calendarTitle)")
                    .opacity(eventPhase)
                    .allowsHitTesting(eventPhase > 0.9)
                    .offset(x: width * start, y: event.isAllDay && scale == .day ? 12 : 26 + CGFloat(row) * 9)
                    .zIndex(2)
                    } else if row == 2 {
                        Button { selectedSlice = TimelineSlice(date: event.start, scale: scale) } label: {
                            Text("+\(max(1, events.filter { $0.start <= event.start && $0.end > event.start }.count - 2))")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(store.color(for: event))
                        }.buttonStyle(.plain).offset(x: min(width - 16, width * start), y: 10).zIndex(3)
                    }
                    if index < 5 && eventPhase > 0 && eventPhase < 1 {
                        ForEach(0..<2, id: \.self) { mote in
                            Circle().fill(store.color(for: event)).frame(width: 2, height: 2)
                                .opacity(sin(eventPhase * .pi) * 0.75)
                                .offset(x: width * start + min(eventWidth * eventPhase, 18)
                                        + CGFloat(mote * 3), y: 24 - CGFloat(eventPhase * Double(8 + mote * 5)))
                                .allowsHitTesting(false)
                        }
                    }
                }
                let head = width * progress
                Rectangle().fill(.primary.opacity(0.85)).frame(width: 1, height: 29).offset(x: head, y: 15)
                    .allowsHitTesting(false)
                Circle().fill(.white.opacity(phase > 0.82 && phase < 1 ? (1 - phase) * 2.5 : 0))
                    .frame(width: 12, height: 12).blur(radius: 3).offset(x: head - 5, y: 9)
                    .allowsHitTesting(false)
                Rectangle().fill(.primary).frame(width: 5, height: 5).rotationEffect(.degrees(45))
                    .offset(x: head - 2, y: 12).allowsHitTesting(false)
                if phase < 1 && phase > 0.02 {
                    let touching = events.first { abs(position($0.start, in: interval) - progress * TimelineMotion.fillPhase(phase)) < 0.025 }
                    Rectangle().fill((touching.map(store.color(for:)) ?? .white).opacity(0.75))
                        .frame(width: 3, height: 27)
                        .blur(radius: 2).offset(x: width * progress * TimelineMotion.fillPhase(phase), y: 16)
                }
                if phase > 0.82 && phase < 1 {
                    ForEach(0..<3, id: \.self) { index in
                        Circle().fill(TimelineDesign.palette[index]).frame(width: 3, height: 3)
                            .opacity((1 - phase) / 0.18)
                            .offset(x: head + CGFloat(index - 1) * CGFloat((phase - 0.82) * 24),
                                    y: 20 - CGFloat((phase - 0.82) * Double(20 + index * 5)))
                    }
                }
            }
            .frame(width: width, height: 49, alignment: .topLeading)
            .clipped()
        }
        .accessibilityLabel("\(scale.title)进度 \(Int(progress * 100))%，\(store.visibleEvents(for: scale).count) 个事件")
    }

    private func position(_ date: Date, in interval: DateInterval) -> Double {
        min(1, max(0, date.timeIntervalSince(interval.start) / interval.duration))
    }
}


private struct TimelineEventButtonStyle: ButtonStyle {
    let animated: Bool
    func makeBody(configuration: Configuration) -> some View {
        EventSurface(configuration: configuration, animated: animated)
    }
    private struct EventSurface: View {
        let configuration: ButtonStyleConfiguration
        let animated: Bool
        @State private var hovered = false
        var body: some View {
            configuration.label
                .brightness(hovered ? 0.10 : 0)
                .offset(y: animated && hovered ? -1 : 0)
                .scaleEffect(configuration.isPressed && animated ? 0.97 : 1)
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
                .animation(animated ? .easeOut(duration: 0.13) : nil, value: hovered)
                .animation(animated ? .easeOut(duration: 0.10) : nil, value: configuration.isPressed)
        }
    }
}
