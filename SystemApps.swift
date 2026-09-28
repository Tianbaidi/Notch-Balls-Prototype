import AppKit
import SwiftUI

private enum ScriptBridge {
    static let queue = DispatchQueue(label: "local.codex.notch.system-apps")
    enum ScriptResult {
        case success(NSAppleEventDescriptor)
        case failure(String)
    }

    static func run(_ source: String) -> ScriptResult {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return .failure("脚本无法编译")
        }
        let result = script.executeAndReturnError(&error)
        if let error {
            return .failure((error["NSAppleScriptErrorMessage"] as? String) ?? "系统应用没有响应")
        }
        return .success(result)
    }

    static func literal(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

final class SystemAppsStore: ObservableObject {
    struct NoteRow: Identifiable {
        let id: String
        let title: String
    }

    @Published var notesExpanded = false
    @Published var musicExpanded = false
    @Published var noteDraft = ""
    @Published private(set) var notes: [NoteRow] = []
    @Published private(set) var notesSummary = "点击读取 Apple 备忘录"
    @Published private(set) var musicTitle = "正在播放"
    @Published private(set) var musicArtist = "点击查看播放状态"
    @Published private(set) var musicAlbum = ""
    @Published private(set) var musicSource = "系统"
    @Published private(set) var musicArtwork: NSImage?
    @Published private(set) var musicPlaying = false
    @Published private(set) var musicAvailable = false
    @Published private(set) var musicElapsed = 0.0
    @Published private(set) var musicDuration = 0.0
    @Published private(set) var timedLyrics: [TimedLyric] = []
    @Published private(set) var plainLyrics: String?
    @Published private(set) var lyricStatus = "开启后查询逐行歌词"
    @Published private(set) var lyricSourceLabel = "歌词"
    @Published private(set) var onlineLyricsEnabled = UserDefaults.standard.bool(forKey: "notch.music.onlineLyrics.v1")
    @Published private(set) var neteaseLyricsEnabled = UserDefaults.standard.bool(forKey: "notch.music.neteaseLyrics.v1")
    @Published private(set) var musicPinned = UserDefaults.standard.bool(forKey: "notch.music.pinned.v1")
    private var musicTimer: Timer?
    private var musicVisible = false
    private var musicFetchInFlight = false
    @Published private(set) var lyricCandidates: [LyricCandidate] = []
    @Published private(set) var selectedLyricID: String?
    @Published private(set) var lyricOffset = 0.0
    @Published private(set) var artistLookupEnabled = UserDefaults.standard.bool(forKey: "notch.music.artistLookup.v1")
    @Published private(set) var independentLyricsEnabled = UserDefaults.standard.bool(forKey: "notch.music.independentLyrics.v1")
    @Published private(set) var extraLyricsEnabled = UserDefaults.standard.bool(forKey: "notch.music.extraLyrics.v1")
    @Published private(set) var lyricSearchSummary = ""
    private var lyricsTrackKey: String?
    private var lyricLookupKey: String?
    private var artworkKey: String?
    private var currentPlayerBundle: String?
    var lyricInteractionChanged: ((Bool) -> Void)?
    var expansionChanged: ((String, Bool) -> Void)?

    func setExpanded(_ module: String, _ expanded: Bool) {
        if module == "notes" {
            guard notesExpanded != expanded else { return }
            notesExpanded = expanded
        } else if module == "music" {
            guard musicExpanded != expanded else { return }
            musicExpanded = expanded
            updateMusicPolling()
        } else { return }
        expansionChanged?(module, expanded)
    }

    func openNotes() {
        notesSummary = "正在读取…"
        ScriptBridge.queue.async { [weak self] in
            let script = """
            tell application "Notes"
                set theAccount to default account
                set resultList to {}
                set noteCount to count of notes of theAccount
                if noteCount > 8 then set noteCount to 8
                repeat with i from 1 to noteCount
                    set oneNote to note i of theAccount
                    set end of resultList to {id of oneNote, name of oneNote}
                end repeat
                return resultList
            end tell
            """
            let result = ScriptBridge.run(script)
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .failure(let message): self.notesSummary = message
                case .success(let descriptor):
                    self.notes = (1...max(1, descriptor.numberOfItems)).compactMap { index in
                        guard index <= descriptor.numberOfItems,
                              let row = descriptor.atIndex(index),
                              let id = row.atIndex(1)?.stringValue,
                              let title = row.atIndex(2)?.stringValue else { return nil }
                        return NoteRow(id: id, title: title)
                    }
                    self.notesSummary = self.notes.isEmpty ? "暂无备忘录" : "最近的备忘录"
                }
            }
        }
    }

    func createNote() {
        let title = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let escaped = title.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        let body = ScriptBridge.literal("<div>\(escaped)</div>")
        notesSummary = "正在新建…"
        ScriptBridge.queue.async { [weak self] in
            let result = ScriptBridge.run("""
            tell application "Notes"
                make new note at default folder of default account with properties {body:\(body)}
            end tell
            """)
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .failure(let message): self.notesSummary = message
                case .success:
                    self.noteDraft = ""
                    self.openNotes()
                }
            }
        }
    }

    func showNote(_ id: String) {
        let literal = ScriptBridge.literal(id)
        ScriptBridge.queue.async { [weak self] in
            let result = ScriptBridge.run("""
            tell application "Notes"
                activate
                show (first note of default account whose id is \(literal))
            end tell
            """)
            if case .failure(let message) = result {
                DispatchQueue.main.async { self?.notesSummary = message }
            }
        }
    }

    func openMusic() {
        guard !musicFetchInFlight else { return }
        musicFetchInFlight = true
        ScriptBridge.queue.async { [weak self] in
            let result = NowPlayingBridge.run()
            DispatchQueue.main.async {
                guard let self else { return }
                self.musicFetchInFlight = false
                switch result {
                case .failure(let error): self.musicArtist = error.localizedDescription
                case .success(let snapshot):
                    self.musicAvailable = snapshot.available
                    guard snapshot.available else {
                        self.musicTitle = "正在播放"
                        self.musicArtist = "系统中没有正在播放的内容"
                        self.musicSource = "系统"
                        self.musicPlaying = false
                        self.musicAlbum = ""
                        self.musicArtwork = nil
                        self.artworkKey = nil
                        self.musicElapsed = 0
                        self.musicDuration = 0
                        self.currentPlayerBundle = nil
                        self.timedLyrics = []
                        self.plainLyrics = nil
                        self.lyricLookupKey = nil
                        self.lyricsTrackKey = nil
                        self.lyricCandidates = []
                        self.selectedLyricID = nil
                        self.lyricOffset = 0
                        self.lyricSourceLabel = "歌词"
                        return
                    }
                    let title = snapshot.title ?? "未知歌曲"
                    let artist = snapshot.artist ?? "未知歌手"
                    self.musicTitle = title
                    self.musicArtist = artist
                    self.musicAlbum = snapshot.album ?? ""
                    self.currentPlayerBundle = snapshot.bundle
                    self.musicSource = snapshot.bundle.flatMap {
                        NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.localizedName
                    } ?? "正在播放"
                    self.musicPlaying = snapshot.playing ?? false
                    self.musicElapsed = snapshot.elapsed ?? 0
                    self.musicDuration = snapshot.duration ?? 0
                    let key = title + "\u{1f}" + artist + "\u{1f}"
                        + self.musicAlbum + "\u{1f}" + String(Int(self.musicDuration))
                    if self.artworkKey != key {
                        self.artworkKey = key
                        self.musicArtwork = nil
                        self.fetchArtwork(key: key)
                    }
                    if self.lyricsTrackKey != key {
                        self.lyricsTrackKey = key
                        self.lyricLookupKey = nil
                        self.timedLyrics = []
                        self.plainLyrics = nil
                        self.lyricCandidates = []
                        self.selectedLyricID = nil
                        self.lyricSearchSummary = ""
                        self.lyricOffset = (UserDefaults.standard.dictionary(forKey: "notch.music.lyricOffsets.v1")?[key] as? Double) ?? 0
                        self.lyricStatus = "点开选择歌词来源"
                        self.lyricSourceLabel = "歌词"
                        self.restoreLocalLyrics(key: key)
                    }
                    if (self.onlineLyricsEnabled || self.neteaseLyricsEnabled || self.extraLyricsEnabled || self.independentLyricsEnabled) &&
                       self.lyricLookupKey == nil {
                        self.fetchLyrics(title: title, artist: artist,
                                         duration: snapshot.duration,
                                         bundle: snapshot.bundle, key: key)
                    }
                }
            }
        }
    }

    func musicCommand(_ command: String) {
        guard musicAvailable, ["toggle", "next", "previous"].contains(command) else { return }
        ScriptBridge.queue.async { [weak self] in
            let result = NowPlayingBridge.run(command: command)
            DispatchQueue.main.async {
                guard let self else { return }
                if case .failure(let error) = result { self.musicArtist = error.localizedDescription }
                else { self.openMusic() }
            }
        }
    }

    func launchMusic() {
        let bundle = currentPlayerBundle ?? "com.netease.163music"
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init()) { [weak self] _, error in
                DispatchQueue.main.async {
                    if let error { self?.musicArtist = error.localizedDescription }
                    else { self?.openMusic() }
                }
            }
        }
    }

    func setMusicPinned(_ pinned: Bool) {
        musicPinned = pinned
        UserDefaults.standard.set(pinned, forKey: "notch.music.pinned.v1")
        updateMusicPolling()
    }

    func setMusicVisible(_ visible: Bool) {
        musicVisible = visible
        updateMusicPolling()
    }

    private func updateMusicPolling() {
        musicTimer?.invalidate()
        musicTimer = (musicVisible || musicExpanded || musicPinned)
            ? Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.openMusic()
            } : nil
    }

    func enableOnlineLyrics() {
        onlineLyricsEnabled = true
        UserDefaults.standard.set(true, forKey: "notch.music.onlineLyrics.v1")
        lyricLookupKey = nil
        openMusic()
    }

    func enableNeteaseLyrics() {
        neteaseLyricsEnabled = true
        UserDefaults.standard.set(true, forKey: "notch.music.neteaseLyrics.v1")
        lyricLookupKey = nil
        openMusic()
    }

    func enableExtraLyrics() {
        extraLyricsEnabled = true
        onlineLyricsEnabled = true
        UserDefaults.standard.set(true, forKey: "notch.music.extraLyrics.v1")
        UserDefaults.standard.set(true, forKey: "notch.music.onlineLyrics.v1")
        retryLyrics()
    }

    func setArtistLookup(_ enabled: Bool) {
        artistLookupEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "notch.music.artistLookup.v1")
        if enabled && !(onlineLyricsEnabled || extraLyricsEnabled || neteaseLyricsEnabled || independentLyricsEnabled) {
            onlineLyricsEnabled = true
            UserDefaults.standard.set(true, forKey: "notch.music.onlineLyrics.v1")
        }
        retryLyrics()
    }

    func retryLyrics() {
        guard musicAvailable, let key = lyricsTrackKey else { return }
        fetchLyrics(title: musicTitle, artist: musicArtist, duration: musicDuration,
                    bundle: currentPlayerBundle, key: key)
    }

    func disableOnlineLyrics() {
        onlineLyricsEnabled = false
        extraLyricsEnabled = false
        independentLyricsEnabled = false
        neteaseLyricsEnabled = false
        artistLookupEnabled = false
        for name in ["onlineLyrics", "extraLyrics", "neteaseLyrics", "independentLyrics", "artistLookup"] {
            UserDefaults.standard.set(false, forKey: "notch.music.\(name).v1")
        }
        // Invalidate callbacks that are already in flight.
        lyricLookupKey = nil
        lyricSearchSummary = "联网查询已关闭"
    }

    private func fetchLyrics(title: String, artist: String, duration: Double?,
                             bundle: String?, key: String) {
        let requestID = key + UUID().uuidString
        lyricLookupKey = requestID
        guard onlineLyricsEnabled || extraLyricsEnabled || neteaseLyricsEnabled || independentLyricsEnabled else {
            lyricStatus = "联网查询已关闭"
            return
        }
        lyricStatus = "正在查询歌词…"
        lyricSearchSummary = "正在匹配…"
        let query = LyricQuery(title: title, artist: artist, album: musicAlbum, duration: duration)
        let extraSources = extraLyricsEnabled
        let lrclib = onlineLyricsEnabled || extraLyricsEnabled
        let artistLookup = artistLookupEnabled
        let externalSearch: () -> Void = { [weak self] in
            guard let self, self.lyricsTrackKey == key, self.lyricLookupKey == requestID else { return }
            self.lyricSearchSummary = "查询歌词，未命中时自动回退…"
            MultiLyricsService.fetch(query: query, includeExtraSources: extraSources,
                                    includeIndependentSource: true, includeLRCLIB: lrclib, includeArtistLookup: artistLookup) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, self.lyricsTrackKey == key, self.lyricLookupKey == requestID else { return }
                    self.addCandidates(result.candidates, key: key)
                    let failed = result.failedSources.joined(separator: "、")
                    let fallbackUsed = result.candidates.contains { $0.source == "VV 歌词" }
                    self.lyricSearchSummary = fallbackUsed ? "已自动回退至 VV 歌词" : "查询完成"
                    if !failed.isEmpty { self.lyricSearchSummary += " · \(failed) 暂时不可用" }
                    if self.lyricCandidates.isEmpty {
                        self.lyricStatus = result.failedSources.isEmpty ? "未匹配到歌词，可导入 LRC" : "部分歌词源不可用，可重试或导入 LRC"
                    }
                }
            }
        }
        if bundle == "com.netease.163music" && neteaseLyricsEnabled {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let id = NeteaseLyricSource.cachedSongID(title: title, artist: query.searchArtist, duration: duration) else {
                    DispatchQueue.main.async { externalSearch() }
                    return
                }
                NeteaseLyricSource.fetch(id: id) { result in
                    DispatchQueue.main.async {
                        guard let self, self.lyricsTrackKey == key, self.lyricLookupKey == requestID else { return }
                        if case .success(let response) = result,
                           !response.timed.isEmpty || !(response.plain?.isEmpty ?? true) {
                            let candidate = LyricCandidate(id: "netease:" + id, source: "网易云歌词",
                                title: title, artist: artist, album: self.musicAlbum, duration: duration,
                                response: response, score: 160)
                            self.addCandidates([candidate], key: key)
                            self.lyricSearchSummary = "网易云歌词已匹配"
                        } else { externalSearch() }
                    }
                }
            }
        } else { externalSearch() }
    }

    private func addCandidates(_ candidates: [LyricCandidate], key: String) {
        for candidate in candidates {
            if let index = lyricCandidates.firstIndex(where: { $0.id == candidate.id }) {
                lyricCandidates[index] = candidate
            } else { lyricCandidates.append(candidate) }
        }
        lyricCandidates.sort {
            if $0.requiresConfirmation != $1.requiresConfirmation { return !$0.requiresConfirmation }
            let left = $0.score + ($0.response.timed.isEmpty ? 0 : 20)
            let right = $1.score + ($1.response.timed.isEmpty ? 0 : 20)
            return left == right ? $0.id < $1.id : left > right
        }
        let preferred = (UserDefaults.standard.dictionary(forKey: "notch.music.lyricSelections.v1")?[key] as? String)
        let choice = preferred.flatMap { id in lyricCandidates.first { $0.id == id } }
            ?? lyricCandidates.first { !$0.requiresConfirmation }
        if let choice { applyLyrics(choice.response, source: choice.source); selectedLyricID = choice.id }
        else if !lyricCandidates.isEmpty {
            selectedLyricID = nil
            timedLyrics = []
            plainLyrics = nil
            lyricSourceLabel = "待确认"
            lyricStatus = "找到相近歌词，请在歌词来源中确认歌手与版本"
        }
    }

    func selectLyric(_ id: String) {
        guard let key = lyricsTrackKey, let candidate = lyricCandidates.first(where: { $0.id == id }) else { return }
        var selections = UserDefaults.standard.dictionary(forKey: "notch.music.lyricSelections.v1") ?? [:]
        selections[key] = id
        UserDefaults.standard.set(selections, forKey: "notch.music.lyricSelections.v1")
        if candidate.requiresConfirmation && candidate.source != "本地歌词" &&
            candidate.artist.range(of: #"[;/、&，,]"#, options: .regularExpression) == nil {
            var aliases = UserDefaults.standard.dictionary(forKey: "notch.music.artistAliases.v1") ?? [:]
            aliases[LyricQuery.normalize(musicArtist)] = candidate.artist
            UserDefaults.standard.set(aliases, forKey: "notch.music.artistAliases.v1")
        }
        selectedLyricID = id
        applyLyrics(candidate.response, source: candidate.source)
    }

    func adjustLyricOffset(_ delta: Double) {
        guard let key = lyricsTrackKey else { return }
        lyricOffset = min(30, max(-30, lyricOffset + delta))
        var offsets = UserDefaults.standard.dictionary(forKey: "notch.music.lyricOffsets.v1") ?? [:]
        offsets[key] = lyricOffset
        UserDefaults.standard.set(offsets, forKey: "notch.music.lyricOffsets.v1")
    }

    func editLyricArtistName() {
        guard musicAvailable else { return }
        let artist = musicArtist
        let alert = NSAlert()
        alert.messageText = "歌词匹配歌手名"
        alert.informativeText = "播放器显示：\(artist)\n设置用于查询歌词的歌手名，按歌手保存在本机。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = LyricQuery.canonicalArtist(artist)
        alert.accessoryView = field
        alert.addButton(withTitle: "保存并重新查询")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "恢复默认")
        lyricInteractionChanged?(true)
        defer { lyricInteractionChanged?(false) }
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        let choice = alert.runModal()
        var aliases = UserDefaults.standard.dictionary(forKey: "notch.music.artistAliases.v1") ?? [:]
        let key = LyricQuery.normalize(artist)
        if choice == .alertFirstButtonReturn {
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            aliases[key] = value
        } else if choice == .alertThirdButtonReturn { aliases.removeValue(forKey: key) }
        else { return }
        UserDefaults.standard.set(aliases, forKey: "notch.music.artistAliases.v1")
        if musicArtist == artist {
            lyricCandidates.removeAll { $0.source != "本地歌词" }
            if selectedLyricID != "local" { selectedLyricID = nil; timedLyrics = []; plainLyrics = nil }
            retryLyrics()
        }
    }

    func importLyrics() {
        guard let key = lyricsTrackKey, musicAvailable else { return }
        let title = musicTitle, artist = musicArtist, album = musicAlbum, duration = musicDuration
        let panel = NSOpenPanel()
        panel.title = "为“\(title)”导入歌词"
        panel.message = "选择 UTF-8 编码的 .lrc 或 .txt 文件，只保存在本机。"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        lyricInteractionChanged?(true)
        panel.begin { [weak self] response in
            defer { self?.lyricInteractionChanged?(false) }
            guard response == .OK, let url = panel.url, let self else { return }
            guard ["lrc", "txt"].contains(url.pathExtension.lowercased()),
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_000_000,
                  let data = try? Data(contentsOf: url), data.count <= 1_000_000,
                  let text = String(data: data, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                if self.lyricsTrackKey == key { self.lyricSearchSummary = "请选择不超过 1 MB 的 UTF-8 LRC / TXT 文件" }
                return
            }
            var locals = UserDefaults.standard.dictionary(forKey: "notch.music.localLyrics.v1") ?? [:]
            locals[key] = text
            UserDefaults.standard.set(locals, forKey: "notch.music.localLyrics.v1")
            guard self.lyricsTrackKey == key else { return }
            let timed = LyricsParser.timed(text)
            self.addCandidates([LyricCandidate(id: "local", source: "本地歌词", title: title,
                artist: artist, album: album, duration: duration,
                response: LyricsService.Response(timed: timed, plain: timed.isEmpty ? text : nil), score: 200)], key: key)
            self.selectLyric("local")
        }
    }

    private func restoreLocalLyrics(key: String) {
        guard let text = UserDefaults.standard.dictionary(forKey: "notch.music.localLyrics.v1")?[key] as? String else { return }
        let timed = LyricsParser.timed(text)
        addCandidates([LyricCandidate(id: "local", source: "本地歌词", title: musicTitle,
            artist: musicArtist, album: musicAlbum, duration: musicDuration,
            response: LyricsService.Response(timed: timed, plain: timed.isEmpty ? text : nil), score: 200)], key: key)
    }

    private func applyLyrics(_ response: LyricsService.Response, source: String) {
        timedLyrics = response.timed
        plainLyrics = response.plain
        lyricSourceLabel = source
        lyricStatus = response.timed.isEmpty
            ? (response.plain == nil ? "这首歌暂无可用歌词" : "暂无逐行时间，仅显示歌词")
            : "歌词来自 \(source)"
    }

    private func fetchArtwork(key: String) {
        ScriptBridge.queue.async { [weak self] in
            let result = NowPlayingBridge.run(command: "artwork")
            DispatchQueue.main.async {
                guard let self, self.artworkKey == key,
                      case .success(let snapshot) = result,
                      let encoded = snapshot.artworkData,
                      let data = Data(base64Encoded: encoded) else { return }
                self.musicArtwork = NSImage(data: data)
            }
        }
    }

    var currentLyricIndex: Int? {
        guard !timedLyrics.isEmpty else { return nil }
        return timedLyrics.lastIndex(where: { $0.time <= musicElapsed + lyricOffset })
    }

    var musicSourceBundle: String? { currentPlayerBundle }

    var currentLyricText: String {
        if let index = currentLyricIndex { return timedLyrics[index].text }
        if let next = timedLyrics.first { return next.text }
        if let first = plainLyrics?.split(whereSeparator: \.isNewline).first,
           !first.isEmpty { return String(first) }
        return lyricStatus
    }
}
