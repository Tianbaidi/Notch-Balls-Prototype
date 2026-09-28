import Foundation

struct LyricCandidate: Identifiable {
    let id: String
    let source: String
    let title: String
    let artist: String
    let album: String
    let duration: Double?
    let response: LyricsService.Response
    let score: Double
    var requiresConfirmation: Bool { score < 100 }
    var label: String {
        let record = album.isEmpty ? title : album
        let seconds = Int(duration ?? 0)
        let length = seconds > 0 ? String(format: " · %d:%02d", seconds / 60, seconds % 60) : " · 时长未标注"
        return "\(source) · \(record) · \(artist)" + length
    }
}

struct LyricQuery {
    let title: String
    let artist: String
    let album: String
    let duration: Double?

    static func normalize(_ value: String) -> String {
        let simplified = value.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? value
        return simplified.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { $0.isLetter || $0.isNumber }
    }

    static func canonicalArtist(_ value: String) -> String {
        let key = normalize(value)
        if let custom = UserDefaults.standard.dictionary(forKey: "notch.music.artistAliases.v1")?[key] as? String,
           !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return custom }
        if let verified = UserDefaults.standard.dictionary(forKey: "notch.music.verifiedArtistNames.v1")?[key] as? [String],
           let preferred = verified.first { return preferred }
        // Apple Music's English display name for the artist identified in this session.
        let builtIn = ["lotayou": "罗大佑", "lodayu": "罗大佑", "luodayou": "罗大佑"]
        return builtIn[key] ?? value
    }

    var searchArtist: String { Self.canonicalArtist(artist) }

    static func cleanTitle(_ value: String) -> String {
        value.replacingOccurrences(of: #"(?i)\s*(?:[\(（\[][^\)）\]]*(?:remaster|重制|重製)[^\)）\]]*[\)）\]]|[-–—]\s*(?:\d{4}\s*)?remaster(?:ed)?(?:\s*\d{4})?)\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var searchTitle: String { Self.cleanTitle(title) }

    static func artistEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        let a = canonicalArtist(lhs), b = canonicalArtist(rhs)
        if normalize(a) == normalize(b) { return true }
        func parts(_ name: String) -> [String] {
            let split = name.replacingOccurrences(of: #"(?i)\s+(?:feat\.?|ft\.?|featuring)\s+|[;/、&，,]|[\(（\)）]"#, with: "|", options: .regularExpression)
            return split.components(separatedBy: "|").map(normalize).filter { !$0.isEmpty }
        }
        if !Set(parts(a)).isDisjoint(with: Set(parts(b))) { return true }
        return false
    }

    static func artistPhoneticEquivalent(_ a: String, _ b: String) -> Bool {
        func latin(_ name: String) -> String {
            normalize(name.applyingTransform(.toLatin, reverse: false) ?? name)
        }
        let ac = a.unicodeScalars.contains { (0x3400...0x9fff).contains(Int($0.value)) }
        let bc = b.unicodeScalars.contains { (0x3400...0x9fff).contains(Int($0.value)) }
        return ac != bc && !latin(a).isEmpty && latin(a) == latin(b)
    }

    func score(title candidate: String, artist singer: String, album record: String,
               duration length: Double?, allowUncertain: Bool = false) -> Double? {
        let a = Self.normalize(Self.cleanTitle(title)), b = Self.normalize(Self.cleanTitle(candidate))
        guard !a.isEmpty, a == b else { return nil }
        let artistMatches = Self.artistEquivalent(artist, singer)
        let phoneticMatch = Self.artistPhoneticEquivalent(artist, singer)
        let sameAlbum = !album.isEmpty && !record.isEmpty && Self.normalize(album) == Self.normalize(record)
        var difference: Double?
        if let duration, duration > 0, let length, length > 0 {
            difference = abs(duration - length)
            guard difference! <= 12 else { return nil }
        }
        guard artistMatches || (allowUncertain && (difference != nil || sameAlbum || phoneticMatch)) else { return nil }
        var result = artistMatches ? 100.0 : 35.0
        if let difference { result += 30 - difference * 2 }
        if sameAlbum { result += 15 }
        if !artistMatches && phoneticMatch { result += 10 }

        return result
    }
}

struct LyricSearchResults {
    var candidates: [LyricCandidate]
    var failedSources: [String]
}

enum MultiLyricsService {
    static func fetch(query: LyricQuery, includeExtraSources: Bool, includeIndependentSource: Bool = false, includeLRCLIB: Bool = true, includeArtistLookup: Bool = false,
                      completion: @escaping (LyricSearchResults) -> Void) {
        Task {
            var result = await primary(query, extras: includeExtraSources, lrclib: includeLRCLIB, broad: false)
            if !result.candidates.contains(where: { !$0.requiresConfirmation }) {
                if includeArtistLookup && query.searchArtist == query.artist {
                    let aliases = await ArtistAliasResolver.shared.resolve(query.artist)
                    for artist in aliases.filter({ LyricQuery.normalize($0) != LyricQuery.normalize(query.artist) }).prefix(2) {
                        let alternative = LyricQuery(title: query.title, artist: artist, album: query.album, duration: query.duration)
                        let found = await primary(alternative, extras: includeExtraSources, lrclib: includeLRCLIB, broad: false)
                        result = merge([result, found])
                        if includeIndependentSource && !found.candidates.contains(where: { !$0.requiresConfirmation }) {
                            let vv = await checked("VV 歌词") { try await searchVV(alternative) }
                            result = merge([result, vv])
                        }
                        if result.candidates.contains(where: { !$0.requiresConfirmation }) { break }
                    }
                }
                if !result.candidates.contains(where: { !$0.requiresConfirmation }) {
                    let broader = await primary(query, extras: includeExtraSources, lrclib: includeLRCLIB, broad: true)
                    result = merge([result, broader])
                }
            }
            if !result.candidates.contains(where: { !$0.requiresConfirmation }) && includeIndependentSource {
                let fallback = await checked("VV 歌词") { try await searchVV(query) }
                result = merge([result, fallback])
            }
            completion(result)
        }
    }

    private static func primary(_ query: LyricQuery, extras: Bool, lrclib: Bool, broad: Bool) async -> LyricSearchResults {
        async let lrc = lrclib ? checked("LRCLIB") { try await searchLRCLIB(query, broad: broad) } : LyricSearchResults(candidates: [], failedSources: [])
        if extras {
            async let qq = checked("QQ 歌词") { try await searchQQ(query, broad: broad) }
            async let kg = checked("酷狗歌词") { try await searchKugou(query, broad: broad) }
            return merge(await [lrc, qq, kg])
        }
        return merge(await [lrc])
    }

    private static func checked(_ source: String, operation: () async throws -> [LyricCandidate]) async -> LyricSearchResults {
        do { return LyricSearchResults(candidates: try await operation(), failedSources: []) }
        catch { return LyricSearchResults(candidates: [], failedSources: [source]) }
    }

    private static func merge(_ results: [LyricSearchResults]) -> LyricSearchResults {
        var unique: [String: LyricCandidate] = [:]
        for candidate in results.flatMap(\.candidates) {
            if candidate.score > (unique[candidate.id]?.score ?? -1) { unique[candidate.id] = candidate }
        }
        return LyricSearchResults(candidates: unique.values.sorted {
            if $0.requiresConfirmation != $1.requiresConfirmation { return !$0.requiresConfirmation }
            let a = $0.score + ($0.response.timed.isEmpty ? 0 : 20)
            let b = $1.score + ($1.response.timed.isEmpty ? 0 : 20)
            return a == b ? $0.id < $1.id : a > b
        }, failedSources: Array(Set(results.flatMap(\.failedSources))).sorted())
    }

    private static func json(_ base: String, _ parameters: [String: String], referer: String? = nil) async throws -> Any {
        var components = URLComponents(string: base)!
        components.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 10
        request.setValue("NotchBallsPrototype/0.20 (macOS)", forHTTPHeaderField: "User-Agent")
        if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "LyricsSources", code: 1)
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func make(id: String, source: String, title: String, artist: String, album: String = "",
                             duration: Double?, text: String, plain: String? = nil, query: LyricQuery, broad: Bool = false) -> LyricCandidate? {
        guard let score = query.score(title: title, artist: artist, album: album, duration: duration, allowUncertain: broad) else { return nil }
        let timed = LyricsParser.timed(text)
        let plainText = plain ?? (timed.isEmpty ? text : nil)
        guard !timed.isEmpty || !(plainText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) else { return nil }
        return LyricCandidate(id: source + ":" + id, source: source, title: title, artist: artist,
                              album: album, duration: duration,
                              response: LyricsService.Response(timed: timed, plain: plainText), score: score)
    }

    private static func searchLRCLIB(_ query: LyricQuery, broad: Bool = false) async throws -> [LyricCandidate] {
        guard let records = try await json("https://lrclib.net/api/search", (broad ? ["track_name": query.searchTitle] : ["track_name": query.searchTitle, "artist_name": query.searchArtist])) as? [[String: Any]] else {
            throw NSError(domain: "LRCLIB", code: 1)
        }
        return records.compactMap { row in
            make(id: String(describing: row["id"] ?? ""), source: "LRCLIB",
                 title: row["trackName"] as? String ?? "", artist: row["artistName"] as? String ?? "",
                 album: row["albumName"] as? String ?? "", duration: (row["duration"] as? NSNumber)?.doubleValue,
                 text: row["syncedLyrics"] as? String ?? "", plain: row["plainLyrics"] as? String, query: query, broad: broad)
        }.sorted { $0.score > $1.score }.prefix(12).map { $0 }
    }

    private static func searchQQ(_ query: LyricQuery, broad: Bool = false) async throws -> [LyricCandidate] {
        guard let body = try await json("https://c.y.qq.com/soso/fcgi-bin/client_search_cp",
            ["w": broad ? query.searchTitle : query.searchTitle + " " + query.searchArtist, "format": "json", "p": "1", "n": broad ? "30" : "8"]) as? [String: Any],
              (body["code"] as? Int) == 0,
              let data = body["data"] as? [String: Any], let song = data["song"] as? [String: Any],
              let rows = song["list"] as? [[String: Any]] else { throw NSError(domain: "QQ", code: 1) }
        var result: [LyricCandidate] = []
        let matched = rows.filter { row in
            let artist = (row["singer"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: " / ")
            return query.score(title: row["songname"] as? String ?? "", artist: artist,
                               album: row["albumname"] as? String ?? "", duration: (row["interval"] as? NSNumber)?.doubleValue, allowUncertain: broad) != nil
        }
        for row in matched.prefix(3) {
            guard let mid = row["songmid"] as? String else { continue }
            let lyrics = try await json("https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg",
                ["songmid": mid, "g_tk": "5381", "format": "json", "nobase64": "1"], referer: "https://y.qq.com/portal/player.html") as? [String: Any]
            guard let lyrics, (lyrics["retcode"] as? Int) == 0, let raw = lyrics["lyric"] as? String else { continue }
            let text = decodeEntities(raw)
            let artist = (row["singer"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: " / ")
            if let candidate = make(id: mid, source: "QQ 歌词", title: row["songname"] as? String ?? "",
                artist: artist, album: row["albumname"] as? String ?? "", duration: (row["interval"] as? NSNumber)?.doubleValue,
                text: text, query: query, broad: broad) { result.append(candidate) }
        }
        return result
    }

    private static func searchKugou(_ query: LyricQuery, broad: Bool = false) async throws -> [LyricCandidate] {
        guard let body = try await json("https://lyrics.kugou.com/search",
            ["keyword": broad ? query.searchTitle : query.searchTitle + " " + query.searchArtist, "duration": String(Int((query.duration ?? 0) * 1000)),
             "client": "pc", "ver": "1", "man": "yes"]) as? [String: Any],
              (body["status"] as? Int) == 200, let rows = body["candidates"] as? [[String: Any]] else {
            throw NSError(domain: "Kugou", code: 1)
        }
        var result: [LyricCandidate] = []
        let matched = rows.filter { row in
            query.score(title: row["song"] as? String ?? "", artist: row["singer"] as? String ?? "", album: "",
                        duration: (row["duration"] as? NSNumber).map { $0.doubleValue / 1000 }, allowUncertain: broad) != nil
        }
        for row in matched.prefix(3) {
            guard let id = row["id"] as? String, let key = row["accesskey"] as? String else { continue }
            let lyrics = try await json("https://lyrics.kugou.com/download",
                ["id": id, "accesskey": key, "fmt": "lrc", "charset": "utf8", "client": "pc", "ver": "1"]) as? [String: Any]
            guard let encoded = lyrics?["content"] as? String,
                  let data = Data(base64Encoded: encoded), let text = String(data: data, encoding: .utf8) else { continue }
            if let candidate = make(id: id, source: "酷狗歌词", title: row["song"] as? String ?? "",
                artist: row["singer"] as? String ?? "", duration: (row["duration"] as? NSNumber).map { $0.doubleValue / 1000 },
                text: text, query: query, broad: broad) { result.append(candidate) }
        }
        return result
    }

    static func parseVVPage(_ html: String, query: LyricQuery) -> Bool {
        // Match structured breadcrumb metadata, not arbitrary visible lyric text.
        guard let regex = try? NSRegularExpression(pattern: #"<script[^>]*type=["']application/ld\+json["'][^>]*>(.*?)</script>"#, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return false }
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range(at: 1), in: html),
                  let data = String(html[range]).data(using: .utf8),
                  let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  body["@type"] as? String == "BreadcrumbList",
                  let items = body["itemListElement"] as? [[String: Any]] else { continue }
            let names = items.compactMap { ($0["item"] as? [String: Any])?["name"] as? String }
            guard names.count >= 3 else { continue }
            return query.score(title: names[2], artist: names[1], album: "", duration: nil) != nil
        }
        return false
    }

    private static func vvData(_ url: URL) async throws -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("NotchBallsPrototype/0.20 (macOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NSError(domain: "VV", code: 1) }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200, data.count <= 1_000_000 else { throw NSError(domain: "VV", code: http.statusCode) }
        return data
    }

    private static func searchVV(_ query: LyricQuery) async throws -> [LyricCandidate] {
        func simplified(_ value: String) -> String {
            (value.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? value)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Direct lyric pages avoid downloading a song catalog or audio.
        let url = URL(string: "https://vvlyrics.com/artist")!
            .appendingPathComponent(simplified(query.searchArtist))
            .appendingPathComponent(simplified(query.searchTitle))
        guard let data = try await vvData(url), let html = String(data: data, encoding: .utf8),
              parseVVPage(html, query: query) else { return [] }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "download", value: "1")]
        guard let data = try await vvData(parts.url!), let text = String(data: data, encoding: .utf8),
              !text.lowercased().contains("<html") else { return [] }
        // Verify downloaded metadata too, so a redirect cannot silently choose another song.
        func tag(_ name: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: "\\[" + name + ":([^\\]]*)\\]", options: .caseInsensitive),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let title = tag("ti"), let artist = tag("ar"),
              let candidate = make(id: url.absoluteString, source: "VV 歌词", title: title, artist: artist,
                                   duration: nil, text: text, query: query) else { return [] }
        if let duration = query.duration, duration > 0,
           (candidate.response.timed.last?.time ?? 0) > duration + 12 { return [] }
        return [candidate]
    }

    static func decodeEntities(_ value: String) -> String {
        var output = value
        if let regex = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);") {
            for match in regex.matches(in: output, range: NSRange(output.startIndex..., in: output)).reversed() {
                guard let digits = Range(match.range(at: 1), in: output), let full = Range(match.range, in: output) else { continue }
                let code = String(output[digits])
                let number = code.hasPrefix("x") ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
                if let number, let scalar = UnicodeScalar(number) { output.replaceSubrange(full, with: String(scalar)) }
            }
        }
        for (entity, text) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&amp;", "&")] {
            output = output.replacingOccurrences(of: entity, with: text)
        }
        return output
    }
}
