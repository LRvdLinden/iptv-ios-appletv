import Foundation

/// Leest M3U/M3U8-playlists (inclusief Xtream-achtige get.php-lijsten) en
/// verdeelt ze in Live TV, Films en Series.
enum M3UParser {
    struct Entry {
        var name: String
        var attrs: [String: String]
        var url: String
        var duration: Int
    }

    private static let attrRegex = try! NSRegularExpression(pattern: #"([\w-]+)="([^"]*)""#)

    static func entries(from text: String) -> [Entry] {
        var out: [Entry] = []
        out.reserveCapacity(4096)
        var pending: (String, [String: String], Int)?
        var groupOverride: String?

        text.enumerateLines { raw, _ in
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { return }
            if line.hasPrefix("#EXTINF") {
                let commaIdx = lastTopLevelComma(line)
                let header = commaIdx.map { String(line[..<$0]) } ?? line
                let name = commaIdx.map { String(line[line.index(after: $0)...]).trimmingCharacters(in: .whitespaces) } ?? ""
                var attrs: [String: String] = [:]
                let ns = header as NSString
                for m in attrRegex.matches(in: header, range: NSRange(location: 0, length: ns.length)) {
                    attrs[ns.substring(with: m.range(at: 1)).lowercased()] = ns.substring(with: m.range(at: 2))
                }
                let durStr = header.replacingOccurrences(of: "#EXTINF:", with: "").split(separator: " ").first ?? "-1"
                pending = (name.isEmpty ? (attrs["tvg-name"] ?? "Onbekend") : name, attrs, Int(durStr) ?? -1)
            } else if line.hasPrefix("#EXTGRP:") {
                groupOverride = String(line.dropFirst(8))
            } else if line.hasPrefix("#") {
                return
            } else if let p = pending {
                var attrs = p.1
                if attrs["group-title"] == nil, let g = groupOverride { attrs["group-title"] = g }
                out.append(Entry(name: p.0, attrs: attrs, url: line, duration: p.2))
                pending = nil; groupOverride = nil
            }
        }
        return out
    }

    /// Komma ná de laatste attribuut-quote (titels mogen zelf komma's bevatten).
    private static func lastTopLevelComma(_ s: String) -> String.Index? {
        var inQuote = false
        for i in s.indices {
            let ch = s[i]
            if ch == "\"" { inQuote.toggle() }
            else if ch == "," && !inQuote { return i }
        }
        return nil
    }

    static func library(from text: String, playlistID: UUID) -> Library {
        var lib = Library()
        var seriesMap: [String: Series] = [:]
        var seriesOrder: [String] = []
        var number = 0

        for e in entries(from: text) {
            let group = e.attrs["group-title"].flatMap { $0.isEmpty ? nil : $0 } ?? "Overig"
            let logo = e.attrs["tvg-logo"]?.urlValue
            let lowerURL = e.url.lowercased()
            let parsed = TitleCleaner.parse(e.name)
            let id = "\(playlistID.uuidString.prefix(8))-\(stableHash(e.url))"

            let looksSeries = lowerURL.contains("/series/") || (parsed.season != nil && parsed.episode != nil)
            let looksMovie = !looksSeries && (lowerURL.contains("/movie/") ||
                lowerURL.hasSuffix(".mkv") || lowerURL.hasSuffix(".mp4") || lowerURL.hasSuffix(".avi"))

            if looksSeries {
                let sKey = parsed.title.lowercased()
                if seriesMap[sKey] == nil {
                    seriesMap[sKey] = Series(id: "s-\(stableHash(group + sKey))", title: parsed.title, year: parsed.year,
                                             poster: logo, group: group)
                    seriesOrder.append(sKey)
                }
                let ep = Episode(id: id, seriesID: seriesMap[sKey]!.id, season: parsed.season ?? 1,
                                 number: parsed.episode ?? (seriesMap[sKey]!.episodes.count + 1),
                                 title: e.name, streamURL: e.url.urlValue, still: logo)
                seriesMap[sKey]!.episodes.append(ep)
            } else if looksMovie {
                lib.movies.append(Movie(id: id, title: parsed.title, year: parsed.year, poster: logo, group: group,
                                        streamURL: e.url.urlValue))
            } else {
                number += 1
                let catchup = Int(e.attrs["catchup-days"] ?? e.attrs["timeshift"] ?? "") ?? 0
                lib.channels.append(Channel(id: id, name: e.name, logo: logo, group: group,
                                            streamURL: e.url.urlValue,
                                            epgID: e.attrs["tvg-id"].flatMap { $0.isEmpty ? nil : $0 },
                                            number: Int(e.attrs["tvg-chno"] ?? "") ?? number,
                                            catchupDays: catchup))
            }
        }
        lib.series = seriesOrder.compactMap { seriesMap[$0] }.map {
            var s = $0; s.episodes.sort { ($0.season, $0.number) < ($1.season, $1.number) }; return s
        }
        return lib
    }

    static func epgURL(fromHeader text: String) -> URL? {
        guard let first = text.split(separator: "\n", maxSplits: 1).first, first.hasPrefix("#EXTM3U") else { return nil }
        let s = String(first)
        for key in ["url-tvg", "x-tvg-url", "tvg-url"] {
            if let r = s.range(of: "\(key)=\"") {
                let rest = s[r.upperBound...]
                if let end = rest.firstIndex(of: "\"") {
                    return String(rest[..<end]).split(separator: ",").first.map(String.init)?.urlValue
                }
            }
        }
        return nil
    }
}

/// Stabiele (niet-gerandomiseerde) hash zodat ID's tussen apparaten gelijk blijven.
func stableHash(_ s: String) -> String {
    var h: UInt64 = 0xcbf29ce484222325
    for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
    return String(h, radix: 36)
}
