import AppKit
import SwiftUI
import EventKit
import Sparkle

struct Module: Codable {
    let id: String
    let title: String
    let detail: String
}

struct SceneConfig: Codable {
    let ballDiameter: CGFloat
    let spacing: CGFloat
    let emergeDuration: Double
    let collapseDelay: Double
    let maxColumns: Int
    let modules: [Module]

    static let fallback = SceneConfig(
        ballDiameter: 22, spacing: 12, emergeDuration: 0.32,
        collapseDelay: 0.55, maxColumns: 7,
        modules: [
            Module(id: "reminders", title: "提醒事项", detail: "查看、新增和完成提醒事项"),
            Module(id: "notes", title: "便笺", detail: "查看和新建 Apple 备忘录"),
            Module(id: "music", title: "音乐", detail: "系统正在播放与歌词"),
            Module(id: "pomodoro", title: "番茄钟", detail: "专注、休息与统计")
        ]
    )

    static func load() -> SceneConfig {
        let external = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("scene.json")
        let url = FileManager.default.fileExists(atPath: external.path)
            ? external : Bundle.main.url(forResource: "scene", withExtension: "json")
        guard let url,
              let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(SceneConfig.self, from: data),
              config.ballDiameter >= 8, config.ballDiameter <= 48,
              config.spacing >= 0, config.spacing <= 80,
              config.emergeDuration > 0, config.emergeDuration <= 3,
              config.collapseDelay.isFinite, (0.15...5).contains(config.collapseDelay),
              config.maxColumns > 0, config.maxColumns <= 12,
              config.modules.count <= 30 else { return .fallback }
        return SceneConfig(
            ballDiameter: config.ballDiameter, spacing: config.spacing,
            emergeDuration: config.emergeDuration,
            collapseDelay: config.collapseDelay, maxColumns: config.maxColumns,
            modules: config.modules.map { module in
                module.id == "timer"
                    ? Module(id: "pomodoro", title: "番茄钟", detail: "专注、休息与统计")
                    : module
            }
        )
    }
}

private func text(_ value: String, size: CGFloat, weight: NSFont.Weight,
                  color: NSColor, at point: NSPoint) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color
    ]
    value.draw(at: point, withAttributes: attributes)
}

final class ModuleStore: ObservableObject {
    struct ReminderRow: Identifiable {
        let id: String
        let title: String
        let notes: String?
        let dueText: String?
    }

    @Published private(set) var reminderSummary = "点击以读取提醒事项"
    @Published private(set) var reminderCount = 0
    @Published private(set) var reminderAccess = false
    @Published private(set) var reminderRows: [ReminderRow] = []
    @Published private(set) var reminderExpanded = false
    @Published var focusedReminderID: String?
    @Published var addingReminder = false
    @Published var newReminder = ""
    @Published var newReminderHasDue = false
    @Published var newReminderDueDate = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
    @Published var newReminderAlarm = true
    var reminderExpansionChanged: ((Bool) -> Void)?

    private let eventStore = EKEventStore()
    private var reminders: [EKReminder] = []
    init() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged,
                                               object: eventStore, queue: .main) { [weak self] _ in
            self?.refreshReminders()
        }
    }

    func openReminders() {
        setReminderExpanded(false)
        addingReminder = false
        newReminder = ""
        focusedReminderID = nil
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess:
            reminderAccess = true
            refreshReminders()
        case .notDetermined:
            eventStore.requestFullAccessToReminders { [weak self] granted, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.reminderAccess = granted
                    self.reminderSummary = granted ? "正在读取…" :
                        (error?.localizedDescription ?? "未授权访问提醒事项")
                    if granted { self.refreshReminders() }
                }
            }
        default:
            reminderAccess = false
            reminderSummary = "请在系统设置中允许访问提醒事项"
        }
    }

    func refreshReminders() {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { return }
        let predicate = eventStore.predicateForReminders(in: nil)
        eventStore.fetchReminders(matching: predicate) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.reminders = (result ?? []).filter { !$0.isCompleted }
                    .sorted { (Self.dueDate($0.dueDateComponents) ?? .distantFuture)
                            < (Self.dueDate($1.dueDateComponents) ?? .distantFuture) }
                self.reminderCount = self.reminders.count
                self.reminderSummary = self.reminders.first?.title ?? "没有未完成事项"
                self.reminderRows = self.reminders.map {
                    let components = $0.dueDateComponents
                    let due = Self.dueDate(components).map {
                        DateFormatter.localizedString(from: $0, dateStyle: .short,
                            timeStyle: components?.hour == nil ? .none : .short)
                    }
                    return ReminderRow(id: $0.calendarItemIdentifier, title: $0.title,
                                       notes: $0.notes, dueText: due)
                }
                if !self.reminderRows.contains(where: { $0.id == self.focusedReminderID }) {
                    self.focusedReminderID = nil
                }
            }
        }
    }

    private static func dueDate(_ components: DateComponents?) -> Date? {
        guard var components else { return nil }
        components.calendar = components.calendar ?? Calendar(identifier: .gregorian)
        return components.date
    }

    @discardableResult func addReminder(_ title: String, dueDate: Date?, alert: Bool) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard reminderAccess, !title.isEmpty else { return false }
        guard let calendar = eventStore.defaultCalendarForNewReminders() else {
            reminderSummary = "请先在提醒事项中设置默认列表"
            return false
        }
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        reminder.calendar = calendar
        if let dueDate {
            var components = Calendar(identifier: .gregorian)
                .dateComponents([.year, .month, .day, .hour, .minute], from: dueDate)
            components.calendar = Calendar(identifier: .gregorian)
            components.timeZone = .current
            reminder.dueDateComponents = components
            if alert { reminder.addAlarm(EKAlarm(absoluteDate: dueDate)) }
        }
        do {
            try eventStore.save(reminder, commit: true)
            refreshReminders()
            return true
        } catch { reminderSummary = error.localizedDescription; return false }
    }

    func completeFirstReminder() {
        guard let id = reminders.first?.calendarItemIdentifier else { return }
        completeReminder(id: id)
    }

    func completeReminder(id: String) {
        guard reminderAccess,
              let reminder = reminders.first(where: { $0.calendarItemIdentifier == id }) else { return }
        reminder.isCompleted = true
        do {
            try eventStore.save(reminder, commit: true)
            refreshReminders()
        } catch { reminderSummary = error.localizedDescription }
    }

    func setReminderExpanded(_ expanded: Bool) {
        guard reminderExpanded != expanded else { return }
        reminderExpanded = expanded
        reminderExpansionChanged?(expanded)
    }
}

final class CapsuleInteraction: ObservableObject {
    @Published var controlsArmed = false
    @Published var backdropRevision = 0
    @Published private(set) var pinnedModules: Set<String>
    private(set) var lastPinnedID: String?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let saved = defaults.array(forKey: "notch.pinnedModules.v1") as? [String] {
            pinnedModules = Set(saved)
        } else {
            pinnedModules = defaults.bool(forKey: "notch.music.pinned.v1") ? ["music"] : []
        }
        lastPinnedID = defaults.string(forKey: "notch.lastPinnedModule.v1")
    }

    func isPinned(_ id: String) -> Bool { pinnedModules.contains(id == "timer" ? "pomodoro" : id) }

    func setPinned(_ id: String, _ pinned: Bool) {
        let id = id == "timer" ? "pomodoro" : id
        if pinned { pinnedModules.insert(id); lastPinnedID = id }
        else { pinnedModules.remove(id) }
        defaults.set(Array(pinnedModules).sorted(), forKey: "notch.pinnedModules.v1")
        defaults.set(lastPinnedID, forKey: "notch.lastPinnedModule.v1")
    }
}

@available(macOS 26.0, *)
private struct NativePillGlass: NSViewRepresentable {
    let clearPassThrough: Bool
    let corner: CGFloat

    func makeNSView(context: Context) -> NSGlassEffectView {
        let glass = NSGlassEffectView()
        // Keep live text/control updates outside the native material subtree.
        glass.contentView = NSView()
        configure(glass)
        return glass
    }

    func updateNSView(_ glass: NSGlassEffectView, context: Context) { configure(glass) }

    fileprivate func configure(_ glass: NSGlassEffectView) {
        glass.style = clearPassThrough ? .clear : .regular
        glass.tintColor = nil
        glass.cornerRadius = corner
        // System clear glass can adapt its body tint. Limit only the backing layer,
        // so even an opaque adapted tint can't cover the application underneath.
        glass.alphaValue = clearPassThrough ? 0.22 : 1
        if #available(macOS 27.0, *) { glass.effectIsInteractive = !clearPassThrough }
    }
}

