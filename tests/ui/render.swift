// Compiled only by scripts/preview-ui.py, together with production views.
// All content below is synthetic. No reminders, notes or player queries are run.
setbuf(stdout, nil)
let previewApp = NSApplication.shared
previewApp.setActivationPolicy(.prohibited)
let previewSuite = "notch-preview-\(UUID().uuidString)"
let scratchDefaults = UserDefaults(suiteName: previewSuite)!
let previewStore = ModuleStore()
let previewSystem = SystemAppsStore()
let previewPomodoro = PomodoroModel(defaults: scratchDefaults, phaseCue: { _ in })
let previewTimeline = TimelineStore(defaults: scratchDefaults, startTimer: false, calendarAuthorization: { .denied })
let previewInteraction = CapsuleInteraction(defaults: scratchDefaults)
previewInteraction.controlsArmed = true
extension ModuleStore { func loadPreview() {
self.reminderAccess = true
self.reminderCount = 3
self.reminderRows = [
    .init(id: "sample1", title: "整理项目灵感与本周的三个小目标", notes: "先做最重要的一件事。", dueText: "今天 18:00"),
    .init(id: "sample2", title: "读完正在看的那一章", notes: nil, dueText: nil),
    .init(id: "sample3", title: "给书桌留一点空白", notes: nil, dueText: nil)
]
self.focusedReminderID = "sample1"
}}
extension SystemAppsStore { func loadPreview() {
self.musicPinned = false
self.notes = [.init(id: "1", title: "今天的灵感"), .init(id: "2", title: "一个更轻盈的工作空间"), .init(id: "3", title: "周末阅读清单")]
self.musicTitle = "A Quiet Morning"
self.musicArtist = "Studio Sessions"
self.musicSource = "Music"
self.musicElapsed = 82
self.musicDuration = 240
self.musicAvailable = true
self.plainLyrics = "把时间留给眼前的小事\n让每一刻慢慢发生"
}}
extension PomodoroModel { func loadActivePreview() {
    activeFocusName = "完成一个小而美的作品"
    isSessionActive = true
    isRunning = true
    secondsRemaining = 18 * 60 + 42
}}
previewStore.loadPreview()
previewSystem.loadPreview()

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
func render<V: View>(_ view: V, name: String, size: CGSize, dark: Bool = false,
                     settle: TimeInterval = 0.25, motionFrames: Int = 0) {
    let root = view.environment(\.colorScheme, dark ? .dark : .light)
        .frame(width: size.width, height: size.height)
        .padding(24)
        .background(dark ? Color(red: 0.08, green: 0.10, blue: 0.14) : Color(red: 0.94, green: 0.95, blue: 0.97))
    let host = NSHostingView(rootView: root)
    let rect = CGRect(x: 0, y: 0, width: size.width + 48, height: size.height + 48)
    let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = host
    host.frame = rect
    window.orderFront(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(settle))
    host.layoutSubtreeIfNeeded()
    host.display()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("Bitmap unavailable") }
    host.cacheDisplay(in: host.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
    if motionFrames > 0 {
        let frames = output.appendingPathComponent(name + "-motion", isDirectory: true)
        try! FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        for index in 0..<motionFrames {
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            host.layoutSubtreeIfNeeded()
            host.display()
            let frame = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: frame)
            try! frame.representation(using: .png, properties: [:])!
                .write(to: frames.appendingPathComponent(String(format: "%02d.png", index)))
        }
    }
    window.orderOut(nil)
    print("Rendered \(name) \(Int(size.width)) × \(Int(size.height))")
}
func pill(_ id: String) -> some View {
    GlassPill(module: SceneConfig.fallback.modules.first { $0.id == id }!, store: previewStore,
              systemApps: previewSystem, pomodoro: previewPomodoro, timeline: previewTimeline,
              interaction: previewInteraction, onClose: {})
}
let previewCalendar = Calendar.current
let previewNow = Date()
let previewDay = previewCalendar.startOfDay(for: previewNow)
func sample(_ id: String, _ title: String, day: Int, hour: Int, duration: Int, calendar: String) -> TimelineEvent {
    let start = previewCalendar.date(byAdding: .hour, value: hour,
        to: previewCalendar.date(byAdding: .day, value: day, to: previewDay)!)!
    return TimelineEvent(id: id, title: title, start: start,
        end: previewCalendar.date(byAdding: .minute, value: duration, to: start)!,
        isAllDay: false, calendarID: calendar, calendarTitle: calendar,
        externalID: nil, url: nil)
}
func orbPalette() -> some View {
    HStack(spacing: 24) {
        ForEach(SceneConfig.fallback.modules, id: \.id) { module in
            VStack(spacing: 8) {
                GlassOrb(moduleID: module.id).frame(width: 26, height: 26)
                Text(module.title).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
}
render(orbPalette(), name: "orbs-unified-light", size: CGSize(width: 400, height: 82))
render(orbPalette(), name: "orbs-unified-dark", size: CGSize(width: 400, height: 82), dark: true)
previewTimeline.open(pinned: false)
previewTimeline.loadPreview([
    sample("work-1", "项目讨论", day: 0, hour: 9, duration: 90, calendar: "工作"),
    sample("personal-1", "午间散步", day: 0, hour: 12, duration: 40, calendar: "个人"),
    sample("family-1", "家庭晚餐", day: 0, hour: 18, duration: 120, calendar: "家庭"),
    sample("work-2", "交付节点", day: 2, hour: 10, duration: 60, calendar: "工作"),
    sample("trip", "短途旅行", day: 7, hour: 8, duration: 60 * 72, calendar: "个人")
])
render(pill("timeline"), name: "timeline-day", size: CGSize(width: 520, height: 96), dark: true, settle: 1.1)
previewTimeline.setLevel(2)
render(pill("timeline"), name: "timeline-month", size: CGSize(width: 520, height: 156), dark: true, settle: 1.1)
previewTimeline.setLevel(3)
render(pill("timeline"), name: "timeline-year", size: CGSize(width: 520, height: 216),
       dark: true, settle: 1.1, motionFrames: 12)
render(pill("timeline"), name: "timeline-light", size: CGSize(width: 520, height: 216), settle: 1.1)
render(pill("timeline"), name: "timeline-entry", size: CGSize(width: 520, height: 216),
       dark: true, settle: 0.02, motionFrames: 12)
previewTimeline.loadPreview((0..<14).map { index in
    sample("dense-\(index)", "重叠事件 \(index + 1)", day: 0,
           hour: 9 + index / 4, duration: 55, calendar: ["工作", "个人", "家庭"][index % 3])
})
render(pill("timeline"), name: "timeline-dense", size: CGSize(width: 520, height: 216), dark: true, settle: 1.1)
render(TimelineFlowField(scale: .month, fillWidth: 400, time: 0, strength: 0.65),
       name: "timeline-flow-a", size: CGSize(width: 440, height: 49), dark: true)
render(TimelineFlowField(scale: .month, fillWidth: 400, time: 4, strength: 0.65),
       name: "timeline-flow-b", size: CGSize(width: 440, height: 49), dark: true)
let firstFlowFrame = try Data(contentsOf: output.appendingPathComponent("timeline-flow-a.png"))
let secondFlowFrame = try Data(contentsOf: output.appendingPathComponent("timeline-flow-b.png"))
assert(firstFlowFrame != secondFlowFrame)
print("PASS: settled timeline color field changes across ambient frames")
var eastern = Calendar(identifier: .gregorian)
eastern.timeZone = TimeZone(identifier: "America/New_York")!
let spring = eastern.date(from: DateComponents(year: 2024, month: 3, day: 10, hour: 12))!
let autumn = eastern.date(from: DateComponents(year: 2024, month: 11, day: 3, hour: 12))!
let leap = eastern.date(from: DateComponents(year: 2024, month: 2, day: 15))!
assert(TimelineScale.day.interval(at: spring, calendar: eastern).duration == 23 * 3600)
assert(TimelineScale.day.interval(at: autumn, calendar: eastern).duration == 25 * 3600)
assert(TimelineScale.month.interval(at: leap, calendar: eastern).duration == 29 * 86400)
previewTimeline.setLevel(1)
previewTimeline.setLevel(3)
previewTimeline.setLevel(2)
assert(previewTimeline.level == 2)
print("PASS: timeline daylight saving, leap month and rapid level changes")
previewPomodoro.setExpanded(true)
render(pill("pomodoro"), name: "focus-idle-light", size: CGSize(width: 354, height: 460))
previewPomodoro.loadActivePreview()
render(pill("pomodoro"), name: "focus-active-dark", size: CGSize(width: 354, height: 460), dark: true)
previewPomodoro.setExpanded(false)
render(pill("pomodoro"), name: "focus-compact", size: CGSize(width: 354, height: 36), dark: true)
previewStore.setReminderExpanded(true)
render(pill("reminders"), name: "reminders", size: CGSize(width: 310, height: 356))
previewStore.newReminderHasDue = true
render(pill("reminders"), name: "reminders-date", size: CGSize(width: 310, height: 356))
previewSystem.notesExpanded = true
render(pill("notes"), name: "notes", size: CGSize(width: 310, height: 316))
previewSystem.musicExpanded = true
render(pill("music"), name: "music-expanded", size: CGSize(width: 528, height: 184), dark: true)
render(pill("music"), name: "music-expanded-narrow", size: CGSize(width: 220, height: 184), dark: true)
previewSystem.musicExpanded = false
render(pill("music"), name: "music-compact", size: CGSize(width: 464, height: 36), dark: true)
render(pill("music"), name: "music-narrow", size: CGSize(width: 220, height: 36), dark: true)
render(FocusStatsView(pomodoro: previewPomodoro), name: "statistics", size: CGSize(width: 700, height: 520))

// Verify interruption and timing with the same animation implementation as the app.
assert(CapsuleAnimator.progress(-1, duration: 1) == 0)
assert(CapsuleAnimator.progress(2, duration: 1) == 1)
let animator = CapsuleAnimator()
var obsoleteCompletion = false
var completed = false
animator.animate(duration: 0.3, step: { _ in }, completion: { obsoleteCompletion = true })
animator.animate(duration: 0.04, step: { _ in }, completion: { completed = true })
let animationDeadline = Date().addingTimeInterval(2)
while !completed && Date() < animationDeadline {
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
}
if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { assert(!obsoleteCompletion) }
assert(completed)
print("PASS: animation boundary and interruption checks")

var trackingFinished = false
animator.animate(duration: 0.02, step: { _ in }, completion: { trackingFinished = true })
let trackingDeadline = Date().addingTimeInterval(2)
while !trackingFinished && Date() < trackingDeadline {
    RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.02))
}
assert(trackingFinished, "Animation froze during control tracking")
print("PASS: animations continue in event-tracking mode")
scratchDefaults.removePersistentDomain(forName: previewSuite)

// Rapid selection must never reopen a previously requested module after closing.
let testConfig = SceneConfig(ballDiameter: 22, spacing: 12, emergeDuration: 0.32,
    collapseDelay: 0.7, maxColumns: 7, modules: [
        Module(id: "demo-a", title: "A", detail: ""), Module(id: "demo-b", title: "B", detail: "")])
let testBalls = BallView(frame: CGRect(x: 0, y: 0, width: 640, height: 540),
    config: testConfig, store: previewStore, systemApps: previewSystem,
    pomodoro: previewPomodoro, timeline: previewTimeline)
testBalls.reveal = 1
testBalls.selected = 0
testBalls.selected = 1
testBalls.selected = nil
let switchDeadline = Date().addingTimeInterval(1)
while Date() < switchDeadline {
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
}
assert(testBalls.selected == nil)
assert(testBalls.desiredHeight == 90)
print("PASS: rapid module switch then dismissal leaves no stale selection or expanded height")

// Lyric matching regression cases: no external requests or user music metadata.
let baseQuery = LyricQuery(title: "Quiet Morning", artist: "Example Artist", album: "Sample Album", duration: 240)
func match(_ title: String = "Quiet Morning", artist: String = "Example Artist", album: String = "Sample Album", duration: Double? = 240, broad: Bool = false) -> Double? {
    baseQuery.score(title: title, artist: artist, album: album, duration: duration, allowUncertain: broad)
}
assert(match()! >= 100)
assert(match(duration: 242.9)! >= 100)
assert(match(duration: 248)! < 100)
assert(match(duration: 253) == nil)
assert(match(artist: "Other Artist") == nil)
assert(match(artist: "Other Artist", broad: true)! < 100)
assert(match(album: "", duration: nil)! < 100)
assert(match("Quiet Morning (Live)") == nil)
assert(match("Quiet Morning (Remastered)")! >= 100)
assert(match("Quiet Morning (Remix)") == nil)
assert(match("Quiet Morning (Instrumental)") == nil)
assert(!LyricQuery.artistEquivalent("Artist A / Artist B", "Artist A"))
assert(LyricQuery.artistEquivalent("Artist A / Artist B", "Artist B & Artist A"))
assert(!LyricQuery.artistEquivalent("", ""))
assert(LyricQuery.artistEquivalent("Lo Ta-You", "羅大佑"))
assert(LyricQuery.normalize("簡體") == LyricQuery.normalize("简体"))
var translationQuery = LyricQuery(title: "Quiet Morning", artist: "Example Artist", album: "Sample Album", duration: 240)
assert(translationQuery.score(title: "宁静清晨", artist: "Example Artist", album: "Sample Album", duration: 240) == nil)
translationQuery.translatedTitleSearch = true
assert(translationQuery.score(title: "宁静清晨", artist: "Example Artist", album: "Sample Album", duration: 240)! < 100)
assert(translationQuery.score(title: "宁静清晨", artist: "Other Artist", album: "Sample Album", duration: 240) == nil)
assert(translationQuery.score(title: "宁静清晨", artist: "Example Artist", album: "Sample Album", duration: 244) == nil)
assert(translationQuery.score(title: "宁静清晨", artist: "Example Artist", album: "Sample Album", duration: nil) == nil)
assert(match(album: "", duration: .nan)! < 100)
assert(LyricCandidate.timeLabel(.infinity) == "时长未标注")
assert(LyricCandidate.timeLabel(240) == "4:00")
print("PASS: matching, translation, collaboration and invalid-duration cases")

func candidate(_ id: String, title: String = "Quiet Morning", artist: String = "Example Artist", score: Double = 130, duration: Double = 240) -> LyricCandidate {
    LyricCandidate(id: id, source: "合成测试歌词源", title: title, artist: artist, album: "Sample Album", duration: duration,
        response: .init(timed: [.init(time: 0, text: "清晨"), .init(time: 10, text: "这是一句很长很长的合成歌词，用来检查布局不会突然只剩下歌名"), .init(time: 20, text: "慢慢来")], plain: nil), score: score)
}
let low = candidate("manual", score: 70)
let high = candidate("high")
assert(LyricCandidate.choose([high, low], preferred: "manual", current: "high")?.id == "manual")
assert(LyricCandidate.choose([high, low], preferred: nil, current: "manual")?.id == "manual")
assert(LyricCandidate.choose([low], preferred: nil, current: nil) == nil)
assert(LyricCandidate.choose([low, high], preferred: nil, current: nil)?.id == "high")

extension SystemAppsStore {
    func testMusicState() {
        onlineLyricsEnabled = false; extraLyricsEnabled = false; independentLyricsEnabled = false; neteaseLyricsEnabled = false
        musicPinned = false
        func snapshot(_ duration: Double?, artist: String? = "Example Artist", album: String? = "Sample Album", available: Bool = true) -> NowPlayingSnapshot {
            NowPlayingSnapshot(available: available, bundle: nil, title: "Quiet Morning", artist: artist, album: album,
                artworkData: nil, duration: duration, elapsed: 11, playing: true)
        }
        // Preseed artwork identity so these pure-state checks never query a player.
        artworkKey = "Quiet Morning\u{1f}Example Artist\u{1f}Sample Album\u{1f}240"
        acceptMusicSnapshot(snapshot(240))
        let key = lyricsTrackKey!
        addCandidates([candidate("first")], key: key)
        assert(selectedLyricID == "first")
        addCandidates([candidate("later", score: 180)], key: key)
        assert(selectedLyricID == "first", "Late results replaced displayed lyrics")
        addCandidates([candidate("stale", score: 300)], key: "old-track")
        assert(!lyricCandidates.contains { $0.id == "stale" })
        acceptMusicSnapshot(snapshot(240.8))
        assert(lyricsTrackKey == key && selectedLyricID == "first")
        acceptMusicSnapshot(snapshot(nil, artist: nil, album: nil))
        assert(lyricsTrackKey == key && musicArtist == "Example Artist" && musicDuration == 240.8)
        acceptMusicSnapshot(snapshot(nil, available: false))
        acceptMusicSnapshot(snapshot(nil, available: false))
        assert(musicAvailable && selectedLyricID == "first")
        acceptMusicSnapshot(snapshot(241))
        assert(musicAvailable && lyricsTrackKey == key)
        addCandidates([candidate("manual-search", score: 200)], key: key, automatic: false)
        assert(selectedLyricID == "first", "Manual search silently selected a new result")
        artworkKey = "Quiet Morning\u{1f}Different Artist\u{1f}Sample Album\u{1f}241"
        acceptMusicSnapshot(snapshot(241, artist: "Different Artist"))
        assert(lyricsTrackKey != key && selectedLyricID == nil && timedLyrics.isEmpty)
        acceptMusicSnapshot(snapshot(nil, available: false))
        acceptMusicSnapshot(snapshot(nil, available: false))
        acceptMusicSnapshot(snapshot(nil, available: false))
        assert(!musicAvailable && lyricsTrackKey == nil)
    }
    func loadLyricSearchPreview() {
        lyricsTrackKey = "synthetic-preview"
        musicTitle = "Quiet Morning (Remastered)"
        musicArtist = "Example Artist"
        musicAlbum = "Sample Album"
        musicAvailable = true
        musicDuration = 240
        musicElapsed = 1
        lyricCandidates = [candidate("selected"), candidate("translated", title: "宁静清晨", score: 80, duration: 241.5), candidate("other", artist: "Different Artist", score: 60)]
        selectedLyricID = "selected"
        applyLyrics(lyricCandidates[0].response, source: lyricCandidates[0].source)
        lyricSearchSummary = "找到 3 个候选，请核对版本"
    }
    func setSyntheticElapsed(_ value: Double) { musicElapsed = value }
}
let stateTest = SystemAppsStore()
stateTest.testMusicState()
print("PASS: selected lyrics hold, stale results ignored, manual search requires choice, snapshot jitter/gaps and real track changes")
previewSystem.loadLyricSearchPreview()
render(LyricSearchHost(store: previewSystem), name: "lyric-search-light", size: CGSize(width: 640, height: 660))
render(LyricSearchHost(store: previewSystem), name: "lyric-search-dark", size: CGSize(width: 640, height: 660), dark: true)
for (name, elapsed) in [("short", 1.0), ("long", 11.0), ("last", 21.0)] {
    previewSystem.setSyntheticElapsed(elapsed)
    previewSystem.musicExpanded = false
    render(pill("music"), name: "music-compact-\(name)", size: CGSize(width: 464, height: 36), dark: true)
    previewSystem.musicExpanded = true
    render(pill("music"), name: "music-expanded-\(name)", size: CGSize(width: 528, height: 184), dark: true)
}
print("PASS: rendered stable lyric layouts and multilingual search results")

// Reproduce the old cache bug using a fresh SQLite file, never the user's database.
let fixtureURL = FileManager.default.temporaryDirectory.appendingPathComponent("notch-lyrics-\(UUID().uuidString).sqlite")
var fixtureDB: OpaquePointer?
assert(sqlite3_open(fixtureURL.path, &fixtureDB) == SQLITE_OK)
assert(sqlite3_exec(fixtureDB, "CREATE TABLE dbTrack (id TEXT, jsonStr TEXT)", nil, nil, nil) == SQLITE_OK)
func insertFixture(_ id: String, artist: String, duration: Int = 240000) {
    let data = try! JSONSerialization.data(withJSONObject: ["name": "Quiet Morning", "artists": [["name": artist]], "duration": duration])
    let json = String(data: data, encoding: .utf8)!.replacingOccurrences(of: "'", with: "''")
    assert(sqlite3_exec(fixtureDB, "INSERT INTO dbTrack VALUES ('\(id)', '\(json)')", nil, nil, nil) == SQLITE_OK)
}
insertFixture("1001", artist: "Wrong Artist")
assert(NeteaseLyricSource.cachedSongID(title: "Quiet Morning", artist: "Example Artist", duration: 240, databaseURL: fixtureURL) == nil)
insertFixture("1002", artist: "Example Artist")
assert(NeteaseLyricSource.cachedSongID(title: "Quiet Morning", artist: "Example Artist", duration: 240, databaseURL: fixtureURL) == "1002")
assert(NeteaseLyricSource.cachedSongID(title: "Quiet Morning", artist: "Example Artist", duration: 248, databaseURL: fixtureURL) == nil)
insertFixture("1003", artist: "Example Artist")
assert(NeteaseLyricSource.cachedSongID(title: "Quiet Morning", artist: "Example Artist", duration: 240, databaseURL: fixtureURL) == nil)
sqlite3_close(fixtureDB)
try! FileManager.default.removeItem(at: fixtureURL)
print("PASS: SQLite cache rejects wrong singer, duration mismatch and ambiguous recording IDs")

let remembered = "Song\u{1f}Artist\u{1f}Album\u{1f}240"
assert(MusicTrackIdentity.persistedKey("Song\u{1f}Artist\u{1f}Album\u{1f}241", existing: [remembered]) == remembered)
assert(MusicTrackIdentity.persistedKey("Song\u{1f}Artist\u{1f}Album\u{1f}250", existing: [remembered]) != remembered)
assert(MusicTrackIdentity.persistedKey("Song\u{1f}Other\u{1f}Album\u{1f}240", existing: [remembered]) != remembered)
print("PASS: saved corrections survive duration jitter without crossing artists or different-length versions")

// Calendar authorization regression uses an injected source; no real calendar is queried or saved.
final class FixtureCalendarSource: TimelineCalendarSource {
    var accessCompletion: (@Sendable (Bool, (any Error)?) -> Void)?
    var requestCount = 0
    var readCount = 0
    var emptyReads = 0
    var rows: [EKCalendar] = []
    var eventRows: [EKEvent] = []
    func requestFullAccessToEvents(completion: @escaping @Sendable (Bool, (any Error)?) -> Void) {
        requestCount += 1; accessCompletion = completion
    }
    func reset() {}
    func calendars(for entityType: EKEntityType) -> [EKCalendar] {
        readCount += 1
        return readCount <= emptyReads ? [] : rows
    }
    func predicateForEvents(withStart startDate: Date, end endDate: Date, calendars: [EKCalendar]?) -> NSPredicate {
        NSPredicate(value: true)
    }
    func events(matching predicate: NSPredicate) -> [EKEvent] { eventRows }
}
func awaitCalendar(_ condition: () -> Bool, timeout: Double = 2) {
    let end = Date().addingTimeInterval(timeout)
    while !condition() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    assert(condition())
}
let fixtureOwner = EKEventStore()
let fixtureCalendar = EKCalendar(for: .event, eventStore: fixtureOwner)
fixtureCalendar.title = "Synthetic calendar"
let fixtureEvent = EKEvent(eventStore: fixtureOwner)
fixtureEvent.calendar = fixtureCalendar
fixtureEvent.title = "Synthetic event"
fixtureEvent.startDate = Date()
fixtureEvent.endDate = Date().addingTimeInterval(3600)
let oldCalendarSource = FixtureCalendarSource()
let newCalendarSource = FixtureCalendarSource()
newCalendarSource.rows = [fixtureCalendar]
newCalendarSource.eventRows = [fixtureEvent]
newCalendarSource.emptyReads = 1
var testAuthorization: EKAuthorizationStatus = .notDetermined
var sourceCount = 0
let calendarSuiteName = "notch-calendar-test-\(UUID().uuidString)"
let calendarDefaults = UserDefaults(suiteName: calendarSuiteName)!
let calendarModel = TimelineStore(defaults: calendarDefaults, startTimer: false,
    calendarAuthorization: { testAuthorization }, makeCalendarSource: {
        sourceCount += 1
        return sourceCount == 1 ? oldCalendarSource : newCalendarSource
    })
calendarModel.open(pinned: false)
calendarModel.open(pinned: false)
assert(oldCalendarSource.requestCount == 1)
assert(oldCalendarSource.readCount == 0)
testAuthorization = .fullAccess
oldCalendarSource.accessCompletion?(true, nil)
awaitCalendar({ calendarModel.events.count == 1 })
assert(sourceCount == 2 && newCalendarSource.readCount >= 2)
assert(calendarModel.calendarReady && !calendarModel.calendarRequestPending)
testAuthorization = .denied
calendarModel.refreshTime()
assert(!calendarModel.calendarReady && calendarModel.events.isEmpty && calendarModel.calendars.isEmpty)
testAuthorization = .fullAccess
calendarModel.refreshTime()
assert(calendarModel.calendarReady && calendarModel.events.count == 1)
calendarModel.disableCalendar()
assert(calendarModel.events.isEmpty && !calendarModel.calendarEnabled)

let lateSource = FixtureCalendarSource()
let lateModel = TimelineStore(defaults: calendarDefaults, startTimer: false,
    calendarAuthorization: { .notDetermined }, makeCalendarSource: { lateSource })
lateModel.enableCalendar()
lateModel.disableCalendar()
lateSource.accessCompletion?(true, nil)
awaitCalendar({ !lateModel.calendarRequestPending })
assert(!lateModel.calendarEnabled && lateSource.readCount == 0)

let emptySource = FixtureCalendarSource()
let emptyModel = TimelineStore(defaults: calendarDefaults, startTimer: false,
    calendarAuthorization: { .fullAccess }, makeCalendarSource: { emptySource })
emptyModel.enableCalendar()
let retryEnd = Date().addingTimeInterval(4.6)
while Date() < retryEnd { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
assert(emptySource.readCount == 4, "Calendar retries must be bounded")
assert(emptyModel.calendarMessage == "暂无可用日历")
emptyModel.disableCalendar()
let deniedSource = FixtureCalendarSource()
let deniedModel = TimelineStore(defaults: calendarDefaults, startTimer: false,
    calendarAuthorization: { .denied }, makeCalendarSource: { deniedSource })
deniedModel.open(pinned: false)
deniedModel.open(pinned: false)
assert(deniedSource.requestCount == 0 && deniedSource.readCount == 0)
assert(!deniedModel.calendarReady && deniedModel.events.isEmpty)
assert(deniedModel.calendarMessage == "请在系统设置中允许访问日历")
let grantedSource = FixtureCalendarSource()
grantedSource.rows = [fixtureCalendar]
grantedSource.eventRows = [fixtureEvent]
let grantedModel = TimelineStore(defaults: calendarDefaults, startTimer: false,
    calendarAuthorization: { .fullAccess }, makeCalendarSource: { grantedSource })
grantedModel.open(pinned: false)
assert(grantedSource.requestCount == 0 && grantedModel.events.count == 1)
grantedModel.disableCalendar()
calendarDefaults.removePersistentDomain(forName: calendarSuiteName)
print("PASS: opening timeline requests access once, denied access does not reprompt, existing permission loads immediately")
print("PASS: calendar grant loads without restart, delayed data retries, permission changes, duplicate requests, late callback and bounded empty-calendar retries")

// Interrupted transitions must never apply stale heights or close a reopened capsule.
let motionModel = TimelineStore(defaults: scratchDefaults, startTimer: false, calendarAuthorization: { .denied })
motionModel.setLevel(3)
motionModel.setLevel(1)
if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { assert(motionModel.renderedLevel == 3) }
motionModel.setLevel(2)
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
assert(motionModel.level == 2 && motionModel.renderedLevel == 2 && motionModel.retiringFrom == nil)
var closed = false
motionModel.close { closed = true }
motionModel.open(pinned: false)
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { assert(!closed) }
assert(motionModel.visible && !motionModel.closing && motionModel.renderedLevel == 1)
var interactions: [Bool] = []
motionModel.interactionChanged = { interactions.append($0) }
motionModel.setInteracting(.day, true)
motionModel.setInteracting(.month, true)
motionModel.setInteracting(.day, false)
assert(interactions == [true])
motionModel.hide()
assert(interactions == [true, false])
for index in 0...100 {
    let phase = Double(index) / 100
    assert(TimelineMotion.rebound(phase) >= -0.0001 && TimelineMotion.rebound(phase) < 1.02)
    for start in [0.0, 0.2, 0.5, 1.0] {
        assert(TimelineMotion.eventPhase(start: start, progress: 0.5, phase: 1) == 1)
        assert(TimelineMotion.eventPhase(start: start, progress: 0.5, phase: 0) == 0)
    }
}
assert(TimelineMotion.fillPhase(0) == 0 && TimelineMotion.fillPhase(0.82) == 1)
assert(TimelineMotion.eventPhase(start: 0.25, progress: 0.5, phase: 0.4) == 0)
assert(TimelineMotion.eventPhase(start: 0.25, progress: 0.5, phase: 0.5) > 0)
assert(TimelineMotion.ambientStrength(elapsed: 4, hovered: false, passive: true) < 0.1)
assert(TimelineMotion.ambientStrength(elapsed: 4, hovered: true, passive: true) == 0.65)
print("PASS: interrupted timeline transitions, popover interaction balance, sweep arrivals and quiet idle")

extension BallView {
    var previewHoverWeights: [CGFloat] { hoverWeights }
    var previewPillAlpha: CGFloat? { pillHost?.alphaValue }
    var previewPillHidden: Bool { pillHost?.isHidden ?? true }
    var previewPillFrame: CGRect? { pillHost?.frame }
}
let motionBalls = BallView(frame: CGRect(x: 0, y: 0, width: 640, height: 540),
    config: testConfig, store: previewStore, systemApps: previewSystem,
    pomodoro: previewPomodoro, timeline: previewTimeline)
motionBalls.reveal = 1
motionBalls.hovered = 0
motionBalls.hovered = 1
motionBalls.hovered = nil
RunLoop.main.run(until: Date().addingTimeInterval(0.25))
assert(motionBalls.previewHoverWeights.allSatisfy { abs($0) < 0.001 })
motionBalls.selected = 0
RunLoop.main.run(until: Date().addingTimeInterval(0.4))
let priorFrame = motionBalls.previewPillFrame!
motionBalls.selected = 1
assert(!motionBalls.previewPillHidden, "Switching modules must preserve visibility")
assert(motionBalls.previewPillAlpha == 1, "Switching modules must not blank the capsule")
assert(motionBalls.previewPillFrame == priorFrame, "Switching modules must begin at the visible capsule")
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
motionBalls.selected = nil
RunLoop.main.run(until: Date().addingTimeInterval(0.35))
assert(motionBalls.previewPillFrame == nil && motionBalls.previewPillAlpha == nil)
print("PASS: smooth hover interruption and module switch preserves visible shell")

// Exercise production menu refresh paths using injected synthetic stores.
extension AppDelegate {
    func prepareTrackingPreview() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "snapshot"
        statsMenuItem = NSMenuItem(title: "snapshot", action: nil, keyEquivalent: "")
        endSessionMenuItem = NSMenuItem(title: "end", action: nil, keyEquivalent: "")
        autoNoiseItem = NSMenuItem(title: "noise", action: nil, keyEquivalent: "")
        pointerInsideOverlay = true
    }
    var trackingTitle: String { statusItem.button?.title ?? "" }
    var trackingSummary: String { statsMenuItem.title }
    func openTrackingPreview() { beginMenuTracking() }
    func closeTrackingPreview() { endMenuTracking() }
    func tickTrackingPreview() {
        updateMenuBar(); refreshSettingsChecks(); updatePlacement(refreshFullscreen: true); updatePointerRouting()
    }
    func finishTrackingPreview() { NSStatusBar.system.removeStatusItem(statusItem) }
}
let trackingDelegate = AppDelegate(config: testConfig, moduleStore: previewStore,
    systemApps: previewSystem, pomodoro: previewPomodoro)
trackingDelegate.prepareTrackingPreview()
trackingDelegate.openTrackingPreview()
trackingDelegate.openTrackingPreview()
for _ in 0..<120 { trackingDelegate.tickTrackingPreview() }
assert(trackingDelegate.trackingTitle == "snapshot" && trackingDelegate.trackingSummary == "snapshot")
trackingDelegate.closeTrackingPreview()
assert(trackingDelegate.trackingTitle == "snapshot")
trackingDelegate.closeTrackingPreview()
assert(trackingDelegate.trackingTitle != "snapshot" && trackingDelegate.trackingSummary != "snapshot")
trackingDelegate.closeTrackingPreview()
trackingDelegate.finishTrackingPreview()
print("PASS: native menu tracking freezes status/menu mutations across nested submenus and resumes once")

var tone = BackdropTone()
assert(tone.ingest(0.9, time: 0) == false)
assert(tone.ingest(0.17, time: 1) == nil)
assert(tone.ingest(0.03, time: 2) == nil)
assert(tone.ingest(0.17, time: 2.1) == nil)
assert(tone.ingest(0.03, time: 3) == nil)
assert(tone.ingest(0.03, time: 3.3) == true)
assert(tone.ingest(0.20, time: 4) == nil)
assert(tone.ingest(0.90, time: 5) == nil)
assert(tone.ingest(0.90, time: 5.3) == false)
assert(tone.ingest(.nan, time: 6) == nil)
let negativeScreen = BackdropRegion(frame: CGRect(x: -950, y: 870, width: 400, height: 40),
    screenFrame: CGRect(x: -1000, y: 0, width: 1000, height: 1000), displayID: 0, excludedWindows: [])
assert(negativeScreen.sourceRect == CGRect(x: 50, y: 90, width: 400, height: 40))
func solidBackdrop(_ color: CGColor) -> CGImage {
    let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(color); context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
    return context.makeImage()!
}
assert(BackdropTone.luminance(of: solidBackdrop(CGColor(gray: 1, alpha: 1)))! > 0.99)
assert(BackdropTone.luminance(of: solidBackdrop(CGColor(gray: 0, alpha: 1)))! < 0.01)
let sRGBRed = CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [1, 0, 0, 1])!
assert(abs(BackdropTone.luminance(of: solidBackdrop(sRGBRed))! - 0.2126) < 0.005)
assert(BackdropTone.luminance(of: solidBackdrop(CGColor(gray: 0, alpha: 0))) == nil)
let ink = CapsuleForeground(isDark: false)
ink.adapt(isDark: true)
assert(ink.lightFraction == 0)
RunLoop.main.run(until: Date().addingTimeInterval(0.12))
assert(ink.lightFraction > 0 && ink.lightFraction < 1)
let interruptedInk = ink.lightFraction
ink.adapt(isDark: false)
assert(ink.lightFraction == interruptedInk)
RunLoop.main.run(until: Date().addingTimeInterval(0.32))
assert(abs(ink.lightFraction) < 0.001)
print("PASS: real pixel luminance, secondary-display coordinates, hysteresis and interruptible text color interpolation")

