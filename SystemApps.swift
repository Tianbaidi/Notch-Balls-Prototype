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
    @Published private(set) var lyricsSearching = false
    @Published private(set) var lyricsTrackKey: String?
    private var musicIdentity: MusicTrackIdentity?
    private var missingMusicSnapshots = 0
    private var lyricSearchWindow: LyricSearchWindowController?
    private var lyricLookupKey: String?
    private var lyricSearchTask: Task<Void, Never>?
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
                case .failure: break
                case .success(let snapshot):
                    self.acceptMusicSnapshot(snapshot)
                }
            }
        }
    }

    private func acceptMusicSnapshot(_ snapshot: NowPlayingSnapshot) {
        guard snapshot.available, let incomingTitle = snapshot.title, !incomingTitle.isEmpty else {
            missingMusicSnapshots += 1
            guard missingMusicSnapshots >= 3 else { return }
            self.musicAvailable = false
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
            self.musicIdentity = nil
            self.lyricSearchTask?.cancel()
            self.lyricsSearching = false
            self.lyricCandidates = []
            self.selectedLyricID = nil
            self.lyricOffset = 0
            self.lyricSourceLabel = "歌词"
            self.lyricStatus = "等待播放"
            self.lyricSearchSummary = ""
            return
        }
        missingMusicSnapshots = 0
        let duration = snapshot.duration.flatMap { $0.isFinite && $0 > 0 && $0 < 604800 ? $0 : nil }
        let identity = MusicTrackIdentity(title: incomingTitle, artist: snapshot.artist ?? "",
            album: snapshot.album ?? "", bundle: snapshot.bundle, duration: duration ?? 0)
        let sameTrack = musicIdentity?.matches(identity) == true
        if !sameTrack { musicIdentity = identity }
        // Fill missing identity fields once without moving the duration anchor every second.
        else if let old = musicIdentity {
            musicIdentity = MusicTrackIdentity(title: old.title,
                artist: old.artist.isEmpty ? identity.artist : old.artist,
                album: old.album.isEmpty ? identity.album : old.album,
                bundle: old.bundle ?? identity.bundle,
                duration: old.duration > 0 ? old.duration : identity.duration)
        }
        self.musicAvailable = true
        let title = incomingTitle
        let artist = snapshot.artist.flatMap { $0.isEmpty ? nil : $0 } ?? (sameTrack ? musicArtist : "未知歌手")
        self.musicTitle = title
        self.musicArtist = artist
        self.musicAlbum = snapshot.album.flatMap { $0.isEmpty ? nil : $0 } ?? (sameTrack ? musicAlbum : "")
        self.currentPlayerBundle = snapshot.bundle ?? (sameTrack ? currentPlayerBundle : nil)
        self.musicSource = currentPlayerBundle.flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.localizedName
        } ?? "正在播放"
        self.musicPlaying = snapshot.playing ?? (sameTrack ? musicPlaying : false)
        self.musicElapsed = snapshot.elapsed.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? (sameTrack ? musicElapsed : 0)
        self.musicDuration = duration ?? (sameTrack ? musicDuration : 0)
        let proposedKey = title + "\u{1f}" + artist + "\u{1f}"
            + self.musicAlbum + "\u{1f}" + String(Int(self.musicDuration))
        let key: String
        if sameTrack, let existing = lyricsTrackKey { key = existing }
        else {
            let storedKeys = ["searchOverrides", "lyricSelections", "lyricOffsets", "localLyrics"].flatMap { name in
                Array((UserDefaults.standard.dictionary(forKey: "notch.music.\(name).v1") ?? [:]).keys)
            }
            key = MusicTrackIdentity.persistedKey(proposedKey, existing: storedKeys)
        }
        if self.artworkKey != key {
            self.artworkKey = key
            self.musicArtwork = nil
            self.fetchArtwork(key: key)
        }
        if !sameTrack || self.lyricsTrackKey != key {
            self.lyricsTrackKey = key
            self.lyricSearchTask?.cancel()
            self.lyricsSearching = false
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
            self.retryLyrics()
        }
    }

    func musicCommand(_ command: String) {
        guard musicAvailable, ["toggle", "next", "previous"].contains(command) else { return }
        ScriptBridge.queue.async { [weak self] in
            let result = NowPlayingBridge.run(command: command)
            DispatchQueue.main.async {
                guard let self else { return }
                if case .failure(let error) = result { self.lyricSearchSummary = error.localizedDescription }
                else { self.openMusic() }
            }
        }
    }

    func launchMusic() {
        let bundle = currentPlayerBundle ?? "com.netease.163music"
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init()) { [weak self] _, error in
                DispatchQueue.main.async {
                    if let error { self?.lyricSearchSummary = error.localizedDescription }
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
        let query = lyricSearchQuery
        fetchLyrics(title: query.title, artist: query.artist, duration: musicDuration,
                    bundle: currentPlayerBundle, key: key, album: query.album)
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
        lyricSearchTask?.cancel()
        lyricsSearching = false
        lyricSearchSummary = "联网查询已关闭"
    }

    private func fetchLyrics(title: String, artist: String, duration: Double?,
                             bundle: String?, key: String, album: String? = nil, manual: Bool = false) {
        lyricSearchTask?.cancel()
        let requestID = key + UUID().uuidString
        lyricLookupKey = requestID
        guard onlineLyricsEnabled || extraLyricsEnabled || neteaseLyricsEnabled || independentLyricsEnabled else {
            lyricsSearching = false
            lyricStatus = "联网查询已关闭"
            return
        }
        lyricsSearching = true
        lyricStatus = "正在查询歌词…"
        lyricSearchSummary = "正在匹配…"
        let query = LyricQuery(title: title, artist: artist, album: album ?? musicAlbum, duration: duration)
        let extraSources = extraLyricsEnabled
        let lrclib = onlineLyricsEnabled || extraLyricsEnabled
        let artistLookup = artistLookupEnabled
        let externalSearch: () -> Void = { [weak self] in
            guard let self, self.lyricsTrackKey == key, self.lyricLookupKey == requestID else { return }
            self.lyricSearchSummary = "查询歌词，未命中时自动回退…"
            self.lyricSearchTask = MultiLyricsService.fetch(query: query, includeExtraSources: extraSources,
                                    includeIndependentSource: true, includeLRCLIB: lrclib, includeArtistLookup: artistLookup) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, self.lyricsTrackKey == key, self.lyricLookupKey == requestID else { return }
                    self.lyricsSearching = false
                    self.addCandidates(result.candidates, key: key, automatic: !manual)
                    let failed = result.failedSources.joined(separator: "、")
                    let fallbackUsed = result.candidates.contains { $0.source == "VV 歌词" }
                    self.lyricSearchSummary = result.candidates.isEmpty ? "未找到新候选，试试原文歌名或更准确的歌手名" :
                        (fallbackUsed ? "已找到候选 · 包含 VV 歌词" : "找到 \(result.candidates.count) 个候选，请核对版本")
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
                            self.lyricsSearching = false
                            self.addCandidates([candidate], key: key, automatic: !manual)
                            self.lyricSearchSummary = "网易云歌词已匹配"
                        } else { externalSearch() }
                    }
                }
            }
        } else { externalSearch() }
    }

    private func addCandidates(_ candidates: [LyricCandidate], key: String, automatic: Bool = true) {
        guard key == lyricsTrackKey else { return }
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
        guard automatic else { return }
        let choice = LyricCandidate.choose(lyricCandidates, preferred: preferred, current: selectedLyricID)
        if let choice, choice.id != selectedLyricID {
            applyLyrics(choice.response, source: choice.source); selectedLyricID = choice.id
        }
        else if selectedLyricID == nil && !lyricCandidates.isEmpty {
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

    var lyricSearchQuery: LyricQuery {
        let values = lyricsTrackKey.flatMap {
            UserDefaults.standard.dictionary(forKey: "notch.music.searchOverrides.v1")?[$0] as? [String: String]
        }
        return LyricQuery(title: values?["title"] ?? musicTitle,
            artist: values?["artist"] ?? LyricQuery.canonicalArtist(musicArtist),
            album: values?["album"] ?? musicAlbum, duration: musicDuration)
    }

    func searchLyrics(title: String, artist: String, album: String, key: String) {
        guard key == lyricsTrackKey, musicAvailable else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        guard onlineLyricsEnabled || extraLyricsEnabled || neteaseLyricsEnabled || independentLyricsEnabled else {
            lyricSearchSummary = "请先选择并开启一个联网歌词来源"
            return
        }
        var overrides = UserDefaults.standard.dictionary(forKey: "notch.music.searchOverrides.v1") ?? [:]
        overrides[key] = ["title": title, "artist": artist.trimmingCharacters(in: .whitespacesAndNewlines),
                          "album": album.trimmingCharacters(in: .whitespacesAndNewlines)]
        UserDefaults.standard.set(overrides, forKey: "notch.music.searchOverrides.v1")
        lyricCandidates.removeAll { $0.id != selectedLyricID }
        fetchLyrics(title: title, artist: artist, duration: musicDuration,
                    bundle: currentPlayerBundle, key: key, album: album, manual: true)
    }

    func cancelLyricSearch() {
        lyricSearchTask?.cancel()
        lyricLookupKey = "cancelled-" + UUID().uuidString
        lyricsSearching = false
        lyricSearchSummary = "已取消查询，当前歌词保留"
    }

    func showLyricSearch() {
        if lyricSearchWindow == nil {
            lyricSearchWindow = LyricSearchWindowController(store: self)
        }
        if lyricSearchWindow?.window?.isVisible != true { lyricInteractionChanged?(true) }
        lyricSearchWindow?.showWindow(nil)
        lyricSearchWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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

final class LyricSearchWindowController: NSWindowController, NSWindowDelegate {
    private weak var store: SystemAppsStore?
    init(store: SystemAppsStore) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "搜索与校正歌词"
        window.minSize = NSSize(width: 580, height: 540)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: LyricSearchHost(store: store))
        super.init(window: window)
        window.delegate = self
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func windowWillClose(_ notification: Notification) { store?.lyricInteractionChanged?(false) }
}

struct LyricSearchHost: View {
    @ObservedObject var store: SystemAppsStore
    var body: some View {
        Group {
            if let key = store.lyricsTrackKey, store.musicAvailable {
                LyricSearchView(store: store, key: key, query: store.lyricSearchQuery).id(key)
            } else {
                ContentUnavailableView("先播放一首歌曲", systemImage: "music.note",
                    description: Text("播放后可按歌名、歌手和专辑寻找歌词。"))
            }
        }
    }
}

struct LyricSearchView: View {
    @ObservedObject var store: SystemAppsStore
    let key: String
    @State private var title: String
    @State private var artist: String
    @State private var album: String
    @State private var previewID: String?
    @FocusState private var titleFocused: Bool

    init(store: SystemAppsStore, key: String, query: LyricQuery) {
        self.store = store; self.key = key
        _title = State(initialValue: query.title)
        _artist = State(initialValue: query.artist)
        _album = State(initialValue: query.album)
    }
    private var canSearch: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.lyricsSearching
    }
    private func search() {
        guard canSearch else { return }
        previewID = nil
        store.searchLyrics(title: title, artist: artist, album: album, key: key)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "text.magnifyingglass").font(.system(size: 26)).foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 4) {
                    Text("找到这一首的歌词").font(.title3.bold())
                    Text("播放器 · \(store.musicTitle) · \(store.musicArtist)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Text(LyricCandidate.timeLabel(store.musicDuration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("美区译名搜不到时，可填中文原名；修改仅记住本曲。").font(.caption).foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow { Text("歌名"); TextField("必填，可输入原名或译名", text: $title).focused($titleFocused) }
                    GridRow { Text("歌手"); TextField("可校正英文艺名或合唱信息", text: $artist) }
                    GridRow { Text("专辑"); TextField("选填，用于核对版本", text: $album) }
                }.textFieldStyle(.roundedBorder).onSubmit { search() }
                HStack {
                    Button("填入播放器信息") {
                        title = store.musicTitle; artist = store.musicArtist; album = store.musicAlbum
                    }.buttonStyle(.link)
                    Spacer()
                    Button(action: search) { Label("搜索歌词", systemImage: "magnifyingglass") }
                        .buttonStyle(.borderedProminent).disabled(!canSearch).keyboardShortcut(.return)
                }
            }.padding(14).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 8) {
                if store.lyricsSearching {
                    ProgressView().controlSize(.small)
                    Button("取消") { store.cancelLyricSearch() }.buttonStyle(.link)
                }
                Text(store.lyricSearchSummary.isEmpty ? "核对曲名、歌手和时长，再选择歌词" : store.lyricSearchSummary)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Menu("来源") {
                    Button("开启 QQ、酷狗、LRCLIB") { store.enableExtraLyrics() }
                    Button("开启 LRCLIB") { store.enableOnlineLyrics() }
                    Button("关闭联网查询") { store.disableOnlineLyrics() }
                }.fixedSize()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if store.lyricCandidates.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: store.lyricsSearching ? "waveform" : "text.quote").font(.title)
                            Text(store.lyricsSearching ? "正在寻找候选歌词" : "暂无候选歌词")
                            Text("试试原文歌名，或导入本地 LRC / TXT").font(.caption)
                        }.foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 30)
                    }
                    ForEach(store.lyricCandidates) { candidate in
                        candidateRow(candidate)
                    }
                }
            }
            HStack {
                Text("搜索会向已开启的歌词源发送查询信息。").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("导入歌词…") { store.importLyrics() }
            }
        }.padding(22).frame(minWidth: 536, minHeight: 480)
            .onAppear { titleFocused = true }
    }
    private func candidateRow(_ candidate: LyricCandidate) -> some View {
        let selected = candidate.id == store.selectedLyricID
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.title).font(.headline).textSelection(.enabled)
                    Text(candidate.artist + (candidate.album.isEmpty ? "" : " · " + candidate.album))
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer(minLength: 10)
                Button(selected ? "使用中" : "使用此歌词") { store.selectLyric(candidate.id) }
                    .disabled(selected)
            }
            Text(candidate.evidence(against: store.lyricSearchQuery))
                .font(.caption).foregroundStyle(candidate.requiresConfirmation ? .orange : .secondary)
            HStack {
                Text(candidate.source + " · " + (candidate.response.timed.isEmpty ? "静态歌词" : "逐行同步"))
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button(previewID == candidate.id ? "收起预览" : "预览歌词") {
                    previewID = previewID == candidate.id ? nil : candidate.id
                }.buttonStyle(.link).font(.caption)
            }
            if previewID == candidate.id {
                Text(candidate.response.timed.isEmpty ? String((candidate.response.plain ?? "").prefix(600)) :
                    candidate.response.timed.prefix(8).map(\.text).joined(separator: "\n"))
                    .font(.callout).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }
        }.padding(12).background(selected ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.035),
                                    in: RoundedRectangle(cornerRadius: 10))
    }
}