private struct IridescentRim: View {
    let corner: CGFloat
    let passive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: reduceMotion || passive || ProcessInfo.processInfo.isLowPowerModeEnabled)) { timeline in
            let time = reduceMotion || passive || ProcessInfo.processInfo.isLowPowerModeEnabled ? 0 : timeline.date.timeIntervalSinceReferenceDate
            let breathing = reduceMotion ? 1 : 0.94 + 0.06 * sin(time * 0.72)
            let spectrum = colorField(time: time)
            ZStack {
                spectrum
                    .mask(RoundedRectangle(cornerRadius: corner).strokeBorder(lineWidth: 4))
                    .blur(radius: 2)
                    .opacity(0.38)
                spectrum
                    .mask(RoundedRectangle(cornerRadius: corner).strokeBorder(lineWidth: 2))
                    .blur(radius: 1.2)
                    .opacity(0.62)
                spectrum
                    .mask(RoundedRectangle(cornerRadius: corner).strokeBorder(lineWidth: 1.2))
                    .opacity(0.9)
                RoundedRectangle(cornerRadius: corner).inset(by: 0.6)
                    .stroke(LinearGradient(colors: [.white.opacity(0.52), .white.opacity(0.12), .white.opacity(0.32)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.45)
            }
            .mask(RoundedRectangle(cornerRadius: corner).strokeBorder(lineWidth: 7))
            .opacity(breathing * (passive ? 0.48 : 0.76))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func colorField(time: Double) -> some View {
        let x1 = Float(0.33 + 0.10 * sin(time * 0.41))
        let x2 = Float(0.67 + 0.10 * sin(time * 0.33 + 1.8))
        let y1 = Float(0.50 + 0.20 * sin(time * 0.47 + 0.7))
        let y2 = Float(0.50 + 0.20 * sin(time * 0.38 + 2.1))
        let colors: [Color] = [
            Color(red: 0.45, green: 0.88, blue: 1), Color(red: 0.49, green: 0.60, blue: 1),
            Color(red: 0.82, green: 0.48, blue: 1), Color(red: 1, green: 0.65, blue: 0.81),
            Color(red: 0.64, green: 0.72, blue: 1), Color(red: 0.93, green: 0.76, blue: 1),
            Color(red: 1, green: 0.84, blue: 0.91), Color(red: 1, green: 0.72, blue: 0.52),
            Color(red: 1, green: 0.76, blue: 0.49), Color(red: 1, green: 0.51, blue: 0.71),
            Color(red: 0.68, green: 0.51, blue: 1), Color(red: 0.48, green: 0.91, blue: 1)
        ]
        if #available(macOS 15.0, *) {
            MeshGradient(width: 4, height: 3, points: [
                SIMD2<Float>(0, 0), SIMD2<Float>(x1, 0), SIMD2<Float>(x2, 0), SIMD2<Float>(1, 0),
                SIMD2<Float>(0, 0.5), SIMD2<Float>(x1, y1), SIMD2<Float>(x2, y2), SIMD2<Float>(1, 0.5),
                SIMD2<Float>(0, 1), SIMD2<Float>(x1, 1), SIMD2<Float>(x2, 1), SIMD2<Float>(1, 1)
            ], colors: colors)
        } else {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

struct BreakHint: Identifiable {
    let id: String
    let symbol: String
    let title: String
    let seconds: Double
    static let longBreak = [
        BreakHint(id: "water", symbol: "drop.fill", title: "喝水", seconds: 5),
        BreakHint(id: "stand", symbol: "figure.stand", title: "站立", seconds: 10)
    ]

    static func offsets(count: Int, diameter: CGFloat = 36, gap: CGFloat = 14) -> [CGFloat] {
        guard count > 0 else { return [] }
        return (0..<count).map { (CGFloat($0) - CGFloat(count - 1) / 2) * (diameter + gap) }
    }

    static func centeredTargets(_ hints: [BreakHint], elapsed: Double) -> [CGFloat] {
        let offsets = offsets(count: hints.count)
        let weights = hints.map { hint -> CGFloat in
            let exit = min(1, max(0, (elapsed - hint.seconds) / 0.55))
            return CGFloat(1 - exit * exit * (3 - 2 * exit))
        }
        let mass = weights.reduce(CGFloat(0)) { $0 + $1 * $1 }
        guard mass > 0.001 else { return Array(repeating: 0, count: hints.count) }
        let center = zip(offsets, weights).reduce(CGFloat(0)) { $0 + $1.0 * $1.1 * $1.1 } / mass
        return offsets.map { $0 - center }
    }

}

private struct LongBreakHints: View {
    @ObservedObject var pomodoro: PomodoroModel
    let travelDistance: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let hints = BreakHint.longBreak

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
            GeometryReader { geometry in
                let elapsed = pomodoro.longBreakPromptElapsed ?? 100
                let offsets = BreakHint.centeredTargets(hints, elapsed: elapsed)
                ForEach(Array(hints.enumerated()), id: \.element.id) { index, hint in
                    let enter = min(1, max(0, elapsed / 0.45))
                    let emerge = 1 - pow(1 - enter, 3)
                    let exit = min(1, max(0, (elapsed - hint.seconds) / 0.55))
                    let returning = exit * exit * (3 - 2 * exit)
                    let spread = emerge * (1 - returning)
                    let remaining = max(0, hint.seconds - elapsed)
                    VStack(spacing: 3) {
                        ZStack {
                            Circle().fill(.ultraThinMaterial)
                            Circle().stroke(.white.opacity(0.25), lineWidth: 1.5)
                            Circle().trim(from: 0, to: remaining / hint.seconds)
                                .stroke(.white.opacity(0.92), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Image(systemName: hint.symbol).font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.white)
                        }.frame(width: 36, height: 36)
                        Text(hint.title).font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white).shadow(color: .black.opacity(0.5), radius: 1)
                    }
                    .scaleEffect(reduceMotion ? 1 : 0.15 + 0.85 * spread, anchor: .top)
                    .opacity(enter * (1 - returning))
                    .position(x: geometry.size.width / 2 + offsets[index] * (reduceMotion ? 1 : spread),
                              y: 24 - (reduceMotion ? 0 : travelDistance * (1 - spread)))
                    .accessibilityLabel("\(hint.title)，\(Int(ceil(remaining)))秒")
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct GlassPill: View {
    @Environment(\.colorScheme) private var colorScheme
    let module: Module
    @ObservedObject var store: ModuleStore
    @ObservedObject var systemApps: SystemAppsStore
    @ObservedObject var pomodoro: PomodoroModel
    @ObservedObject var interaction: CapsuleInteraction
    let onClose: () -> Void

    private var locked: Bool {
        interaction.isPinned(module.id)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var accent: Color { CapsuleTheme.accent(module.id) }
    private var clearPassThrough: Bool { locked && !interaction.controlsArmed }
    private var detailAnimation: Animation? { reduceMotion ? nil : .easeOut(duration: 0.24) }

    var body: some View {
        let detailOpen = (module.id == "reminders" && store.reminderExpanded)
            || (module.id == "notes" && systemApps.notesExpanded)
            || (module.id == "music" && systemApps.musicExpanded)
            || ((module.id == "pomodoro" || module.id == "timer") && pomodoro.expanded)
        let corner: CGFloat = detailOpen ? 22 : 18
        ZStack {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: corner).fill(Color(nsColor: .windowBackgroundColor))
            } else if #available(macOS 26.0, *) {
                NativePillGlass(clearPassThrough: clearPassThrough, corner: corner)
                    .id(interaction.backdropRevision)
                    .allowsHitTesting(false)
            } else {
                if clearPassThrough {
                    RoundedRectangle(cornerRadius: corner).fill(.white.opacity(0.06))
                } else {
                    RoundedRectangle(cornerRadius: corner).fill(.ultraThinMaterial)
                }
            }
            content.padding(.horizontal, detailOpen ? 16 : 10)
                .environment(\.colorScheme, clearPassThrough && !reduceTransparency ? .dark : colorScheme)
                .tint(accent)
                .accentColor(accent)
                .shadow(color: .black.opacity(clearPassThrough ? 0.5 : 0), radius: 1.5, y: 0.5)
                .clipShape(RoundedRectangle(cornerRadius: corner))
        }
        .overlay {
            RoundedRectangle(cornerRadius: corner)
                .strokeBorder(.white.opacity(clearPassThrough ? 0.3 : 0.18), lineWidth: 0.7)
                .allowsHitTesting(false)
        }
        .overlay {
            IridescentRim(corner: corner, passive: clearPassThrough)
        }
        .contentShape(RoundedRectangle(cornerRadius: corner))
        .animation(.easeOut(duration: 0.22), value: clearPassThrough)
        .accessibilityValue(locked ? (clearPassThrough ? "已锁定，点击穿透" : "已锁定，可操作") : "可操作")
        .animation(detailAnimation, value: store.reminderExpanded)
        .animation(detailAnimation, value: systemApps.notesExpanded)
        .animation(detailAnimation, value: systemApps.musicExpanded)
        .animation(detailAnimation, value: pomodoro.expanded)
    }

    @ViewBuilder private var content: some View {
        if module.id == "reminders" && store.reminderExpanded {
            remindersDetail
        } else if module.id == "notes" && systemApps.notesExpanded {
            notesDetail
        } else if module.id == "music" && systemApps.musicExpanded {
            musicDetail
        } else if (module.id == "pomodoro" || module.id == "timer") && pomodoro.expanded {
            pomodoroDetail
        } else {
        HStack(spacing: 8) {
            if module.id == "pomodoro" || module.id == "timer" {
                ZStack {
                    Circle().stroke(.primary.opacity(0.18), lineWidth: 2)
                    Circle().trim(from: 0, to: min(1, max(0, pomodoro.progress)))
                        .stroke(.primary.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: pomodoro.phase == .focus ? "timer" : "cup.and.saucer.fill")
                        .font(.system(size: 9))
                }.frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(pomodoro.phase.title + (pomodoro.isRunning ? "" : pomodoro.isSessionActive ? " · 已暂停" : " · 待开始"))
                        .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                    Text(pomodoro.activeFocusName ?? (pomodoro.phase == .focus ? "命名专注" : "休息一下"))
                        .font(.system(size: 10, weight: .medium)).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(pomodoro.timeText).font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                iconButton(pomodoro.isRunning ? "pause.fill" : "play.fill") { pomodoro.toggleRunning() }
                iconButton("chevron.down") { pomodoro.setExpanded(true) }
            } else if module.id == "reminders" {
                Button { store.setReminderExpanded(true) } label: {
                    HStack(spacing: 5) {
                        Text(store.reminderAccess ? "提醒事项" : store.reminderSummary)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if store.reminderAccess {
                            Text("\(store.reminderCount)")
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Text("查看").font(.system(size: 10, weight: .medium))
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            } else if module.id == "music" {
                musicCompact
            } else if module.id == "notes" {
                Button { systemApps.setExpanded(module.id, true) } label: {
                    HStack(spacing: 5) {
                        Text("便笺")
                            .font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            } else {
                Text(module.title).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                Text("演示模块").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if module.id != "music" {
                iconButton(interaction.isPinned(module.id) ? "pin.fill" : "pin") { togglePin() }
                if module.id == "pomodoro" || module.id == "timer" {
                    iconButton(pomodoro.isSessionActive ? "stop.fill" : "xmark") {
                        if pomodoro.isSessionActive { pomodoro.endSession() }
                        interaction.setPinned(module.id, false)
                        onClose()
                    }.help(pomodoro.isSessionActive ? "结束并记录本次专注" : "关闭番茄钟")
                } else {
                    iconButton("xmark") {
                        interaction.setPinned(module.id, false)
                        onClose()
                    }
                }
            }
        }
        }
    }

    private func togglePin() {
        let pinned = !interaction.isPinned(module.id)
        interaction.setPinned(module.id, pinned)
        if module.id == "music" { systemApps.setMusicPinned(pinned) }
    }

    private var musicCompact: some View {
        GeometryReader { geometry in
            // Choose only from the available space, never the current lyric's ideal width.
            if MusicPresentation.usesFullCompact(width: geometry.size.width) {
                musicCompactFull.frame(width: geometry.size.width, height: geometry.size.height)
            } else {
                HStack(spacing: 5) {
                    Button { systemApps.setExpanded("music", true) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(systemApps.musicTitle).font(.system(size: 10, weight: .semibold))
                            Text(systemApps.currentLyricText).font(.system(size: 10)).foregroundStyle(.secondary)
                        }.lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                    iconButton(systemApps.musicPlaying ? "pause.fill" : "play.fill", label: systemApps.musicPlaying ? "暂停播放" : "播放") {
                        systemApps.musicCommand("toggle")
                    }
                    iconButton("chevron.down") { systemApps.setExpanded("music", true) }
                }.frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
    }

    private var musicCompactFull: some View {
        HStack(spacing: 5) {
            musicArtwork(size: 28)
            Button { systemApps.setExpanded("music", true) } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(systemApps.musicTitle)
                        .font(.system(size: 10, weight: .semibold)).lineLimit(1)
                    Text(systemApps.musicArtist)
                        .font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1)
                }.frame(width: 88, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Rectangle().fill(.primary.opacity(0.13)).frame(width: 1, height: 18)
            Button { systemApps.setExpanded("music", true) } label: {
                Text(systemApps.currentLyricText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(systemApps.currentLyricIndex == nil ? .secondary : .primary)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
            iconButton("backward.end.fill") { systemApps.musicCommand("previous") }
            iconButton(systemApps.musicPlaying ? "pause.fill" : "play.fill") {
                systemApps.musicCommand("toggle")
            }
            iconButton("forward.end.fill") { systemApps.musicCommand("next") }
            iconButton(interaction.isPinned("music") ? "pin.fill" : "pin") {
                togglePin()
            }
            iconButton("arrow.up.left.and.arrow.down.right") {
                systemApps.setExpanded("music", true)
            }
        }
    }

    private var pomodoroDetail: some View {
        ScrollView {
            VStack(spacing: 14) {
                detailHeader("番茄钟", subtitle: pomodoro.isSessionActive ? "一件事，专心做好" : "为下一段专注留出空间") {
                    pomodoro.setExpanded(false)
                }
                HStack(spacing: 18) {
                    ZStack {
                        Circle().stroke(accent.opacity(0.12), lineWidth: 5)
                        Circle().trim(from: 0, to: min(1, max(0, pomodoro.progress)))
                            .stroke(accent.gradient, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: 3) {
                            Text(pomodoro.timeText)
                                .font(.system(size: 24, weight: .medium, design: .rounded)).monospacedDigit()
                                .contentTransition(.numericText(countsDown: true))
                                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: pomodoro.secondsRemaining)
                            Text(pomodoro.phase.title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        }
                    }.frame(width: 98, height: 98)
                    VStack(alignment: .leading, spacing: 9) {
                        if let name = pomodoro.activeFocusName {
                            Text(name).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                            Label(pomodoro.isRunning ? "正在专注" : "已暂停", systemImage: pomodoro.isRunning ? "smallcircle.filled.circle" : "pause.circle")
                                .font(.system(size: 11)).foregroundStyle(accent)
                        } else {
                            TextField("这次专注做什么？", text: $pomodoro.focusDraft)
                                .textFieldStyle(.plain).font(.system(size: 12))
                                .padding(10).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                                .onSubmit { pomodoro.start() }
                            Text(pomodoro.nameError ? "先写下一个小目标，再开始" : "输入目标，按回车开始")
                                .font(.system(size: 10)).foregroundStyle(pomodoro.nameError ? accent : .secondary)
                        }
                        Button { pomodoro.toggleRunning() } label: {
                            Label(pomodoro.isRunning ? "暂停" : pomodoro.isSessionActive ? "继续" : "开始专注",
                                  systemImage: pomodoro.isRunning ? "pause.fill" : "play.fill")
                                .font(.system(size: 11, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 32)
                        }.buttonStyle(CapsuleButtonStyle(prominent: true))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(12).background(accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
                HStack(spacing: 8) {
                    labeledButton("跳过阶段", symbol: "forward.end") { pomodoro.skipPhase() }
                    labeledButton("重置计时", symbol: "arrow.counterclockwise") { pomodoro.resetCurrent() }
                    if pomodoro.isSessionActive {
                        labeledButton("结束并记录", symbol: "stop.fill") {
                            pomodoro.endSession(); interaction.setPinned(module.id, false); onClose()
                        }
                    }
                }
                VStack(spacing: 8) {
                    HStack {
                        Label("环境声", systemImage: "waveform").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Button(pomodoro.ambientOn ? "停止播放" : "播放混音") { pomodoro.toggleAmbient() }
                            .font(.system(size: 10, weight: .medium)).buttonStyle(.plain).foregroundStyle(accent)
                    }
                    HStack(spacing: 6) {
                        Text("底噪").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        ForEach(AmbientBase.allCases, id: \.self) { base in
                            Button(base.title) { pomodoro.setAmbientBase(base) }
                                .font(.system(size: 10, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 5)
                                .background(pomodoro.ambientSettings.base == base ? accent.opacity(0.16) : .clear, in: Capsule())
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(pomodoro.ambientSettings.base == base ? .isSelected : [])
                        }
                    }
                    ForEach(AmbientLayer.allCases, id: \.self) { layer in
                        NeutralLevelSlider(title: layer.title, symbol: layer.symbol,
                            value: Binding(get: { pomodoro.ambientSettings.volume(for: layer) },
                                           set: { pomodoro.setAmbientVolume(layer, $0) }),
                            enabled: layer != .base || pomodoro.ambientSettings.base != .off)
                    }
                    if let error = pomodoro.soundError {
                        Text(error).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }.padding(12).background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
            }.padding(.vertical, 14)
        }.scrollIndicators(.hidden)
    }

    private func detailHeader(_ title: String, subtitle: String, collapse: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: CapsuleTheme.symbol(module.id)).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accent).frame(width: 30, height: 30)
                .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            iconButton(interaction.isPinned(module.id) ? "pin.fill" : "pin") { togglePin() }
            iconButton("chevron.up", action: collapse)
        }
    }

    private func labeledButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 10, weight: .medium))
                .frame(maxWidth: .infinity).frame(height: 30)
        }.buttonStyle(CapsuleButtonStyle())
    }

    private var remindersDetail: some View {
        VStack(alignment: .leading, spacing: 7) {
            detailHeader("提醒事项", subtitle: "\(store.reminderCount) 项待办") {
                store.setReminderExpanded(false)
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if store.reminderRows.isEmpty {
                        Text(store.reminderSummary)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    ForEach(store.reminderRows) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .top, spacing: 8) {
                                Button { store.completeReminder(id: row.id) } label: {
                                    Image(systemName: "circle")
                                        .font(.system(size: 13))
                                        .frame(width: 18, height: 18)
                                }.buttonStyle(.plain).help("完成此提醒事项")
                                    .accessibilityLabel("完成：\(row.title)")
                                Button {
                                    store.focusedReminderID = store.focusedReminderID == row.id
                                        ? nil : row.id
                                } label: {
                                    Text(row.title)
                                        .font(.system(size: 11))
                                        .lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain)
                            }
                            if store.focusedReminderID == row.id {
                                if let due = row.dueText {
                                    Text(due).font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                if let notes = row.notes, !notes.isEmpty {
                                    Text(notes).font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if store.reminderAccess {
                HStack(spacing: 6) {
                    TextField("新增提醒事项", text: $store.newReminder)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .onSubmit { saveReminder() }
                    iconButton("plus") { saveReminder() }
                }
                .padding(9).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                HStack(spacing: 8) {
                    Toggle("到期时间", isOn: $store.newReminderHasDue)
                        .toggleStyle(.checkbox).font(.system(size: 10))
                    Spacer(minLength: 0)
                }
                if store.newReminderHasDue {
                    DatePicker("", selection: $store.newReminderDueDate,
                               displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden().datePickerStyle(.compact)
                        .font(.system(size: 10))
                    Toggle("到期时提醒", isOn: $store.newReminderAlarm)
                        .toggleStyle(.checkbox).font(.system(size: 10))
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var notesDetail: some View {
        VStack(alignment: .leading, spacing: 7) {
            detailHeader("便笺", subtitle: "随手记下，稍后展开") {
                systemApps.setExpanded("notes", false)
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if systemApps.notes.isEmpty {
                        Text(systemApps.notesSummary).font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(systemApps.notes) { note in
                        Button { systemApps.showNote(note.id) } label: {
                            HStack {
                                Text(note.title).lineLimit(1)
                                Spacer()
                                Image(systemName: "arrow.up.forward.app")
                            }.font(.system(size: 12)).padding(10)
                                .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 6) {
                TextField("快速新建备忘录", text: $systemApps.noteDraft)
                    .textFieldStyle(.plain).font(.system(size: 11))
                    .onSubmit { systemApps.createNote() }
                iconButton("plus") { systemApps.createNote() }
            }.padding(9).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Text("点标题在备忘录中打开").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                iconButton("arrow.clockwise") { systemApps.openNotes() }
            }
            Text("读取默认账户")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }.padding(.vertical, 8)
    }

    private var musicDetail: some View {
        GeometryReader { geometry in
            if MusicPresentation.usesFullDetail(width: geometry.size.width) {
                musicDetailFull.frame(width: geometry.size.width, height: geometry.size.height)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(systemApps.musicTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 2)
                        iconButton("chevron.up") { systemApps.setExpanded("music", false) }
                    }
                    Text(systemApps.musicArtist).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    HStack {
                        iconButton("backward.end.fill") { systemApps.musicCommand("previous") }
                        iconButton(systemApps.musicPlaying ? "pause.fill" : "play.fill") { systemApps.musicCommand("toggle") }
                        iconButton("forward.end.fill") { systemApps.musicCommand("next") }
                        Spacer(minLength: 0)
                        iconButton(interaction.isPinned("music") ? "pin.fill" : "pin") { togglePin() }
                    }
                    Text(systemApps.currentLyricText).font(.system(size: 11)).lineLimit(2)
                    lyricActions
                }.padding(.vertical, 10).frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
    }

    private var musicDetailFull: some View {
        HStack(alignment: .center, spacing: 16) {
            musicArtwork(size: 120)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 3) {
                    Text(systemApps.musicTitle)
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    iconButton(interaction.isPinned("music") ? "pin.fill" : "pin") {
                        togglePin()
                    }
                    iconButton("arrow.down.right.and.arrow.up.left") {
                        systemApps.setExpanded("music", false)
                    }
                    iconButton("xmark") {
                        systemApps.setMusicPinned(false)
                        onClose()
                    }
                }
                Text("\(systemApps.musicArtist) · \(systemApps.musicSource)")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 12) {
                    iconButton("backward.end.fill") { systemApps.musicCommand("previous") }
                    iconButton(systemApps.musicPlaying ? "pause.fill" : "play.fill") {
                        systemApps.musicCommand("toggle")
                    }
                    iconButton("forward.end.fill") { systemApps.musicCommand("next") }
                    Spacer(minLength: 0)
                    Button("打开播放器") { systemApps.launchMusic() }
                        .buttonStyle(.plain).font(.system(size: 9)).foregroundStyle(.secondary)
                }
                GeometryReader { geometry in
                    Capsule().fill(.primary.opacity(0.13))
                        .overlay(alignment: .leading) {
                            Capsule().fill(.primary.opacity(0.7))
                                .frame(width: geometry.size.width * min(1, max(0,
                                    systemApps.musicElapsed / max(1, systemApps.musicDuration))))
                        }
                }.frame(height: 3)
                if let index = systemApps.currentLyricIndex {
                    Text(systemApps.timedLyrics[index].text)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .lineLimit(2).frame(height: 36, alignment: .leading)
                    Text(index + 1 < systemApps.timedLyrics.count ? systemApps.timedLyrics[index + 1].text : " ")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).frame(height: 13)
                } else {
                    Text(systemApps.currentLyricText)
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                lyricActions
            }
        }.padding(.vertical, 8)

    }

    @ViewBuilder private var lyricActions: some View {
        HStack(spacing: 8) {
            Menu {
                if !systemApps.extraLyricsEnabled {
                    Button("开启自动歌词查询 · QQ、酷狗、LRCLIB，未命中回退 VV") {
                        systemApps.enableExtraLyrics()
                    }
                }
                if systemApps.musicSourceBundle == "com.netease.163music" && !systemApps.neteaseLyricsEnabled {
                    Button("开启网易云歌词 · 未命中自动回退 VV") { systemApps.enableNeteaseLyrics() }
                }
                if !systemApps.onlineLyricsEnabled {
                    Button("开启 LRCLIB · 未命中自动回退 VV") { systemApps.enableOnlineLyrics() }
                }
                if systemApps.extraLyricsEnabled || systemApps.onlineLyricsEnabled || systemApps.neteaseLyricsEnabled || systemApps.independentLyricsEnabled {
                    Button("重新查询歌词") { systemApps.retryLyrics() }
                    Button("关闭联网查询") { systemApps.disableOnlineLyrics() }
                }
                Divider()
                if systemApps.lyricCandidates.contains(where: { $0.requiresConfirmation }) {
                    Text("确认只用于本曲，不修改全局歌手别名")
                }
                ForEach(systemApps.lyricCandidates) { candidate in
                    Button((systemApps.selectedLyricID == candidate.id ? "✓ " : candidate.requiresConfirmation ? "确认匹配 · " : "") + candidate.label +
                           (candidate.response.timed.isEmpty ? " · 全文" : " · 同步")) {
                        systemApps.selectLyric(candidate.id)
                    }
                }
                Divider()
                if systemApps.artistLookupEnabled {
                    Button("关闭艺名联网识别") { systemApps.setArtistLookup(false) }
                } else {
                    Button("开启艺名识别 · 仅歌手名发送至 MusicBrainz") { systemApps.setArtistLookup(true) }
                }
                Button("搜索与校正歌词…") { systemApps.showLyricSearch() }
                Button("导入本地 LRC / TXT…") { systemApps.importLyrics() }
                if !systemApps.lyricSearchSummary.isEmpty {
                    Text(systemApps.lyricSearchSummary)
                }
            } label: {
                Text(systemApps.lyricCandidates.isEmpty ? "歌词来源" : "\(systemApps.lyricSourceLabel) · \(systemApps.lyricCandidates.count) 个版本")
                    .font(.system(size: 9))
            }.menuStyle(.borderlessButton).fixedSize()
            Button { systemApps.showLyricSearch() } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 11))
            }.buttonStyle(.plain).help("搜索与校正歌词")
            Spacer(minLength: 0)
            if !systemApps.timedLyrics.isEmpty {
                Menu {
                    Text("正值提前，负值延后；按歌曲保存")
                    Button("提前 0.5 秒") { systemApps.adjustLyricOffset(0.5) }
                    Button("延后 0.5 秒") { systemApps.adjustLyricOffset(-0.5) }
                    Button("恢复原始时间") { systemApps.adjustLyricOffset(-systemApps.lyricOffset) }
                } label: {
                    Text(String(format: "同步 %+.1fs", systemApps.lyricOffset)).font(.system(size: 9))
                }.menuStyle(.borderlessButton).fixedSize()
            }
        }.foregroundStyle(.secondary)
    }

    @ViewBuilder private func musicArtwork(size: CGFloat) -> some View {
        if let artwork = systemApps.musicArtwork {
            Image(nsImage: artwork).resizable().scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size / 6))
        } else {
            RoundedRectangle(cornerRadius: size / 6).fill(.primary.opacity(0.1))
                .frame(width: size, height: size)
                .overlay(Image(systemName: "music.note")
                    .font(.system(size: size / 3)).foregroundStyle(.secondary))
        }
    }

    private func iconButton(_ symbol: String, label: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 28)
        }
        .buttonStyle(CapsuleButtonStyle())
        .help(label ?? CapsuleTheme.controlLabel(symbol))
        .accessibilityLabel(label ?? CapsuleTheme.controlLabel(symbol))
    }

    private func saveReminder() {
        if store.addReminder(store.newReminder,
                             dueDate: store.newReminderHasDue ? store.newReminderDueDate : nil,
                             alert: store.newReminderHasDue && store.newReminderAlarm) {
            store.newReminder = ""
            store.newReminderHasDue = false
            store.addingReminder = false
        }
    }
}

private struct NeutralLevelSlider: View {
    let title: String
    let symbol: String
    @Binding var value: Double
    let enabled: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).frame(width: 14)
            Text(title).frame(width: 26, alignment: .leading)
            Slider(value: $value, in: 0...1).controlSize(.small)
                .accessibilityLabel("\(title)音量")
            Text("\(Int((value * 100).rounded()))")
                .monospacedDigit().frame(width: 25, alignment: .trailing)
        }
        .font(.system(size: 10))
        .foregroundStyle(.primary)
        .opacity(enabled ? 1 : 0.35)
        .disabled(!enabled)
        .frame(height: 26)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)音量")
        .accessibilityValue("\(Int((value * 100).rounded()))%")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(1, value + 0.05)
            case .decrement: value = max(0, value - 0.05)
            @unknown default: break
            }
        }
    }
}

private struct GlassOrb: View {
    let moduleID: String
    var body: some View {
        ZStack {
            if #available(macOS 26.0, *) {
                Circle().fill(.clear).glassEffect(.regular, in: .circle)
            } else {
                Circle().fill(.ultraThinMaterial)
            }
        }
        .overlay(Circle().strokeBorder(.white.opacity(0.38), lineWidth: 0.8))
        .overlay(Image(systemName: CapsuleTheme.symbol(moduleID))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(CapsuleTheme.accent(moduleID)))
        .clipShape(Circle())
    }
}

private final class PassiveHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class InteractiveHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        guard bounds.contains(localPoint) else { return nil }
        return super.hitTest(point) ?? self
    }
}

private final class NotchPanel: NSPanel {
    var escapeAction: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { escapeAction?() }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class TriggerView: NSView {
    var enter: (() -> Void)?
    var showsNotchHandle = false { didSet { needsDisplay = true } }
    var showsSideHandle = false { didSet { needsDisplay = true } }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { enter?() }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill(); dirtyRect.fill()
        if showsSideHandle || showsNotchHandle {
            NSColor.labelColor.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: showsNotchHandle ? 1 : 5), xRadius: 2, yRadius: 2).fill()
        }
    }
}

final class BallView: NSView {
    let config: SceneConfig
    let store: ModuleStore
    let systemApps: SystemAppsStore
    let pomodoro: PomodoroModel
    let interaction = CapsuleInteraction()
    var lockedCapsule: Bool {
        guard let selected else { return false }
        let id = config.modules[selected].id
        return interaction.isPinned(id)
    }
    var notchBandHeight: CGFloat = 0 { didSet { updateLayout(); needsDisplay = true } }
    var dockAlignment = 0 { didSet { updateLayout(); needsDisplay = true } }
    var reveal: CGFloat = 0 { didSet { updateLayout() } }
    var hovered: Int? { didSet { updateLayout(); needsDisplay = true } }
    var selected: Int? { didSet { if selected != oldValue { animateSelection() } } }
    private var morphingIndex: Int?
    private var pillProgress: CGFloat = 0
    private let pillAnimator = CapsuleAnimator()
    private var selectionOrigin: CGRect?
    private var detailExtra: CGFloat = 0
    private let detailAnimator = CapsuleAnimator()
    private var pillHost: InteractiveHostingView<GlassPill>?
    private var hintsHost: PassiveHostingView<LongBreakHints>?
    private var hintsVisible = false
    private var ballHosts: [PassiveHostingView<GlassOrb>] = []
    var pointerChanged: (() -> Void)?
    var didLeave: (() -> Void)?
    var didEnter: (() -> Void)?
    var heightChanged: ((CGFloat) -> Void)?

    init(frame: NSRect, config: SceneConfig, store: ModuleStore,
         systemApps: SystemAppsStore,
         pomodoro: PomodoroModel) {
        self.config = config
        self.store = store
        self.systemApps = systemApps
        self.pomodoro = pomodoro
        super.init(frame: frame)
        wantsLayer = true
        store.reminderExpansionChanged = { [weak self] expanded in
            self?.animateDetail(expanded, extra: 320)
        }
        systemApps.expansionChanged = { [weak self] module, expanded in
            self?.animateDetail(expanded, extra: module == "notes" ? 280 : 148)
        }
        pomodoro.expansionChanged = { [weak self] expanded in
            self?.animateDetail(expanded, extra: 424)
        }
        for module in config.modules {
            let host = PassiveHostingView(rootView: GlassOrb(moduleID: module.id))
            host.isHidden = true
            ballHosts.append(host)
            addSubview(host)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    private var columns: Int { min(config.maxColumns, max(1, config.modules.count)) }
    private var rows: Int { (config.modules.count + columns - 1) / columns }
    private var rowStep: CGFloat { config.ballDiameter + 18 }
    var maximumHeight: CGFloat { max(80, 50 + CGFloat(rows) * rowStep) + 424 + 64 }
    var desiredHeight: CGFloat {
        max(80, 50 + CGFloat(rows) * rowStep) + detailExtra + (hintsVisible ? 64 : 0)
    }

    func refreshLongBreakHints() {
        let timerSelected = selected.map { config.modules[$0].id == "pomodoro" || config.modules[$0].id == "timer" } ?? false
        let visible = timerSelected && reveal > 0.01 && pomodoro.phase == .longBreak
            && (pomodoro.longBreakPromptElapsed.map { $0 < 10.6 } ?? false)
        if visible != hintsVisible {
            hintsVisible = visible
            heightChanged?(desiredHeight)
            updateLayout()
        }
    }

    private func updateHintLayout() {
        guard hintsVisible, let pillHost else { hintsHost?.isHidden = true; return }
        let distance = pillHost.frame.height / 2 + 12 + 24
        let root = LongBreakHints(pomodoro: pomodoro, travelDistance: distance)
        if hintsHost == nil {
            let host = PassiveHostingView(rootView: root)
            hintsHost = host
            addSubview(host, positioned: .below, relativeTo: pillHost)
        }
        guard let hintsHost else { return }
        hintsHost.rootView = root
        hintsHost.frame = CGRect(x: pillHost.frame.minX, y: pillHost.frame.maxY + 12,
                                width: pillHost.frame.width, height: 58)
        hintsHost.alphaValue = pillProgress * reveal
        hintsHost.isHidden = false
    }

    private func center(for index: Int) -> CGPoint {
        let row = index / columns
        let start = row * columns
        let count = min(columns, config.modules.count - start)
        let column = index - start
        let step = config.ballDiameter + config.spacing
        let rowWidth = CGFloat(count - 1) * step + config.ballDiameter
        let middle = dockAlignment < 0 ? 16 + rowWidth / 2
            : dockAlignment > 0 ? bounds.width - 16 - rowWidth / 2 : bounds.midX
        let x = middle + (CGFloat(column) - CGFloat(count - 1) / 2) * step
        return CGPoint(x: x, y: (notchBandHeight > 0 ? notchBandHeight / 2 : 20) + CGFloat(row) * rowStep)
    }

    private func ball(at index: Int) -> CGRect {
        let c = center(for: index)
        let d = config.ballDiameter
        return CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
    }

    private func expandedLayout(for selectedIndex: Int) -> (pill: CGRect, satellites: [Int: CGRect]) {
        let row = selectedIndex / columns
        let start = row * columns
        let end = min(start + columns, config.modules.count)
        let leftCount = selectedIndex - start
        let rightCount = end - selectedIndex - 1
        let satelliteStep: CGFloat = 22
        let satelliteSize: CGFloat = 18
        let gap: CGFloat = 12
        let desiredPillWidth: CGFloat = config.modules[selectedIndex].id == "music"
            ? 464 + min(1, detailExtra / 148) * 64
            : (config.modules[selectedIndex].id == "pomodoro" || config.modules[selectedIndex].id == "timer" ? 354 : 310)
        let leftGap = leftCount > 0 ? gap : 0
        let rightGap = rightCount > 0 ? gap : 0
        let availablePillWidth = bounds.width - CGFloat(leftCount + rightCount) * satelliteStep - leftGap - rightGap - 32
        let pillWidth = min(desiredPillWidth, max(180, availablePillWidth))
        let total = CGFloat(leftCount + rightCount) * satelliteStep
            + leftGap + pillWidth + rightGap
        let leading = dockAlignment < 0 ? 16 : dockAlignment > 0 ? bounds.width - 16 - total : bounds.midX - total / 2
        let y = center(for: selectedIndex).y
        let pillHeight = notchBandHeight > 0 ? min(36, max(24, notchBandHeight - 4)) : 36
        let pill = CGRect(x: leading + CGFloat(leftCount) * satelliteStep + leftGap,
                          y: y - pillHeight / 2, width: pillWidth, height: pillHeight)
        var satellites: [Int: CGRect] = [:]
        for index in start..<end where index != selectedIndex {
            let x: CGFloat
            if index < selectedIndex {
                x = leading + (CGFloat(index - start) + 0.5) * satelliteStep
            } else {
                x = pill.maxX + rightGap
                    + (CGFloat(index - selectedIndex - 1) + 0.5) * satelliteStep
            }
            satellites[index] = CGRect(x: x - satelliteSize / 2, y: y - satelliteSize / 2,
                                       width: satelliteSize, height: satelliteSize)
        }
        return (pill, satellites)
    }

    private func mix(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t,
               y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t,
               height: a.height + (b.height - a.height) * t)
    }

    private func visualBallRect(for index: Int) -> CGRect {
        let source = ball(at: index)
        guard let selectedIndex = morphingIndex else { return source }
        let destination = expandedLayout(for: selectedIndex).satellites[index] ?? source
        return mix(source, destination, pillProgress)
    }

    private func updateLayout() {
        let t = min(1, max(0, reveal))
        let eased = t
        for index in ballHosts.indices {
            let target = visualBallRect(for: index)
            let diameter = 3 + (target.width - 3) * eased
            let y = -5 + (target.midY + 5) * eased
            let hoveredScale: CGFloat = hovered == index && pillProgress < 0.1 ? 1.13 : 1
            let size = diameter * hoveredScale
            let host = ballHosts[index]
            host.frame = CGRect(x: target.midX - size / 2, y: y - size / 2,
                                width: size, height: size)
            host.alphaValue = index == morphingIndex
                ? 1 - pillProgress : 1 - 0.37 * pillProgress
            host.isHidden = t <= 0.01 || host.alphaValue < 0.01
        }
        if let index = morphingIndex, let pillHost {
            let source = selectionOrigin ?? ball(at: index)
            var destination = expandedLayout(for: index).pill
            destination.size.height += detailExtra
            pillHost.frame = mix(source, destination, pillProgress)
            pillHost.alphaValue = min(1, max(0, (pillProgress - 0.25) / 0.75))
            pillHost.isHidden = pillProgress < 0.01
        }
        updateHintLayout()
    }

    private func animateSelection() {
        let previousExtra = detailExtra
        selectionOrigin = selected != nil && morphingIndex != nil ? pillHost?.frame : nil
        detailAnimator.cancel()
        detailExtra = 0
        store.setReminderExpanded(false)
        systemApps.setExpanded("notes", false)
        systemApps.setExpanded("music", false)
        systemApps.setMusicVisible(selected.map { config.modules[$0].id == "music" } ?? false)
        pomodoro.setExpanded(false)
        detailAnimator.cancel()
        detailExtra = selected == nil ? previousExtra : 0
        heightChanged?(desiredHeight)
        if let selected {
            if selectionOrigin != nil { pillProgress = 0 }
            morphingIndex = selected
            pillHost?.removeFromSuperview()
            let module = config.modules[selected]
            if module.id == "reminders" { store.openReminders() }
            if module.id == "notes" { systemApps.openNotes() }
            if module.id == "music" { systemApps.openMusic() }
            let host = InteractiveHostingView(rootView: GlassPill(
                module: module, store: store, systemApps: systemApps, pomodoro: pomodoro,
                interaction: interaction, onClose: { [weak self] in
                    guard let self else { return }
                    self.interaction.setPinned(module.id, false)
                    if module.id == "music" { self.systemApps.setMusicPinned(false) }
                    self.selected = nil
                }))
            pillHost = host
            addSubview(host)
            if let hintsHost { addSubview(hintsHost, positioned: .below, relativeTo: host) }
            window?.makeKey()
            updateLayout()
        }
        let start = pillProgress
        let end: CGFloat = selected == nil ? 0 : 1
        pillAnimator.animate(duration: selectionOrigin == nil ? 0.28 : 0.22) { [weak self] t in
            guard let self else { return }
            self.pillProgress = start + (end - start) * t
            self.updateLayout()
        } completion: { [weak self] in
            guard let self else { return }
            self.selectionOrigin = nil
            if self.selected == nil {
                self.pillHost?.removeFromSuperview()
                self.pillHost = nil
                self.morphingIndex = nil
                self.detailExtra = 0
                self.heightChanged?(self.desiredHeight)
            }
            self.updateLayout()
        }
    }

    private func animateDetail(_ expanded: Bool, extra: CGFloat) {
        let start = detailExtra
        let end: CGFloat = expanded ? extra : 0
        detailAnimator.animate { [weak self] t in
            guard let self else { return }
            self.detailExtra = start + (end - start) * t
            self.heightChanged?(self.desiredHeight)
            self.updateLayout()
        }
    }

    func containsInteractivePoint(_ point: CGPoint) -> Bool {
        guard reveal > 0.01 else { return false }
        if let host = pillHost, !host.isHidden,
           NSBezierPath(roundedRect: host.frame, xRadius: 18, yRadius: 18).contains(point) { return true }
        return ballHosts.contains { host in
            !host.isHidden && NSBezierPath(ovalIn: host.frame).contains(point)
        }
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { didEnter?(); mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { hovered = nil; didLeave?() }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let next = config.modules.indices.first {
            $0 != morphingIndex && visualBallRect(for: $0).insetBy(dx: -7, dy: -7).contains(point)
        }
        if next != hovered { hovered = next; pointerChanged?() }
        if next != nil || (selected != nil && expandedLayout(for: selected!).pill.contains(point)) {
            NSCursor.pointingHand.set()
        } else { NSCursor.arrow.set() }
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = config.modules.indices.first(where: {
            $0 != morphingIndex && visualBallRect(for: $0).insetBy(dx: -7, dy: -7).contains(point)
        }) {
            selected = index
        }
        pointerChanged?()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill(); dirtyRect.fill()
        if let hovered, hovered != selected, reveal > 0.95 {
            let rect = visualBallRect(for: hovered)
            let title = config.modules[hovered].title
            let width = (title as NSString).size(withAttributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium)
            ]).width
            text(title, size: 11, weight: .medium, color: .labelColor,
                 at: CGPoint(x: rect.midX - width / 2, y: rect.maxY + 10))
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let config = SceneConfig.load()
    private let moduleStore = ModuleStore()
    private let systemApps = SystemAppsStore()
    private let pomodoro = PomodoroModel()
    private var trigger: NSPanel!
    private var overlay: NSPanel!
    private var balls: BallView!
    private var statsWindow: NSWindow?
    private var statusItem: NSStatusItem!
    private var updaterController: SPUStandardUpdaterController?
    private var statsMenuItem: NSMenuItem!
    private var endSessionMenuItem: NSMenuItem!
    private var focusPresetItems: [NSMenuItem] = []
    private var shortPresetItems: [NSMenuItem] = []
    private var longPresetItems: [NSMenuItem] = []
    private var cyclePresetItems: [NSMenuItem] = []
    private var basePresetItems: [NSMenuItem] = []
    private var autoNoiseItem: NSMenuItem!
    private let revealAnimator = CapsuleAnimator()
    private var collapseWork: DispatchWorkItem?
    private var pointerInsideOverlay = false
    private var wasSessionActive = false
    private var lyricInteractionCount = 0
    private var menuObservers: [NSObjectProtocol] = []
    private var placementObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var placementTimer: Timer?
    private var pointerTimer: Timer?
    private var mouseMonitors: [Any] = []
    private var triggerHoverStarted: Date?
    private var triggerActivated = false
    private var pointerDragging = false
    private var controlsArmed = false { didSet { balls?.interaction.controlsArmed = controlsArmed } }
    private var fullscreenAtAnchor = false
    private var dockPosition = DockPosition(rawValue: UserDefaults.standard.integer(forKey: "notch.position.v3")) ?? .automatic
    private var positionItems: [NSMenuItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
           let url = URL(string: feed), url.scheme == "https", url.host != nil,
           let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
           !key.isEmpty {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        }
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 || $0.localizedName.contains("Built-in") })
                  ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let width: CGFloat = 640
        let top = screen.frame.maxY - max(30, screen.safeAreaInsets.top)
        let x = screen.frame.midX - width / 2

        let triggerView = TriggerView(frame: CGRect(x: 0, y: 0, width: 200, height: 12))
        trigger = makePanel(frame: CGRect(x: screen.frame.midX - 100, y: top - 4,
                                          width: 200, height: 12))
        trigger.contentView = triggerView
        trigger.ignoresMouseEvents = true
        trigger.orderFrontRegardless()

        balls = BallView(frame: CGRect(x: 0, y: 0, width: width, height: 200),
                         config: config, store: moduleStore, systemApps: systemApps,
                         pomodoro: pomodoro)
        overlay = makePanel(frame: CGRect(x: x, y: top - balls.desiredHeight,
                                          width: width, height: balls.desiredHeight))
        overlay.contentView = balls
        overlay.ignoresMouseEvents = true
        overlay.becomesKeyOnlyIfNeeded = true
        balls.didLeave = { [weak self] in
            self?.pointerInsideOverlay = false
            self?.scheduleCollapse()
        }
        balls.didEnter = { [weak self] in
            self?.pointerInsideOverlay = true
            self?.collapseWork?.cancel()
        }
        balls.pointerChanged = { [weak self] in self?.collapseWork?.cancel() }
        balls.heightChanged = { [weak self] height in
            guard let self else { return }
            self.updatePlacement(refreshFullscreen: false)
        }

        (overlay as? NotchPanel)?.escapeAction = { [weak self] in
            guard let self else { return }
            self.overlay.makeFirstResponder(nil)
            self.moduleStore.setReminderExpanded(false)
            self.systemApps.setExpanded("notes", false)
            self.systemApps.setExpanded("music", false)
            self.pomodoro.setExpanded(false)
            if self.preferredPinnedIndex() == nil { self.balls.selected = nil }
            self.scheduleCollapse()
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.setAccessibilityLabel("Notch Balls Prototype")
        statusItem.button?.toolTip = "Notch Balls · 提醒、便笺、音乐与专注"
        let menu = NSMenu()
        let positionMenu = NSMenu(title: "位置")
        positionItems = DockPosition.allCases.map { position in
            let item = NSMenuItem(title: position.title, action: #selector(setDockPosition(_:)), keyEquivalent: "")
            item.tag = position.rawValue
            item.target = self
            positionMenu.addItem(item)
            return item
        }
        let positionRoot = NSMenuItem(title: "位置", action: nil, keyEquivalent: "")
        positionRoot.submenu = positionMenu
        menu.addItem(positionRoot)
        menu.addItem(NSMenuItem(title: "显示小球", action: #selector(showFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "打开提醒事项列表", action: #selector(showReminders), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "打开便笺", action: #selector(showNotes), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "打开正在播放", action: #selector(showMusic), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "打开番茄钟", action: #selector(showPomodoro), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "打开专注统计", action: #selector(showStatistics), keyEquivalent: ""))
        statsMenuItem = NSMenuItem(title: "今日专注 0 次 · 0 分钟", action: nil, keyEquivalent: "")
        statsMenuItem.isEnabled = false
        menu.addItem(statsMenuItem)
        endSessionMenuItem = NSMenuItem(title: "结束番茄钟", action: #selector(endPomodoro), keyEquivalent: "")
        menu.addItem(endSessionMenuItem)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "番茄钟默认设置", action: nil, keyEquivalent: "")
        let settingsMenu = NSMenu(title: "番茄钟默认设置")
        focusPresetItems = presetMenu(into: settingsMenu, title: "专注时长",
                                      values: [15, 25, 30, 45, 50],
                                      action: #selector(setFocusPreset(_:)), suffix: "分钟")
        shortPresetItems = presetMenu(into: settingsMenu, title: "短休息",
                                      values: [5, 10],
                                      action: #selector(setShortPreset(_:)), suffix: "分钟")
        longPresetItems = presetMenu(into: settingsMenu, title: "长休息",
                                     values: [15, 20, 30],
                                     action: #selector(setLongPreset(_:)), suffix: "分钟")
        cyclePresetItems = presetMenu(into: settingsMenu, title: "长休息间隔",
                                      values: [3, 4, 6],
                                      action: #selector(setCyclePreset(_:)), suffix: "次专注")
        settingsMenu.addItem(.separator())
        let continuousItem = NSMenuItem(title: "连续循环，直到主动结束", action: nil, keyEquivalent: "")
        continuousItem.isEnabled = false
        settingsMenu.addItem(continuousItem)
        let baseItem = NSMenuItem(title: "默认底噪", action: nil, keyEquivalent: "")
        let baseMenu = NSMenu(title: "默认底噪")
        basePresetItems = AmbientBase.allCases.enumerated().map { index, base in
            let option = NSMenuItem(title: base.title, action: #selector(setBasePreset(_:)),
                                    keyEquivalent: "")
            option.tag = index
            option.target = self
            baseMenu.addItem(option)
            return option
        }
        baseItem.submenu = baseMenu
        settingsMenu.addItem(baseItem)
        autoNoiseItem = NSMenuItem(title: "专注时自动播放环境声",
                                   action: #selector(toggleAutoNoise), keyEquivalent: "")
        autoNoiseItem.target = self
        settingsMenu.addItem(autoNoiseItem)
        settingsItem.submenu = settingsMenu
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let updatesItem = NSMenuItem(
            title: updaterController == nil ? "检查更新（等待更新清单发布）" : "检查更新…",
            action: updaterController == nil ? nil : #selector(checkForUpdates(_:)),
            keyEquivalent: "")
        updatesItem.isEnabled = updaterController != nil
        menu.addItem(updatesItem)
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
        let versionItem = NSMenuItem(title: "版本 \(appVersion)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(NSMenuItem(title: "退出原型", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
        systemApps.lyricInteractionChanged = { [weak self] active in
            self?.setLyricInteraction(active)
        }
        menuObservers = [
            NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                self?.setLyricInteraction(true)
            },
            NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                self?.setLyricInteraction(false)
            }
        ]
        pomodoro.statusChanged = { [weak self] in
            self?.pomodoroStatusChanged()
        }
        updateMenuBar()
        refreshSettingsChecks()
        startPlacementMonitoring()
        systemApps.setMusicPinned(balls.interaction.isPinned("music"))
        if let index = preferredPinnedIndex() {
            balls.selected = index
            showBalls(armControls: false)
        }
    }

    @objc private func setDockPosition(_ item: NSMenuItem) {
        guard let position = DockPosition(rawValue: item.tag) else { return }
        dockPosition = position
        UserDefaults.standard.set(position.rawValue, forKey: "notch.position.v3")
        updatePlacement(refreshFullscreen: true)
    }

    private var anchorScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 || $0.localizedName.contains("Built-in") }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func startPlacementMonitoring() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                if name == NSWorkspace.activeSpaceDidChangeNotification { self?.refreshGlassForSpaceChange() }
                self?.updatePlacement(refreshFullscreen: true)
            })
        }
        placementObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.updatePlacement(refreshFullscreen: true) })
        placementTimer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.updatePlacement(refreshFullscreen: true) }
        pointerTimer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.updatePointerRouting() }
        RunLoop.main.add(placementTimer!, forMode: .common)
        RunLoop.main.add(pointerTimer!, forMode: .common)
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseUp], handler: { [weak self] event in
            if event.type == .leftMouseUp { self?.pointerDragging = false }
            self?.updatePointerRouting()
        }) { mouseMonitors.append(monitor) }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]) { [weak self] event in
            if event.type == .leftMouseDown, event.window === self?.overlay {
                self?.pointerDragging = !(self?.overlay.ignoresMouseEvents ?? true)
            } else if event.type == .leftMouseUp { self?.pointerDragging = false }
            self?.updatePointerRouting()
            return event
        }
        if let local { mouseMonitors.append(local) }
        if let keyboard = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, event.keyCode == 53, event.window === self.overlay,
                  self.lyricInteractionCount == 0 else { return event }
            // Field editors otherwise consume Escape before the panel sees it.
            (self.overlay as? NotchPanel)?.escapeAction?()
            return nil
        }) { mouseMonitors.append(keyboard) }
        updatePlacement(refreshFullscreen: true)
    }

    private func detectFullscreen(on screen: NSScreen) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return fullscreenAtAnchor }
        // File pickers or our menu can activate this app while the other app remains full screen.
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return fullscreenAtAnchor }
        guard let primary = NSScreen.screens.first,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return fullscreenAtAnchor
        }
        return windows.contains { item in
            guard (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier,
                  (item[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = item[kCGWindowBounds as String] as? [String: Any],
                  let quartz = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            let rect = CGRect(x: quartz.minX, y: primary.frame.maxY - quartz.maxY, width: quartz.width, height: quartz.height)
            return DockGeometry.coversFullscreen(rect, screen: screen.frame, safeTop: screen.safeAreaInsets.top)
        }
    }

    private func updatePlacement(refreshFullscreen: Bool) {
        guard let screen = anchorScreen, let overlay, let balls, let trigger else { return }
        if refreshFullscreen {
            let nextFullscreen = detectFullscreen(on: screen)
            if nextFullscreen != fullscreenAtAnchor { refreshGlassForSpaceChange() }
            fullscreenAtAnchor = nextFullscreen
        }
        let geometry = DockGeometry.resolve(screen: screen.frame, safeTop: screen.safeAreaInsets.top,
            height: balls.desiredHeight, position: dockPosition, fullscreen: fullscreenAtAnchor, maximumHeight: balls.maximumHeight,
            notchLeftEdge: screen.auxiliaryTopLeftArea.flatMap { $0.isEmpty ? nil : $0.maxX })
        if overlay.frame != geometry.overlay {
            overlay.setFrame(geometry.overlay, display: true)
            balls.frame = CGRect(origin: .zero, size: geometry.overlay.size)
        }
        if balls.notchBandHeight != geometry.notchBandHeight { balls.notchBandHeight = geometry.notchBandHeight }
        if balls.dockAlignment != geometry.alignment { balls.dockAlignment = geometry.alignment }
        if trigger.frame != geometry.trigger {
            trigger.setFrame(geometry.trigger, display: true)
            triggerHoverStarted = nil
            triggerActivated = false
        }
        (trigger.contentView as? TriggerView)?.showsSideHandle = geometry.alignment != 0 && geometry.notchBandHeight == 0
        (trigger.contentView as? TriggerView)?.showsNotchHandle = geometry.notchBandHeight > 0
        for item in positionItems { item.state = item.tag == dockPosition.rawValue ? .on : .off }
        updatePointerRouting()
    }

    private func refreshGlassForSpaceChange() {
        guard let balls, balls.lockedCapsule else { return }
        balls.interaction.backdropRevision += 1
        // Reattach the native material after the panel joins the new Space.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.balls.interaction.backdropRevision += 1
        }
    }

    private func updatePointerRouting() {
        guard let overlay, let balls, let trigger else { return }
        balls.refreshLongBreakHints()
        let pointer = NSEvent.mouseLocation
        let inTrigger = trigger.frame.contains(pointer)
        if inTrigger {
            if triggerHoverStarted == nil { triggerHoverStarted = Date() }
            if !triggerActivated && Date().timeIntervalSince(triggerHoverStarted!) >= 0.25 {
                triggerActivated = true
                showBalls()
            }
        } else {
            triggerHoverStarted = nil
            triggerActivated = false
        }
        let local = balls.convert(overlay.convertPoint(fromScreen: pointer), from: nil)
        if NSEvent.pressedMouseButtons & 1 == 0 { pointerDragging = false }
        let interactive = overlay.isVisible && (!balls.lockedCapsule || controlsArmed) && (pointerDragging || balls.containsInteractivePoint(local))
        overlay.ignoresMouseEvents = !interactive
        let inside = interactive || inTrigger
        if inside && !pointerInsideOverlay {
            pointerInsideOverlay = true
            collapseWork?.cancel()
        } else if !inside && pointerInsideOverlay {
            pointerInsideOverlay = false
            scheduleCollapse()
        }
    }

    private func presetMenu(into parent: NSMenu, title: String, values: [Int],
                            action: Selector, suffix: String) -> [NSMenuItem] {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        let options = values.map { value -> NSMenuItem in
            let option = NSMenuItem(title: "\(value) \(suffix)", action: action, keyEquivalent: "")
            option.tag = value
            option.target = self
            submenu.addItem(option)
            return option
        }
        item.submenu = submenu
        parent.addItem(item)
        return options
    }

    private func refreshSettingsChecks() {
        for item in focusPresetItems {
            item.state = item.tag == pomodoro.settings.focusMinutes ? .on : .off
        }
        for item in shortPresetItems {
            item.state = item.tag == pomodoro.settings.shortBreakMinutes ? .on : .off
        }
        for item in longPresetItems {
            item.state = item.tag == pomodoro.settings.longBreakMinutes ? .on : .off
        }
        for item in cyclePresetItems {
            item.state = item.tag == pomodoro.settings.longBreakEvery ? .on : .off
        }
        for item in basePresetItems {
            item.state = AmbientBase.allCases[item.tag] == pomodoro.ambientSettings.base
                ? .on : .off
        }
        autoNoiseItem.state = pomodoro.ambientSettings.autoPlay ? .on : .off
    }

    private func updateMenuBar() {
        statusItem.button?.title = pomodoro.isRunning ? "● \(pomodoro.timeText)" : "●"
        statsMenuItem.title = "今日专注 \(pomodoro.today.sessions) 次 · \(pomodoro.today.seconds / 60) 分 \(pomodoro.today.seconds % 60) 秒"
        endSessionMenuItem.isEnabled = pomodoro.isSessionActive
    }

    private func pomodoroStatusChanged() {
        updateMenuBar()
        refreshSettingsChecks()
        let active = pomodoro.isSessionActive
        if active && !wasSessionActive {
            balls.interaction.setPinned("pomodoro", true)
            showBalls()
            if let index = config.modules.firstIndex(where: {
                $0.id == "pomodoro" || $0.id == "timer"
            }), balls.selected != index { balls.selected = index }
        } else if !active && wasSessionActive {
            balls.interaction.setPinned("pomodoro", false)
            if !pointerInsideOverlay { scheduleCollapse() }
        }
        wasSessionActive = active
    }

    private func makePanel(frame: CGRect) -> NSPanel {
        let panel = NotchPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        return panel
    }

    @objc private func showFromMenu() { showBalls() }
    @objc private func showReminders() {
        guard let index = config.modules.firstIndex(where: { $0.id == "reminders" }) else { return }
        showBalls()
        balls.selected = index
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.moduleStore.setReminderExpanded(true)
        }
    }
    @objc private func showNotes() {
        guard let index = config.modules.firstIndex(where: { $0.id == "notes" }) else { return }
        showBalls()
        balls.selected = index
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.systemApps.setExpanded("notes", true)
        }
    }
    @objc private func showMusic() {
        guard let index = config.modules.firstIndex(where: { $0.id == "music" }) else { return }
        showBalls()
        balls.selected = index
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.systemApps.setExpanded("music", true)
        }
    }
    @objc private func showPomodoro() {
        guard let index = config.modules.firstIndex(where: {
            $0.id == "pomodoro" || $0.id == "timer"
        }) else { return }
        showBalls()
        balls.selected = index
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.pomodoro.setExpanded(true)
        }
    }
    @objc private func showStatistics() {
        if statsWindow == nil {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 520),
                                  styleMask: [.titled, .closable],
                                  backing: .buffered, defer: false)
            window.title = "专注统计"
            window.contentView = NSHostingView(rootView: FocusStatsView(pomodoro: pomodoro))
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.center()
            statsWindow = window
        }
        statsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func endPomodoro() { pomodoro.endSession() }
    @objc private func setFocusPreset(_ item: NSMenuItem) {
        pomodoro.setFocusMinutes(item.tag); refreshSettingsChecks()
    }
    @objc private func setShortPreset(_ item: NSMenuItem) {
        pomodoro.setShortBreakMinutes(item.tag); refreshSettingsChecks()
    }
    @objc private func setLongPreset(_ item: NSMenuItem) {
        pomodoro.setLongBreakMinutes(item.tag); refreshSettingsChecks()
    }
    @objc private func setCyclePreset(_ item: NSMenuItem) {
        pomodoro.setLongBreakEvery(item.tag); refreshSettingsChecks()
    }
    @objc private func setBasePreset(_ item: NSMenuItem) {
        guard AmbientBase.allCases.indices.contains(item.tag) else { return }
        pomodoro.setAmbientBase(AmbientBase.allCases[item.tag]); refreshSettingsChecks()
    }
    @objc private func toggleAutoNoise() {
        pomodoro.toggleAutoAmbient(); refreshSettingsChecks()
    }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func checkForUpdates(_ sender: Any?) {
        updaterController?.checkForUpdates(sender)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if pomodoro.isSessionActive { pomodoro.endSession() }
        pomodoro.setAmbient(false)
        placementTimer?.invalidate()
        pointerTimer?.invalidate()
        mouseMonitors.forEach(NSEvent.removeMonitor)
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        placementObservers.forEach(NotificationCenter.default.removeObserver)
    }

    private func showBalls(armControls: Bool = true) {
        if armControls { controlsArmed = true }
        updatePlacement(refreshFullscreen: true)
        collapseWork?.cancel()
        overlay.orderFrontRegardless()
        transition(to: 1)
        if armControls && !pointerInsideOverlay { scheduleCollapse() }
    }

    private func setLyricInteraction(_ active: Bool) {
        lyricInteractionCount = max(0, lyricInteractionCount + (active ? 1 : -1))
        if lyricInteractionCount > 0 { collapseWork?.cancel() }
        else if !pointerInsideOverlay { scheduleCollapse() }
    }

    private func preferredPinnedIndex() -> Int? {
        if let selected = balls.selected, balls.interaction.isPinned(config.modules[selected].id) { return selected }
        if let id = balls.interaction.lastPinnedID,
           let index = config.modules.firstIndex(where: { $0.id == id }), balls.interaction.isPinned(id) { return index }
        return config.modules.indices.first { balls.interaction.isPinned(config.modules[$0].id) }
    }

    private func scheduleCollapse() {
        collapseWork?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.lyricInteractionCount == 0 else { return }
            if self.overlay.isKeyWindow,
               let editor = self.overlay.firstResponder as? NSTextView, editor.isFieldEditor {
                // A pointer leaving the capsule must not dismiss an active text edit.
                self.scheduleCollapse()
                return
            }
            self.controlsArmed = false
            self.overlay.ignoresMouseEvents = true
            if let index = self.preferredPinnedIndex() {
                if self.balls.selected != index { self.balls.selected = index }
                if self.config.modules[index].id == "pomodoro" || self.config.modules[index].id == "timer" {
                    self.pomodoro.setExpanded(false)
                }
                self.showBalls(armControls: false)
                return
            }
            self.balls.selected = nil
            self.transition(to: 0)
        }
        collapseWork = task
        DispatchQueue.main.asyncAfter(deadline: .now() + config.collapseDelay, execute: task)
    }

    private func transition(to value: CGFloat) {
        let start = balls.reveal
        if abs(start - value) < 0.001 {
            revealAnimator.cancel()
            if value == 0 { overlay.orderOut(nil) }
            return
        }
        revealAnimator.animate(duration: config.emergeDuration) { [weak self] t in
            guard let self else { return }
            self.balls.reveal = start + (value - start) * t
            self.updatePointerRouting()
        } completion: { [weak self] in
            if value == 0 { self?.overlay.orderOut(nil) }
        }
    }

}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