// Permission, pause, revocation and late captures are simulated; never capture a real screen.
var backdropTestsDone = false
Task { @MainActor in
    let permissions = UserDefaults(suiteName: "notch-backdrop-tests-\(UUID().uuidString)")!
    var authorized = false, requests = 0, captures = 0
    let sampler = BackdropContrastStore(foreground: ink, defaults: permissions, startTimer: false,
        authorization: { authorized }, requestAuthorization: { requests += 1; return false },
        capture: { _ in captures += 1; return 0.95 })
    sampler.region = { negativeScreen }
    await sampler.sampleNow(); await sampler.sampleNow()
    assert(requests == 1 && captures == 0 && sampler.enabled)
    authorized = true
    sampler.paused = true
    await sampler.sampleNow()
    assert(captures == 0)
    sampler.paused = false
    await sampler.sampleNow()
    assert(captures == 1 && requests == 1 && sampler.ready && ink.tracksBackdrop)
    try? await Task.sleep(nanoseconds: 450_000_000)
    authorized = false
    await sampler.sampleNow()
    assert(!sampler.ready && !ink.tracksBackdrop && sampler.enabled && requests == 1)
    sampler.setEnabled(false)
    let restored = BackdropContrastStore(foreground: ink, defaults: permissions, startTimer: false,
        authorization: { false }, requestAuthorization: { fatalError("Disabled preference must not prompt") },
        capture: { _ in fatalError("Disabled preference must not capture") })
    assert(!restored.enabled)
    restored.region = { negativeScreen }
    await restored.sampleNow()

    let grantedDefaults = UserDefaults(suiteName: "notch-backdrop-granted-\(UUID().uuidString)")!
    var pendingCapture: CheckedContinuation<Double?, Error>?
    let late = BackdropContrastStore(foreground: ink, defaults: grantedDefaults, startTimer: false,
        authorization: { true }, requestAuthorization: { fatalError("Existing grant must be reused") },
        capture: { _ in try await withCheckedThrowingContinuation { pendingCapture = $0 } })
    late.region = { negativeScreen }
    let pendingTask = Task { @MainActor in await late.sampleNow() }
    while pendingCapture == nil { await Task.yield() }
    late.setEnabled(false)
    pendingCapture!.resume(returning: 0.01)
    await pendingTask.value
    assert(!ink.tracksBackdrop && !late.enabled)
    late.setEnabled(true)
    pendingCapture = nil
    try? await Task.sleep(nanoseconds: 450_000_000)
    let failingTask = Task { @MainActor in await late.sampleNow() }
    while pendingCapture == nil { await Task.yield() }
    late.paused = true
    pendingCapture!.resume(throwing: NSError(domain: "SyntheticCapture", code: 1))
    await failingTask.value
    late.paused = false
    pendingCapture = nil
    let recoveredTask = Task { @MainActor in await late.sampleNow() }
    while pendingCapture == nil { await Task.yield() }
    pendingCapture!.resume(returning: 0.95)
    await recoveredTask.value
    assert(ink.tracksBackdrop)
    print("PASS: backdrop reuses existing authorization, requests once, pauses for menus, retains intent after revocation and rejects disabled late captures")
    backdropTestsDone = true
}
let backdropDeadline = Date().addingTimeInterval(5)
while !backdropTestsDone && Date() < backdropDeadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
}
assert(backdropTestsDone)

