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
