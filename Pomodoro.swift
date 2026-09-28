import AppKit
import AVFoundation
import Combine

struct PomodoroSettings: Codable {
    var focusMinutes = 25
    var shortBreakMinutes = 5
    var longBreakMinutes = 15
    var longBreakEvery = 2
    var autoStartNext = true
    var autoWhiteNoise = false
    var whiteNoiseVolume = 0.30
}

enum AmbientBase: String, Codable, CaseIterable {
    case soft, deep, off

    var title: String {
        switch self {
        case .soft: return "柔和"
        case .deep: return "深沉"
        case .off: return "关闭"
        }
    }
}

enum AmbientLayer: CaseIterable {
    case base, rain, ocean, stream

    var title: String {
        switch self {
        case .base: return "底噪"
        case .rain: return "雨声"
        case .ocean: return "海浪"
        case .stream: return "溪流"
        }
    }

    var symbol: String {
        switch self {
        case .base: return "waveform"
        case .rain: return "cloud.rain"
        case .ocean: return "water.waves"
        case .stream: return "drop"
        }
    }
}

struct AmbientSettings: Codable {
    var base: AmbientBase = .soft
    var baseVolume = 0.18
    var rainVolume = 0.55
    var oceanVolume = 0.32
    var streamVolume = 0.22
    var autoPlay = false

    func volume(for layer: AmbientLayer) -> Double {
        switch layer {
        case .base: return baseVolume
        case .rain: return rainVolume
        case .ocean: return oceanVolume
        case .stream: return streamVolume
        }
    }

    var valid: Bool {
        [baseVolume, rainVolume, oceanVolume, streamVolume].allSatisfy {
            $0.isFinite && (0...1).contains($0)
        }
    }

    var hasAudibleLayer: Bool {
        (base != .off && baseVolume > 0) || rainVolume > 0
            || oceanVolume > 0 || streamVolume > 0
    }
}

struct FocusDay: Codable {
    var sessions = 0
    var seconds = 0
}

struct FocusSession: Codable, Identifiable {
    let id: UUID
    let finishedAt: Date
    let name: String
    let seconds: Int
}

enum PomodoroPhase: String {
    case focus
    case shortBreak
    case longBreak

    var title: String {
        switch self {
        case .focus: return "专注"
        case .shortBreak: return "短休息"
        case .longBreak: return "长休息"
        }
    }
}

private final class AmbientPlayer {
    private let resources: Bundle
    private var players: [String: AVAudioPlayer] = [:]

    init(resources: Bundle) { self.resources = resources }

    func apply(_ settings: AmbientSettings) throws {
        let levels: [String: Double] = [
            "white-noise": settings.base == .soft ? settings.baseVolume : 0,
            "deep-noise": settings.base == .deep ? settings.baseVolume : 0,
            "rain": settings.rainVolume,
            "ocean": settings.oceanVolume,
            "stream": settings.streamVolume
        ]
        do {
            for (name, level) in levels {
                guard level > 0 else { players[name]?.stop(); continue }
                if players[name] == nil {
                    guard let url = resources.url(forResource: name, withExtension: "wav") else {
                        throw NSError(domain: "NotchPomodoro", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "找不到音源：\(name)"])
                    }
                    let player = try AVAudioPlayer(contentsOf: url)
                    player.numberOfLoops = -1
                    player.prepareToPlay()
                    players[name] = player
                }
                guard let player = players[name] else { continue }
                player.volume = Float(level)
                if !player.isPlaying && !player.play() {
                    throw NSError(domain: "NotchPomodoro", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "无法播放音源：\(name)"])
                }
            }
        } catch {
            stop()
            throw error
        }
    }

    func stop() { players.values.forEach { $0.stop() } }
}

final class PomodoroModel: ObservableObject {
    @Published private(set) var settings: PomodoroSettings
    @Published private(set) var phase: PomodoroPhase = .focus
    @Published private(set) var secondsRemaining: Int
    @Published private(set) var phaseDuration: Int
    @Published private(set) var isRunning = false
    @Published private(set) var isSessionActive = false
    @Published private(set) var completedInCycle = 0
    @Published private(set) var ambientOn = false
    @Published private(set) var ambientSettings: AmbientSettings
    @Published private(set) var soundError: String?
    @Published private(set) var expanded = false
    @Published private(set) var longBreakPromptStartedAt: Date?
    @Published private(set) var records: [String: FocusDay] = [:]
    @Published private(set) var sessions: [FocusSession] = []
    @Published private(set) var currentSessionFocusSeconds = 0
    @Published var focusDraft = ""
    @Published private(set) var activeFocusName: String?
    @Published private(set) var nameError = false