// Check readable settled foregrounds without changing the system's appearance.
previewInteraction.setPinned("music", true)
previewInteraction.controlsArmed = false
previewSystem.musicExpanded = false
let adaptiveInk = CapsuleForeground(isDark: false)
adaptiveInk.tracksBackdrop = true
func adaptivePill() -> some View {
    GlassPill(module: SceneConfig.fallback.modules.first { $0.id == "music" }!, store: previewStore,
        systemApps: previewSystem, pomodoro: previewPomodoro, timeline: previewTimeline,
        interaction: previewInteraction, onClose: {}, foreground: adaptiveInk)
}
render(adaptivePill(), name: "adaptive-ink-light-background", size: CGSize(width: 464, height: 36), dark: false)
adaptiveInk.adapt(isDark: true)
RunLoop.main.run(until: Date().addingTimeInterval(0.32))
render(adaptivePill(), name: "adaptive-ink-dark-background", size: CGSize(width: 464, height: 36), dark: true)
if #available(macOS 26.0, *) {
    let backing = CapsuleGlassBacking()
    for fraction in [0.0, 0.3, 0.5, 0.8, 1.0] {
        NativePillGlass(clearPassThrough: true, corner: 18, lightFraction: fraction).configure(backing)
        assert(backing.light.style == .clear && backing.dark.style == .clear)
        assert(backing.light.alphaValue + backing.dark.alphaValue <= 0.22001)
    }
}
print("PASS: adaptive foregrounds render in both backgrounds and blended clear backing never exceeds its opacity cap")

