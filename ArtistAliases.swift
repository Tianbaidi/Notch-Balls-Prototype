import Foundation

actor ArtistAliasResolver {
    static let shared = ArtistAliasResolver()
    private var nextRequest = Date.distantPast
    private var misses: [String: Date] = [:]

    static func exactArtists(_ records: [[String: Any]], input: String) -> [[String: Any]] {
        let key = LyricQuery.normalize(input)
        let primary = records.filter { LyricQuery.normalize($0["name"] as? String ?? "") == key }
        if !primary.isEmpty { return primary }
        return records.filter { record in
            let names = [record["name"] as? String ?? ""] +
                (record["aliases"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            return names.contains { LyricQuery.normalize($0) == key }
        }
    }

    static func validatedNames(_ record: [String: Any], input: String) -> [String] {
        guard !exactArtists([record], input: input).isEmpty else { return [] }
        let names = [record["name"] as? String ?? ""] +
            (record["aliases"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        var seen = Set<String>()
        return names.filter { !$0.isEmpty && seen.insert(LyricQuery.normalize($0)).inserted }
            .sorted { a, b in
                let ac = a.unicodeScalars.contains { (0x3400...0x9fff).contains(Int($0.value)) }
                let bc = b.unicodeScalars.contains { (0x3400...0x9fff).contains(Int($0.value)) }
                return ac == bc ? a < b : ac
            }
    }

    private func json(_ path: String, parameters: [String: String]) async throws -> [String: Any] {
        let reservation = max(Date(), nextRequest)
        nextRequest = reservation.addingTimeInterval(1.1)
        let delay = reservation.timeIntervalSinceNow
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        guard UserDefaults.standard.bool(forKey: "notch.music.artistLookup.v1") else {
            throw CancellationError()
        }
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/" + path)!
        components.queryItems = (parameters.merging(["fmt": "json"]) { a, _ in a }).map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 10
        request.setValue("NotchBallsPrototype/0.20 (macOS personal prototype)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "ArtistAliases", code: 1)
        }
        return result
    }

    func resolve(_ input: String) async -> [String] {
        guard UserDefaults.standard.bool(forKey: "notch.music.artistLookup.v1") else { return [] }
        let key = LyricQuery.normalize(input)
        if let cache = UserDefaults.standard.dictionary(forKey: "notch.music.verifiedArtistNames.v1")?[key] as? [String] { return cache }
        if let miss = misses[key], Date().timeIntervalSince(miss) < 3600 { return [] }
        do {
            let escaped = input.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let search = try await json("artist/", parameters: ["query": "artist:\"\(escaped)\" OR alias:\"\(escaped)\"", "limit": "10"])
            let matches = Self.exactArtists(search["artists"] as? [[String: Any]] ?? [], input: input)
            // Identical names can refer to different people; never guess an identity.
            guard matches.count == 1, let id = matches.first?["id"] as? String,
                  UUID(uuidString: id) != nil else { misses[key] = Date(); return [] }
            let details = try await json("artist/" + id, parameters: ["inc": "aliases"])
            let names = Self.validatedNames(details, input: input)
            if !names.isEmpty && UserDefaults.standard.bool(forKey: "notch.music.artistLookup.v1") {
                var cache = UserDefaults.standard.dictionary(forKey: "notch.music.verifiedArtistNames.v1") ?? [:]
                cache[key] = names
                UserDefaults.standard.set(cache, forKey: "notch.music.verifiedArtistNames.v1")
            }
            return names
        } catch { return [] }
    }
}
