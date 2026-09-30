import AppKit
import SwiftUI
import EventKit

enum TimelineDesign {
    static let width: CGFloat = 520
    static let rowHeight: CGFloat = 60
    static let headerHeight: CGFloat = 36
    static let sweepDuration = 0.92
    static let palette: [Color] = [
        Color(red: 0.39, green: 0.68, blue: 0.86), // 雾蓝
        Color(red: 0.28, green: 0.76, blue: 0.66), // 青绿
        Color(red: 0.57, green: 0.54, blue: 0.89), // 蓝紫
        Color(red: 0.96, green: 0.65, blue: 0.39), // 暖橙
        Color(red: 0.91, green: 0.48, blue: 0.61)  // 玫瑰
    ]
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

final class TimelineStore: ObservableObject {
    @Published private(set) var level = 1
    @Published private(set) var now = Date()
    @Published private(set) var events: [TimelineEvent] = []
    @Published private(set) var calendars: [EKCalendar] = []
    @Published private(set) var calendarEnabled = false
    @Published private(set) var calendarMessage = "开启日历以显示事件"
    @Published private(set) var visible = false
    var expansionChanged: ((Int) -> Void)?

    private let store = EKEventStore()
    private let defaults: UserDefaults
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var wakeObserver: NSObjectProtocol?
    private var paletteMap: [String: Int]
    private var lastBoundaryKey = ""

    init(defaults: UserDefaults = .standard, startTimer: Bool = true) {
        self.defaults = defaults
        paletteMap = defaults.dictionary(forKey: "notch.timeline.colors.v1") as? [String: Int] ?? [:]
        calendarEnabled = defaults.bool(forKey: "notch.timeline.calendarEnabled.v1")
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
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.refreshTime(forceEvents: true) }
                }
            if calendarEnabled { refreshCalendars() }
        }
    }

    deinit {
        timer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    func setLevel(_ value: Int) {
        let next = min(3, max(1, value))
        guard next != level else { return }
        level = next
        expansionChanged?(next)
        if defaults.bool(forKey: "notch.timeline.rememberLevel.v1") {
            defaults.set(next, forKey: "notch.timeline.level.v1")
        }
    }

    func open(pinned: Bool) {
        visible = true
        setLevel(pinned ? max(1, defaults.integer(forKey: "notch.timeline.level.v1")) : 1)
        refreshTime(forceEvents: true)
    }

    func hide() { visible = false }

    func rememberLevel(_ remember: Bool) {
        defaults.set(remember, forKey: "notch.timeline.rememberLevel.v1")
        if remember { defaults.set(level, forKey: "notch.timeline.level.v1") }
    }

    func refreshTime(forceEvents: Bool = false) {
        now = Date()
        let calendar = Calendar.current
        let key = "\(calendar.startOfDay(for: now).timeIntervalSince1970)-\(TimeZone.current.identifier)"
        if forceEvents || key != lastBoundaryKey {
            lastBoundaryKey = key
            if calendarEnabled { refreshCalendars() }
        }
    }

    func enableCalendar() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: calendarEnabled = true; persistCalendarEnabled(); refreshCalendars()
        case .notDetermined:
            store.requestFullAccessToEvents { [weak self] granted, error in
                Task { @MainActor in
                    guard let self else { return }
                    self.calendarEnabled = granted
                    self.calendarMessage = granted ? "" : (error?.localizedDescription ?? "未授权访问日历")
                    self.persistCalendarEnabled()
                    if granted { self.refreshCalendars() }
                }
            }
        default: calendarMessage = "请在系统设置中允许访问日历"
        }
    }

    func disableCalendar() {
        calendarEnabled = false
        events = []
        persistCalendarEnabled()
    }

    private func persistCalendarEnabled() {
        defaults.set(calendarEnabled, forKey: "notch.timeline.calendarEnabled.v1")
    }

    func isSelected(_ calendar: EKCalendar) -> Bool {
        let saved = defaults.stringArray(forKey: "notch.timeline.selectedCalendars.v1")
        return saved == nil || saved!.contains(calendar.calendarIdentifier)
    }

    func setSelected(_ calendar: EKCalendar, _ selected: Bool) {
        var ids = Set(defaults.stringArray(forKey: "notch.timeline.selectedCalendars.v1") ?? calendars.map(\.calendarIdentifier))
        if selected { ids.insert(calendar.calendarIdentifier) } else { ids.remove(calendar.calendarIdentifier) }
        defaults.set(Array(ids).sorted(), forKey: "notch.timeline.selectedCalendars.v1")
        refreshEvents()
    }

    private func refreshCalendars() {
        guard calendarEnabled, EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            calendarEnabled = false
            events = []
            return
        }
        calendars = store.calendars(for: .event).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        refreshEvents()
    }

    private func refreshEvents() {
        guard calendarEnabled else { return }
        let calendar = Calendar.current
        let span = TimelineScale.year.interval(at: now, calendar: calendar)
        let selected = calendars.filter(isSelected)
        guard !selected.isEmpty else { events = []; calendarMessage = "没有选中的日历"; return }
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

    func loadPreview(_ samples: [TimelineEvent]) { events = samples; calendarEnabled = true; calendarMessage = "" }
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
                        Image(systemName: "timeline.selection")
                        Text("时间轴").font(.system(size: 11, weight: .semibold))
                        if store.level < 3 { Image(systemName: "chevron.down").font(.system(size: 9)) }
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).help(store.level < 3 ? "增加下一条轨道" : "已显示全部轨道")
                if !store.calendarEnabled {
                    Button("接入日历") { store.enableCalendar() }
                        .buttonStyle(.plain).font(.system(size: 9)).foregroundStyle(.secondary)
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
                        Button("关闭日历联动") { store.disableCalendar() }
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
                control("xmark", "关闭时间轴") { onClose() }
            }.frame(height: TimelineDesign.headerHeight)
            ForEach(TimelineScale.allCases.prefix(store.level)) { scale in
                TimelineTrack(scale: scale, store: store, animated: !reduceMotion)
                    .frame(height: TimelineDesign.rowHeight)
            }
        }
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func control(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).frame(width: 24, height: 25) }
            .buttonStyle(CapsuleButtonStyle()).help(label).accessibilityLabel(label)
    }
}