// Fullscreen Pin uses synthetic screen geometry and our own panels only.
let pinScreen = CGRect(x: 0, y: 0, width: 1512, height: 982)
let pinGeometry = FullscreenPinGeometry.resolve(screen: pinScreen, safeTop: 33, notchLeft: 668, notchRight: 844)
assert(pinGeometry.usesWings && pinGeometry.left!.maxX == 668 && pinGeometry.right.minX == 844)
assert(pinGeometry.left!.minY >= pinScreen.maxY - 33 && pinGeometry.right.maxY <= pinScreen.maxY)
assert(!pinGeometry.left!.intersects(pinGeometry.right))
let shiftedPin = FullscreenPinGeometry.resolve(screen: pinScreen.offsetBy(dx: -1800, dy: -700), safeTop: 33,
    notchLeft: 668 - 1800, notchRight: 844 - 1800)
assert(shiftedPin.left == pinGeometry.left!.offsetBy(dx: -1800, dy: -700))
assert(shiftedPin.right == pinGeometry.right.offsetBy(dx: -1800, dy: -700))
for screen in [CGRect(x: 0, y: 0, width: 1024, height: 768), CGRect(x: -1920, y: 0, width: 1920, height: 1080)] {
    let shape = FullscreenPinGeometry.resolve(screen: screen, safeTop: 0, notchLeft: nil, notchRight: nil)
    assert(!shape.usesWings && screen.contains(shape.right) && shape.right.height == 28)
}
assert(!FullscreenPinGeometry.resolve(screen: pinScreen, safeTop: 33, notchLeft: 20, notchRight: 1490).usesWings)
let originalPinLayout = CapsuleLayoutSnapshot(selected: 0, reminders: true, notes: false, music: false,
    pomodoro: false, timelineLevel: 3)
