// Compiled only by scripts/preview-ui.py, together with production views.
// All content below is synthetic. No reminders, notes or player queries are run.
let previewApp = NSApplication.shared
previewApp.setActivationPolicy(.prohibited)
let previewSuite = "notch-preview-\(UUID().uuidString)"
let scratchDefaults = UserDefaults(suiteName: previewSuite)!
let previewStore = ModuleStore()
let previewSystem = SystemAppsStore()
let previewPomodoro = PomodoroModel(defaults: scratchDefaults, phaseCue: { _ in })
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
func render<V: View>(_ view: V, name: String, size: CGSize, dark: Bool = false) {
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
    RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    host.layoutSubtreeIfNeeded()
    host.display()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("Bitmap unavailable") }
    host.cacheDisplay(in: host.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
    window.orderOut(nil)
    print("Rendered \(name) \(Int(size.width)) × \(Int(size.height))")
}
func pill(_ id: String) -> some View {
    GlassPill(module: SceneConfig.fallback.modules.first { $0.id == id }!, store: previewStore,
              systemApps: previewSystem, pomodoro: previewPomodoro, interaction: previewInteraction, onClose: {})
}
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
    config: testConfig, store: previewStore, systemApps: previewSystem, pomodoro: previewPomodoro)
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
