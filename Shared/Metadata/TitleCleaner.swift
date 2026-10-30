import Foundation

/// Maakt IPTV-titels schoon ("NL - The Batman (2022) [4K]" → "The Batman", 2022)
/// en herkent afleveringen ("Breaking Bad S01 E02").
enum TitleCleaner {
    struct Parsed { var title: String; var year: Int?; var season: Int?; var episode: Int? }

    private static let episode = try! NSRegularExpression(pattern: #"[Ss](\d{1,2})\s*[Ee](\d{1,3})"#)
    private static let junk = try! NSRegularExpression(
        // build 154: "Multi", "Sub" en "VOST" alleen in hoofdletters ("Sub Zero" blijft heel)
        pattern: #"(?i)\b(4k|uhd|fhd|hd|sd|hevc|h\.?265|x265|x264|1080p|720p|2160p|dolby|atmos|hdr10?\+?|dv)\b|\b(?-i:MULTI|SUBS?|NL ?SUBS?|VOST[A-Z]*)\b|\[[^\]]*\]|\([^\)]*\)"#)

    static func parse(_ raw: String) -> Parsed {
        // taallabels ("Animal (IT)", "EN-Animal", "NL SUBS") eerst weg, met dezelfde regels als de covers (build 59)
        // build 150: andere pipe-tekens ("¦", "│", "｜") als "|", zoals bij de categorieën
        // build 153: alle pipe-varianten uit `CategoryName.pipes`; stukken tussen pipes vooraan/achteraan haalt
        // `ContentLanguage.displayTitle` weg (`CategoryName.pipeBlocks`)
        var s = ContentLanguage.displayTitle(CategoryName.normalizeSeparators(raw))
        // landcodes/labels vooraan weg (eventueel meerdere). Build 154: alleen een taal-/landcode, kwaliteitswoord of
        // IPTV-woord ("NCIS: Hawaii", "FBI: Most Wanted" en "BBC - Planet Earth" blijven heel)
        s = TitleRules154.stripPrefixes(s)

        var season: Int?, ep: Int?
        if let m = episode.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) {
            season = Int(sub(s, m.range(at: 1))); ep = Int(sub(s, m.range(at: 2)))
            if let r = Range(m.range, in: s) { s = String(s[..<r.lowerBound]) }
        }

        // build 154: een jaartal alleen tussen haakjes/blokhaken of achter "-"/"|" (1900 … volgend jaar);
        // "Blade Runner 2049" en "1917" blijven heel
        let yr = TitleRules154.extractYear(s)
        let y = yr.year
        s = yr.title

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