let temporaryPinLayout = CapsuleLayoutSnapshot(selected: 1, reminders: false, notes: false, music: false,
    pomodoro: false, timelineLevel: 1)
var pinSession = FullscreenPinSession()
assert(pinSession.update(active: true, snapshot: originalPinLayout) == nil)
pinSession.expand(); assert(pinSession.active && pinSession.expanded)
assert(pinSession.update(active: true, snapshot: temporaryPinLayout) == nil)
pinSession.collapse(); assert(pinSession.active && !pinSession.expanded)
assert(pinSession.update(active: false, snapshot: temporaryPinLayout) == originalPinLayout)
assert(pinSession.desktop == nil && !pinSession.expanded)
assert(pinSession.update(active: false, snapshot: temporaryPinLayout) == nil)
for _ in 0..<30 {
    _ = pinSession.update(active: true, snapshot: originalPinLayout)
    pinSession.expand(); pinSession.collapse()
    assert(pinSession.update(active: false, snapshot: temporaryPinLayout) == originalPinLayout)
}
print("PASS: fullscreen wings leave the hardware gap empty, negative screens align, notchless screens stay visible and desktop snapshots survive interruptions")

let focusPinStatus = FullscreenPinStatus(moduleID: "pomodoro", value: "20:18", symbol: nil,
    progress: 0.19, accessibility: "固定番茄钟，20 分 18 秒")