private struct TimelineTrack: View {
    let scale: TimelineScale
    @ObservedObject var store: TimelineStore
    let animated: Bool
    @State private var appearedAt = ProcessInfo.processInfo.systemUptime
    @State private var animating = false
    @State private var selected: TimelineEvent?
    @State private var selectedSlice: TimelineSlice?
    @State private var hovered = false

    var body: some View {
        let interval = scale.interval(at: store.now, calendar: .current)
        let progress = position(store.now, in: interval)
        HStack(spacing: 7) {
            Text(scale.title).font(.system(size: 11, weight: .semibold)).frame(width: 16)
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animating || !store.visible || ProcessInfo.processInfo.isLowPowerModeEnabled)) { _ in
                let phase = animated && !ProcessInfo.processInfo.isLowPowerModeEnabled
                    ? min(1, max(0, (ProcessInfo.processInfo.systemUptime - appearedAt) / TimelineDesign.sweepDuration)) : 1
                track(interval: interval, progress: progress, phase: phase)
            }
            .frame(height: 49)
            Text("\(Int(progress * 100))%")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .monospacedDigit().foregroundStyle(.secondary).frame(width: 29, alignment: .trailing)
        }
        .onAppear {
            appearedAt = ProcessInfo.processInfo.systemUptime
            animating = animated && !ProcessInfo.processInfo.isLowPowerModeEnabled
            DispatchQueue.main.asyncAfter(deadline: .now() + TimelineDesign.sweepDuration + 0.03) {
                animating = false
            }
        }
        .onHover { hovered = $0 }
        .popover(item: $selected, arrowEdge: .bottom) { event in
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
        }
        .popover(item: $selectedSlice, arrowEdge: .bottom) { slice in
            let component: Calendar.Component = slice.scale == .year ? .month : .day
            let span = Calendar.current.dateInterval(of: component, for: slice.date)!
            let matching = store.events.filter { $0.start < span.end && $0.end > span.start }
            VStack(alignment: .leading, spacing: 8) {
                Text(slice.date.formatted(.dateTime.year().month().day()))
                    .font(.system(size: 12, weight: .semibold))
                if matching.isEmpty { Text("这段时间没有事件").foregroundStyle(.secondary) }
                ForEach(matching.prefix(8)) { event in
                    Button { selectedSlice = nil; selected = event } label: {
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

    private func track(interval: DateInterval, progress: Double, phase: Double) -> some View {
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
                LinearGradient(colors: [TimelineDesign.palette[0].opacity(0.50), TimelineDesign.palette[1].opacity(0.55), TimelineDesign.palette[2].opacity(0.48)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: max(0, width * progress * phase), height: 27)
                    .clipShape(RoundedRectangle(cornerRadius: 7)).offset(y: 16)
                    .allowsHitTesting(false)
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
                    let eventPhase = min(1, max(0, (phase - min(0.90, 0.14 + start * 0.65)) / 0.13))
                    if row < 2 {
                    Button { selected = event } label: {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(store.color(for: event).opacity(event.end < store.now ? 0.70 : 0.95))
                            .overlay {
                                RoundedRectangle(cornerRadius: 3)
                                    .strokeBorder(.white.opacity(event.start <= store.now && event.end > store.now ? 0.65 : 0), lineWidth: 0.8)
                            }
                            .frame(width: (event.isAllDay && scale == .day ? 7 : eventWidth) * eventPhase, height: 7)
                            .overlay(alignment: .leading) {
                                if eventWidth > 54 && row == 0 && scale == .day {
                                    Text(event.title).font(.system(size: 7, weight: .medium)).lineLimit(1)
                                        .padding(.leading, 3).foregroundStyle(.black.opacity(0.8))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .help("\(event.title) · \(event.calendarTitle)")
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
                    if index < 5 && phase > 0.08 && phase < 0.94 && abs(phase - (0.14 + start * 0.65)) < 0.09 {
                        Circle().fill(store.color(for: event)).frame(width: 3, height: 3)
                            .offset(x: width * start + 3, y: 21 - CGFloat(index % 2) * 4)
                    }
                }
                let head = width * progress
                Rectangle().fill(.white.opacity(0.9)).frame(width: 1, height: 29).offset(x: head, y: 15)
                    .allowsHitTesting(false)
                Rectangle().fill(.white).frame(width: 5, height: 5).rotationEffect(.degrees(45))
                    .offset(x: head - 2, y: 12).allowsHitTesting(false)
                if phase < 1 && phase > 0.02 {
                    let touching = events.first { abs(position($0.start, in: interval) - progress * phase) < 0.025 }
                    Rectangle().fill((touching.map(store.color(for:)) ?? .white).opacity(0.75))
                        .frame(width: 3, height: 27)
                        .blur(radius: 2).offset(x: width * progress * phase, y: 16)
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
