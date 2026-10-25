import Foundation

/// Maakt IPTV-titels schoon ("NL - The Batman (2022) [4K]" → "The Batman", 2022)
/// en herkent afleveringen ("Breaking Bad S01 E02").
enum TitleCleaner {
    struct Parsed { var title: String; var year: Int?; var season: Int?; var episode: Int? }

    private static let prefix = try! NSRegularExpression(pattern: #"^\s*(\|[^|]{1,12}\||\[[^\]]{1,12}\]|[A-Z]{2,4}\s*[-:|]\s+)"#)
    private static let episode = try! NSRegularExpression(pattern: #"[Ss](\d{1,2})\s*[Ee](\d{1,3})"#)
    private static let year = try! NSRegularExpression(pattern: #"[\(\[\s-](19\d{2}|20\d{2})[\)\]]?"#)
    private static let junk = try! NSRegularExpression(
        pattern: #"(?i)\b(4k|uhd|fhd|hd|sd|hevc|h\.?265|x265|x264|1080p|720p|2160p|multi|subs?|nl ?sub|vost\w*|dolby|atmos|hdr10?\+?|dv)\b|\[[^\]]*\]|\([^\)]*\)"#)

    static func parse(_ raw: String) -> Parsed {
        // taallabels ("Animal (IT)", "EN-Animal", "NL SUBS") eerst weg, met dezelfde regels als de covers (build 59)
        // build 150: andere pipe-tekens ("¦", "│", "｜") als "|", zoals bij de categorieën
        var s = ContentLanguage.displayTitle(CategoryName.normalizeSeparators(raw))
        // landcodes/labels vooraan weg (eventueel meerdere)
        for _ in 0..<2 { s = replace(prefix, in: s, with: "") }

        var season: Int?, ep: Int?
        if let m = episode.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) {
            season = Int(sub(s, m.range(at: 1))); ep = Int(sub(s, m.range(at: 2)))
            if let r = Range(m.range, in: s) { s = String(s[..<r.lowerBound]) }
        }

        var y: Int?
        let matches = year.matches(in: s, range: NSRange(s.startIndex..., in: s))
        if let m = matches.last {
            y = Int(sub(s, m.range(at: 1)))
            if let r = Range(m.range, in: s) { s.removeSubrange(r) }
        }

        s = replace(junk, in: s, with: " ")
        s = s.replacingOccurrences(of: "_", with: " ")
             .replacingOccurrences(of: ".", with: " ")
             .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
             .trimmingCharacters(in: CharacterSet(charactersIn: " -|:"))
        return Parsed(title: s.isEmpty ? raw : s, year: y, season: season, episode: ep)
    }

    private static func replace(_ re: NSRegularExpression, in s: String, with t: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: t)
    }
    private static func sub(_ s: String, _ r: NSRange) -> String {
        guard let rr = Range(r, in: s) else { return "" }; return String(s[rr])
    }
}