let musicPinStatus = FullscreenPinStatus(moduleID: "music", value: "播放中", symbol: nil,
    progress: 0.44, accessibility: "固定音乐，播放中")
let timelinePinStatus = FullscreenPinStatus(moduleID: "timeline", value: "65%", symbol: nil,
    progress: 0.65, accessibility: "固定时间轴，今日进度65%")
for (name, status) in [("focus", focusPinStatus), ("music", musicPinStatus), ("timeline", timelinePinStatus)] {
    render(HStack(spacing: 0) {
        FullscreenPinSurface(status: status, part: .left, action: {}).frame(width: 40)
        Color.black.frame(width: 176)
        FullscreenPinSurface(status: status, part: .right, action: {}).frame(width: 64)
    }, name: "fullscreen-pin-\(name)", size: CGSize(width: 280, height: 28), dark: true)
}
render(FullscreenPinSurface(status: focusPinStatus, part: .capsule, action: {}),
    name: "fullscreen-pin-external", size: CGSize(width: 148, height: 28))
let nativePins = FullscreenPinController()
var nativePinClicks = 0
nativePins.open = { nativePinClicks += 1 }
nativePins.update(status: focusPinStatus, geometry: pinGeometry, menuTracking: false)
RunLoop.main.run(until: Date().addingTimeInterval(0.15))
assert(nativePins.leftPanel!.isVisible && nativePins.rightPanel!.isVisible)
assert(!nativePins.leftPanel!.canBecomeKey && !nativePins.rightPanel!.canBecomeMain)
for panel in [nativePins.leftPanel!, nativePins.rightPanel!] {
    assert(panel.level.rawValue > Int(CGWindowLevelForKey(.mainMenuWindow)) &&
           panel.level.rawValue < Int(CGWindowLevelForKey(.popUpMenuWindow)),
        "Fullscreen wings must clear the notch backing and stay below popup menus")
}
assert(nativePins.leftPanel!.frame == pinGeometry.left && nativePins.rightPanel!.frame == pinGeometry.right,
    "Expected \(pinGeometry); actual left \(nativePins.leftPanel!.frame), right \(nativePins.rightPanel!.frame)")
