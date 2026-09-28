import Foundation
import SQLite3

struct NowPlayingSnapshot: Decodable {
    let available: Bool
    let bundle: String?
    let title: String?
    let artist: String?
    let album: String?
    let artworkData: String?
    let duration: Double?
    let elapsed: Double?
    let playing: Bool?
}

enum NowPlayingBridge {
    static func run(command: String? = nil) -> Result<NowPlayingSnapshot, Error> {
        guard let script = Bundle.main.url(forResource: "now-playing", withExtension: "jxa") else {
            return .failure(NSError(domain: "NowPlayingBridge", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "缺少播放状态脚本"]))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", script.path] + (command.map { [$0] } ?? [])
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "NowPlayingBridge", code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: "无法读取系统播放状态"])
            }
            return .success(try JSONDecoder().decode(NowPlayingSnapshot.self, from: data))
        } catch { return .failure(error) }
    }
}

struct TimedLyric: Identifiable {
    let time: Double
    let text: String
    var id: Double { time }
}

enum LyricsParser {
    static func timed(_ source: String) -> [TimedLyric] {
        guard let tags = try? NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]"#),
              let offsetTag = try? NSRegularExpression(pattern: #"\[offset:([+-]?\d+)\]"#, options: .caseInsensitive) else { return [] }
        var offset = 0.0
        if let match = offsetTag.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
           let range = Range(match.range(at: 1), in: source) {
            offset = (Double(source[range]) ?? 0) / 1000
        }
        var result: [TimedLyric] = []
        for raw in source.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            let matches = tags.matches(in: line, range: NSRange(line.startIndex..., in: line))
            guard let last = matches.last, let lastRange = Range(last.range, in: line) else { continue }
            let prefix = line[..<lastRange.upperBound]
            // Only timestamp tags may precede the text; ignore timestamps inside lyric text.
            let stripped = tags.stringByReplacingMatches(in: String(prefix), range: NSRange(prefix.startIndex..., in: prefix), withTemplate: "")
            guard stripped.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let text = String(line[lastRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            for match in matches {
                guard let minuteRange = Range(match.range(at: 1), in: line),
                      let secondRange = Range(match.range(at: 2), in: line),
                      let minutes = Double(line[minuteRange]), let seconds = Double(line[secondRange]), seconds < 60 else { continue }
                var fraction = 0.0
                if let range = Range(match.range(at: 3), in: line) {
                    fraction = (Double(line[range]) ?? 0) / pow(10, Double(line[range].count))
                }
                result.append(TimedLyric(time: max(0, minutes * 60 + seconds + fraction - offset), text: text))
            }
        }
        return result.enumerated().sorted {
            $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time
        }.map(\.element)
    }
}

enum LyricsService {
    struct Response {
        let timed: [TimedLyric]
        let plain: String?
    }

    static func fetch(title: String, artist: String, duration: Double?,
                      completion: @escaping (Result<Response, Error>) -> Void) {
        var parts = URLComponents(string: "https://lrclib.net/api/search")!
        parts.queryItems = [URLQueryItem(name: "track_name", value: title),
                            URLQueryItem(name: "artist_name", value: artist)]
        var request = URLRequest(url: parts.url!)
        request.timeoutInterval = 12
        request.setValue("NotchBallsPrototype/0.14 (macOS)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { completion(.failure(error)); return }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data,
                  let records = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
                completion(.failure(NSError(domain: "LyricsService", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "歌词查询失败"])))
                return
            }
            let normalizedTitle = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let candidates = records.filter { item in
                guard let name = item["trackName"] as? String else { return false }
                let normalized = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return normalized == normalizedTitle
            }
            let ordered = candidates.sorted { a, b in
                let ad = abs((a["duration"] as? Double ?? duration ?? 0) - (duration ?? 0))
                let bd = abs((b["duration"] as? Double ?? duration ?? 0) - (duration ?? 0))
                return ad < bd
            }
            guard let best = ordered.first,
                  duration == nil || abs((best["duration"] as? Double ?? duration!) - duration!) < 12 else {
                completion(.success(Response(timed: [], plain: nil)))
                return
            }
            let timed = LyricsParser.timed(best["syncedLyrics"] as? String ?? "")
            let plain = best["plainLyrics"] as? String
            completion(.success(Response(timed: timed, plain: plain)))
        }.resume()
    }
}

enum NeteaseLyricSource {
    static func cachedSongID(title: String, artist: String, duration: Double?,
                             databaseURL: URL? = nil) -> String? {
        let url = databaseURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.netease.163music/Documents/storage/sqlite_storage.sqlite3")
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let database else { return nil }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database,
            "SELECT id, jsonStr FROM dbTrack WHERE jsonStr LIKE ? LIMIT 40", -1,
            &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        let pattern = "%" + title + "%"
        _ = pattern.withCString { pointer in
            sqlite3_bind_text(statement, 1, pointer, -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        var matches: [(id: String, score: Int)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idPointer = sqlite3_column_text(statement, 0),
                  let jsonPointer = sqlite3_column_text(statement, 1) else { continue }
            let id = String(cString: idPointer)
            guard !id.isEmpty, id.allSatisfy(\.isNumber),
                  let data = String(cString: jsonPointer).data(using: .utf8),
                  let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  row["name"] as? String == title else { continue }
            let trackDuration = (row["duration"] as? NSNumber)?.doubleValue ?? 0
            if let duration, trackDuration > 0,
               abs(trackDuration / 1000 - duration) > 12 { continue }
            let artists = (row["artists"] as? [[String: Any]] ?? [])
                .compactMap { $0["name"] as? String }
            let artistMatch = artists.contains {
                artist.localizedCaseInsensitiveContains($0) ||
                $0.localizedCaseInsensitiveContains(artist)
            }
            matches.append((id, artistMatch ? 2 : 1))
        }
        let ranked = matches.sorted { $0.score > $1.score }
        guard let first = ranked.first,
              ranked.count == 1 || first.score > ranked[1].score else { return nil }
        return first.id
    }

    static func fetch(id: String,
                      completion: @escaping (Result<LyricsService.Response, Error>) -> Void) {
        guard !id.isEmpty, id.allSatisfy(\.isNumber) else {
            completion(.failure(NSError(domain: "NeteaseLyricSource", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "歌曲标识无效"])))
            return
        }
        var parts = URLComponents(string: "https://music.163.com/api/song/lyric")!
        parts.queryItems = [URLQueryItem(name: "id", value: id),
                            URLQueryItem(name: "lv", value: "1"),
                            URLQueryItem(name: "tv", value: "-1")]
        var request = URLRequest(url: parts.url!)
        request.timeoutInterval = 12
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { completion(.failure(error)); return }
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200, let data,
                  let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let lrc = body["lrc"] as? [String: Any],
                  let source = lrc["lyric"] as? String else {
                completion(.failure(NSError(domain: "NeteaseLyricSource", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "网易云歌词不可用"])))
                return
            }
            let lines = LyricsParser.timed(source)
            completion(.success(LyricsService.Response(timed: lines,
                plain: lines.isEmpty ? source : nil)))
        }.resume()
    }
}