    var expansionChanged: ((Bool) -> Void)?
    var statusChanged: (() -> Void)?

    private let defaults: UserDefaults
    private let now: () -> Date
    private let phaseCue: (PomodoroPhase) -> Void
    private let settingsKey = "notch.pomodoro.settings.v1"
    private let recordsKey = "notch.pomodoro.records.v1"
    private let sessionsKey = "notch.pomodoro.sessions.v1"
    private let ambientKey = "notch.pomodoro.ambient.v1"
    private let sound: AmbientPlayer
    private var ticker: Timer?
    private var deadline: Date?
    private var noiseBeforePause = false
    private var manualNoiseOverride: Bool?
    private var hasStartedCurrentPhase = false
    private var accountedFocusSecondsInPhase = 0
    private var countedTopicDays: Set<String> = []

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = { Date() },
         resources: Bundle = .main, phaseCue: @escaping (PomodoroPhase) -> Void = PomodoroModel.playPhaseCue) {
        self.defaults = defaults
        self.now = now
        self.phaseCue = phaseCue
        self.sound = AmbientPlayer(resources: resources)
        var initialSettings: PomodoroSettings
        if let data = defaults.data(forKey: settingsKey),
           let saved = try? JSONDecoder().decode(PomodoroSettings.self, from: data),
           (1...120).contains(saved.focusMinutes),
           (1...60).contains(saved.shortBreakMinutes),
           (1...90).contains(saved.longBreakMinutes),
           (2...8).contains(saved.longBreakEvery),
           (0...1).contains(saved.whiteNoiseVolume) {
            initialSettings = saved
        } else { initialSettings = PomodoroSettings() }
        // Upgrade the previous one-round behavior while preserving duration/audio choices.
        if !defaults.bool(forKey: "notch.pomodoro.continuous.v1") {
            initialSettings.longBreakEvery = 2
            defaults.set(true, forKey: "notch.pomodoro.continuous.v1")
        }
        initialSettings.autoStartNext = true
        if let data = try? JSONEncoder().encode(initialSettings) { defaults.set(data, forKey: settingsKey) }
        settings = initialSettings
        if let data = defaults.data(forKey: ambientKey),
           let saved = try? JSONDecoder().decode(AmbientSettings.self, from: data),
           saved.valid {
            ambientSettings = saved
        } else {
            var migrated = AmbientSettings()
            if defaults.data(forKey: settingsKey) != nil {
                migrated.autoPlay = initialSettings.autoWhiteNoise
                migrated.baseVolume = initialSettings.whiteNoiseVolume
            }
            ambientSettings = migrated
        }
        secondsRemaining = initialSettings.focusMinutes * 60
        phaseDuration = initialSettings.focusMinutes * 60
        if let data = defaults.data(forKey: recordsKey),
           let saved = try? JSONDecoder().decode([String: FocusDay].self, from: data) {
            records = saved
        }
        if let data = defaults.data(forKey: sessionsKey),
           let saved = try? JSONDecoder().decode([FocusSession].self, from: data) {
            sessions = saved
        }
    }

    var longBreakPromptElapsed: TimeInterval? {
        longBreakPromptStartedAt.map { max(0, now().timeIntervalSince($0)) }
    }

    var timeText: String {
        String(format: "%02d:%02d", secondsRemaining / 60, secondsRemaining % 60)
    }

    private func configuredDuration(for phase: PomodoroPhase) -> Int {
        switch phase {
        case .focus: return settings.focusMinutes * 60
        case .shortBreak: return settings.shortBreakMinutes * 60
        case .longBreak: return settings.longBreakMinutes * 60
        }
    }

    var progress: Double {
        guard phaseDuration > 0 else { return 0 }
        return 1 - Double(secondsRemaining) / Double(phaseDuration)
    }

    var today: FocusDay { records[Self.dayKey(for: now())] ?? FocusDay() }

    func focusDay(on date: Date) -> FocusDay {
        records[Self.dayKey(for: date)] ?? FocusDay()
    }

    var totalFocus: FocusDay {
        let seconds = records.values.reduce(0) { $0 + $1.seconds }
        return FocusDay(sessions: sessions.count + (isSessionActive ? 1 : 0), seconds: seconds)
    }

    var lastSevenDays: [(label: String, sessions: Int)] {
        (0..<7).reversed().compactMap { offset in
            guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: now()) else {
                return nil
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "E"
            let label = formatter.string(from: date)
            return (label, records[Self.dayKey(for: date)]?.sessions ?? 0)
        }
    }

    func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        expanded = value
        expansionChanged?(value)
    }

    func toggleRunning() {
        if isRunning { pause() }
        else { start() }
    }

    func start() {
        guard !isRunning else { return }
        if phase == .focus && !hasStartedCurrentPhase && activeFocusName == nil {
            let name = focusDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                nameError = true
                setExpanded(true)
                return
            }
            activeFocusName = String(name.prefix(80))
            focusDraft = ""
            nameError = false
        }
        if secondsRemaining <= 0 { secondsRemaining = phaseDuration }
        if !isSessionActive {
            currentSessionFocusSeconds = 0
            accountedFocusSecondsInPhase = 0
            countedTopicDays = []
            countTopic(on: now())
        }
        deadline = now().addingTimeInterval(TimeInterval(secondsRemaining))
        isRunning = true
        isSessionActive = true
        hasStartedCurrentPhase = true
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.updateClock()
        }
        if let ticker { RunLoop.main.add(ticker, forMode: .common) }
        if noiseBeforePause || manualNoiseOverride == true
            || (phase == .focus && ambientSettings.autoPlay && manualNoiseOverride != false) {
            setAmbient(true)
        }
        noiseBeforePause = false
        statusChanged?()
    }

    func pause() {
        guard isRunning else { return }
        updateClock()
        guard isRunning else { return }
        ticker?.invalidate()
        ticker = nil
        deadline = nil
        isRunning = false
        noiseBeforePause = ambientOn
        setAmbient(false)
        statusChanged?()
    }

    func resetCurrent() {
        captureCurrentFocusTime()
        stopTimer()
        accountedFocusSecondsInPhase = 0
        phaseDuration = configuredDuration(for: phase)
        secondsRemaining = phaseDuration
        hasStartedCurrentPhase = false
        manualNoiseOverride = nil
        statusChanged?()
    }

    func endSession() {
        captureCurrentFocusTime()
        if isSessionActive, let name = activeFocusName {
            sessions.append(FocusSession(id: UUID(), finishedAt: now(),
                                         name: name, seconds: currentSessionFocusSeconds))
            saveSessions()
        }
        stopTimer()
        isSessionActive = false
        currentSessionFocusSeconds = 0
        accountedFocusSecondsInPhase = 0
        countedTopicDays = []
        longBreakPromptStartedAt = nil
        phase = .focus
        phaseDuration = configuredDuration(for: .focus)
        secondsRemaining = phaseDuration
        completedInCycle = 0
        hasStartedCurrentPhase = false
        activeFocusName = nil
        focusDraft = ""
        nameError = false
        manualNoiseOverride = nil
        setExpanded(false)
        statusChanged?()
    }

    func skipPhase() {
        guard isSessionActive else { return }
        let resume = isRunning
        captureCurrentFocusTime()
        stopTimer()
        advance(completed: false)
        if resume { start() }
        statusChanged?()
    }

    func updateClock() {
        guard let deadline else { return }
        secondsRemaining = max(0, Int(ceil(deadline.timeIntervalSince(now()))))
        accountCurrentFocusTime()
        statusChanged?()
        if secondsRemaining == 0 {
            stopTimer()
            advance(completed: true)
            if isSessionActive { start() }
            statusChanged?()
        }
    }

    private func stopTimer() {
        ticker?.invalidate()
        ticker = nil
        deadline = nil
        isRunning = false
        noiseBeforePause = false
        setAmbient(false)
    }

    private func captureCurrentFocusTime() {
        guard let deadline else { return }
        secondsRemaining = max(0, Int(ceil(deadline.timeIntervalSince(now()))))
        accountCurrentFocusTime()
    }

    private func countTopic(on date: Date) {
        let key = Self.dayKey(for: date)
        guard countedTopicDays.insert(key).inserted else { return }
        var day = records[key] ?? FocusDay()
        day.sessions += 1
        records[key] = day
        saveRecords()
    }

    private func accountCurrentFocusTime() {
        guard isSessionActive && phase == .focus && hasStartedCurrentPhase else { return }
        let elapsed = min(phaseDuration, max(0, phaseDuration - secondsRemaining))
        let increment = elapsed - accountedFocusSecondsInPhase
        guard increment > 0 else { return }
        accountedFocusSecondsInPhase = elapsed
        currentSessionFocusSeconds += increment
        let finished = min(now(), deadline ?? now())
        var cursor = finished.addingTimeInterval(TimeInterval(-increment))
        var remaining = increment
        while remaining > 0 {
            countTopic(on: cursor)
            let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: cursor)) ?? finished
            let chunk = min(remaining, max(1, Int(ceil(nextDay.timeIntervalSince(cursor)))))
            let key = Self.dayKey(for: cursor)
            var day = records[key] ?? FocusDay()
            day.seconds += chunk
            records[key] = day
            remaining -= chunk
            cursor = cursor.addingTimeInterval(TimeInterval(chunk))
        }
        saveRecords()
    }

    private func advance(completed: Bool) {
        if phase == .focus {
            if completed { completedInCycle += 1 }
            phase = completed && completedInCycle % settings.longBreakEvery == 0
                ? .longBreak : .shortBreak
        } else { phase = .focus }
        longBreakPromptStartedAt = phase == .longBreak ? now() : nil
        phaseDuration = configuredDuration(for: phase)
        secondsRemaining = phaseDuration
        accountedFocusSecondsInPhase = 0
        hasStartedCurrentPhase = false
        manualNoiseOverride = nil
        phaseCue(phase)
    }

    static func playPhaseCue(_ phase: PomodoroPhase) {
        let name = phase == .focus ? "Ping" : "Glass"
        if let cue = NSSound(named: NSSound.Name(name)) {
            cue.volume = 0.55
            cue.play()
        } else { NSSound.beep() }
    }

    func setAmbient(_ enabled: Bool) {
        if enabled {
            guard ambientSettings.hasAudibleLayer else {
                sound.stop()
                ambientOn = false
                soundError = "请调高至少一个声道的音量"
                return
            }
            do {
                try sound.apply(ambientSettings)
                ambientOn = true
                soundError = nil
            } catch {
                ambientOn = false
                soundError = error.localizedDescription
            }
        } else {
            sound.stop()
            ambientOn = false
        }
    }

    func toggleAmbient() {
        let enabled = !ambientOn
        manualNoiseOverride = enabled
        noiseBeforePause = enabled
        setAmbient(enabled)
    }

    func setAmbientBase(_ base: AmbientBase) {
        ambientSettings.base = base
        updateAmbientSettings()
    }

    func setAmbientVolume(_ layer: AmbientLayer, _ value: Double) {
        let clamped = min(1, max(0, value))
        switch layer {
        case .base: ambientSettings.baseVolume = clamped
        case .rain: ambientSettings.rainVolume = clamped
        case .ocean: ambientSettings.oceanVolume = clamped
        case .stream: ambientSettings.streamVolume = clamped
        }
        updateAmbientSettings()
    }

    private func updateAmbientSettings() {
        if ambientOn { setAmbient(true) }
        if let data = try? JSONEncoder().encode(ambientSettings) {
            defaults.set(data, forKey: ambientKey)
        }
        statusChanged?()
    }

    func setFocusMinutes(_ value: Int) {
        guard (1...120).contains(value) else { return }
        settings.focusMinutes = value
        if phase == .focus && !hasStartedCurrentPhase {
            phaseDuration = configuredDuration(for: phase)
            secondsRemaining = phaseDuration
        }
        saveSettings()
    }
    func setShortBreakMinutes(_ value: Int) {
        guard (1...60).contains(value) else { return }
        settings.shortBreakMinutes = value
        if phase == .shortBreak && !hasStartedCurrentPhase {
            phaseDuration = configuredDuration(for: phase)
            secondsRemaining = phaseDuration
        }
        saveSettings()
    }
    func setLongBreakMinutes(_ value: Int) {
        guard (1...90).contains(value) else { return }
        settings.longBreakMinutes = value
        if phase == .longBreak && !hasStartedCurrentPhase {
            phaseDuration = configuredDuration(for: phase)
            secondsRemaining = phaseDuration
        }
        saveSettings()
    }
    func setLongBreakEvery(_ value: Int) {
        guard (2...8).contains(value) else { return }
        settings.longBreakEvery = value
        saveSettings()
    }
    func toggleAutoAmbient() {
        ambientSettings.autoPlay.toggle()
        updateAmbientSettings()
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: settingsKey)
        }
        statusChanged?()
    }
    private func saveRecords() {
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: recordsKey)
        }
    }
    private func saveSessions() {
        if let data = try? JSONEncoder().encode(sessions) {
            defaults.set(data, forKey: sessionsKey)
        }
    }
    private static func dayKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