func clickSyntheticPin(_ panel: NSPanel) {
    let point = CGPoint(x: panel.contentView!.bounds.midX, y: panel.contentView!.bounds.midY)
    let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
        windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0.01,
        windowNumber: panel.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
    NSApp.postEvent(up, atStart: false)
    panel.sendEvent(down)
    if let queuedUp = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
        panel.sendEvent(queuedUp)
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
}
clickSyntheticPin(nativePins.leftPanel!)
clickSyntheticPin(nativePins.rightPanel!)
assert(nativePinClicks == 2, "Both resident wings must respond on the first click")
nativePins.pauseInteraction(true)
assert(nativePins.leftPanel!.ignoresMouseEvents && nativePins.rightPanel!.ignoresMouseEvents)
assert(nativePins.leftPanel!.isVisible && nativePins.rightPanel!.isVisible)
nativePins.pauseInteraction(false)
let externalPinGeometry = FullscreenPinGeometry.resolve(screen: pinScreen, safeTop: 0, notchLeft: nil, notchRight: nil)
nativePins.update(status: musicPinStatus, geometry: externalPinGeometry, menuTracking: false)
assert(!nativePins.leftPanel!.isVisible && nativePins.rightPanel!.isVisible)
nativePins.hide()
print("PASS: actual native wing panels accept first clicks, stay visible during menu tracking, never take keyboard focus and fall back to a visible capsule")

extension AppDelegate {
    func prepareFullscreenPreview() {
        prepareTrackingPreview()
        timeline = TimelineStore(defaults: scratchDefaults, startTimer: false, calendarAuthorization: { .denied })
        let interaction = CapsuleInteraction(defaults: scratchDefaults)
        interaction.setPinned("demo-a", true)
        balls = BallView(frame: CGRect(x: 0, y: 0, width: 640, height: 540), config: config,
            store: moduleStore, systemApps: systemApps, pomodoro: pomodoro, timeline: timeline, interaction: interaction)
        overlay = makePanel(frame: balls.frame)
        overlay.contentView = balls
        trigger = makePanel(frame: CGRect(x: 0, y: 0, width: 160, height: 30))
        trigger.contentView = TriggerView()
        balls.reveal = 1
        balls.selected = 0
        moduleStore.setReminderExpanded(true)
        timeline.setLevel(3)
        fullscreenPinController.open = { [weak self] in self?.toggleFullscreenCapsule() }
        balls.interaction.compactRequested = { [weak self] in self?.compactFullscreenCapsule() }
    }
    func placeFullscreenPreview() { updatePlacement(refreshFullscreen: true) }
    func openFullscreenPreview() { toggleFullscreenCapsule() }
    func compactFullscreenPreview() { compactFullscreenCapsule() }
    var fullscreenPreviewActive: Bool { fullscreenPin.active }
    var fullscreenPreviewExpanded: Bool { fullscreenPin.expanded }
    var fullscreenPreviewSelected: Int? { balls.selected }
    var fullscreenPreviewPinned: Bool { balls.interaction.isPinned("demo-a") }
    var fullscreenPreviewReminders: Bool { moduleStore.reminderExpanded }
    var fullscreenPreviewTimelineLevel: Int { timeline.level }
    var fullscreenPreviewOverlay: NSPanel { overlay }
    func editFullscreenPreview() { moduleStore.setReminderExpanded(false); timeline.setLevel(1) }
    func replaceFullscreenPinPreview() {
        balls.interaction.setPinned("demo-a", false)
        balls.interaction.setPinned("demo-b", true)
    }
    func finishFullscreenPreview() {
        collapseWork?.cancel(); revealAnimator.cancel(); fullscreenAnimator.cancel()
        fullscreenPinController.hide(); overlay.orderOut(nil); trigger.orderOut(nil)
        finishTrackingPreview()
    }
}
var syntheticFullscreen = true
let fullscreenDelegate = AppDelegate(config: testConfig, moduleStore: ModuleStore(), systemApps: SystemAppsStore(),
    pomodoro: PomodoroModel(defaults: scratchDefaults, phaseCue: { _ in }), fullscreenDetection: { _ in syntheticFullscreen })
fullscreenDelegate.prepareFullscreenPreview()
fullscreenDelegate.placeFullscreenPreview()
RunLoop.main.run(until: Date().addingTimeInterval(0.25))
assert(fullscreenDelegate.fullscreenPreviewActive && !fullscreenDelegate.fullscreenPreviewExpanded)
assert(!fullscreenDelegate.fullscreenPreviewOverlay.isVisible && fullscreenDelegate.fullscreenPreviewPinned)
fullscreenDelegate.openFullscreenPreview()
RunLoop.main.run(until: Date().addingTimeInterval(0.25))
assert(fullscreenDelegate.fullscreenPreviewExpanded && fullscreenDelegate.fullscreenPreviewOverlay.isVisible)
fullscreenDelegate.editFullscreenPreview()
fullscreenDelegate.compactFullscreenPreview()
fullscreenDelegate.openFullscreenPreview()
RunLoop.main.run(until: Date().addingTimeInterval(0.25))
assert(fullscreenDelegate.fullscreenPreviewExpanded && fullscreenDelegate.fullscreenPreviewOverlay.isVisible,
    "An interrupted collapse must not hide a reopened capsule")
fullscreenDelegate.compactFullscreenPreview()
syntheticFullscreen = false
fullscreenDelegate.placeFullscreenPreview()
RunLoop.main.run(until: Date().addingTimeInterval(0.25))
assert(!fullscreenDelegate.fullscreenPreviewActive && fullscreenDelegate.fullscreenPreviewPinned)
assert(fullscreenDelegate.fullscreenPreviewSelected == 0 && fullscreenDelegate.fullscreenPreviewReminders)
assert(fullscreenDelegate.fullscreenPreviewTimelineLevel == 3 && fullscreenDelegate.fullscreenPreviewOverlay.isVisible)
syntheticFullscreen = true
fullscreenDelegate.placeFullscreenPreview()
fullscreenDelegate.replaceFullscreenPinPreview()
syntheticFullscreen = false
fullscreenDelegate.placeFullscreenPreview()
assert(!fullscreenDelegate.fullscreenPreviewPinned && fullscreenDelegate.fullscreenPreviewSelected == 1,
    "An intentionally removed Pin must not be restored on exit")
fullscreenDelegate.finishFullscreenPreview()
scratchDefaults.removePersistentDomain(forName: previewSuite)
print("PASS: production AppDelegate integrates resident/open/compact transitions, ignores stale collapse completions, preserves Pin and restores original desktop expansion")

previewInteraction.fullscreenPresentation = true
previewInteraction.presentationVisible = true
previewStore.setReminderExpanded(true)
previewSystem.notesExpanded = true
previewSystem.musicExpanded = false
render(pill("music"), name: "fullscreen-music-open", size: CGSize(width: 464, height: 60), dark: true)
render(pill("reminders"), name: "fullscreen-reminders-open", size: CGSize(width: 310, height: 380))
render(pill("notes"), name: "fullscreen-notes-open", size: CGSize(width: 310, height: 340))
previewPomodoro.setExpanded(true)
render(pill("pomodoro"), name: "fullscreen-focus-open", size: CGSize(width: 354, height: 484))
previewTimeline.setLevel(3)
previewTimeline.setPresentationVisible(true)
render(pill("timeline"), name: "fullscreen-timeline-open", size: CGSize(width: 520, height: 240), dark: true, settle: 1.1)
previewInteraction.fullscreenPresentation = false
print("PASS: all five modules render the fullscreen compact action without changing their normal content layout")
