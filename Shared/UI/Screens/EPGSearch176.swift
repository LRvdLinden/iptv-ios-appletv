import SwiftUI

/// Build 176: zoeken in de beschrijvingen van de tv-gids (nu tot 7 dagen vooruit), op de achtergrond met een index van
/// genormaliseerde tekst (`Build176.foldString`). De index wordt één keer per gids gebouwd en bewaard; zoeken loopt
/// daarna over platte tekst, zodat het vlot blijft bij 50.000 programma's. Regels: docs/ACCOUNT.md → "Build 176" (5).
enum EPGSearch176 {
    struct Entry: Sendable {
        let channel: Int
        let program: EPGProgram
        let title: String
        let desc: String
    }

    struct Hit: Identifiable {
        var id: String { channel.id + "|" + program.id }
        let channel: Channel
        let program: EPGProgram
        let match: Build176.EPGMatch
    }

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var key = ""
        var built: Date = .distantPast
        var entries: [Entry] = []
    }
    private static let cache = Cache()

    /// Sleutel van de gids: zenders, aantal lijsten en de eerste/laatste zender (goedkoop te berekenen)
    private static func key(_ lib: Library) -> String {
        "\(lib.channels.count)|\(lib.epg.count)|\(lib.channels.first?.id ?? "")|\(lib.channels.last?.id ?? "")|\(lib.epg.values.reduce(0) { $0 + $1.count })"
    }

    private static func entries(_ lib: Library, now: Date) -> [Entry] {
        let k = key(lib)
        cache.lock.lock()
        if cache.key == k, now.timeIntervalSince(cache.built) < 1800 {
            let e = cache.entries
            cache.lock.unlock()
            return e
        }
        cache.lock.unlock()
        let until = now.addingTimeInterval(7 * 86400)
        var out: [Entry] = []
        out.reserveCapacity(20_000)
        for (i, c) in lib.channels.enumerated() {
            guard let list = lib.epg[c.epgID ?? c.id] else { continue }
            for p in list where p.end > now && p.start < until {
                out.append(Entry(channel: i, program: p, title: Build176.foldString(p.title),
                                 desc: Build176.foldString(p.description ?? "")))
            }
        }
        cache.lock.lock()
        cache.key = k; cache.built = now; cache.entries = out
        cache.lock.unlock()
        return out
    }

    /// Programma's waarvan alleen de beschrijving past (titeltreffers staan al bij "TV guide"), max. 100; één per
    /// (zender, start), op starttijd.
    static func search(_ q: String, in lib: Library) async -> [Hit] {
        let words = Build176.queryWords(q)
        guard !words.isEmpty else { return [] }
        return await Task.detached(priority: .userInitiated) { () -> [Hit] in
            let now = Date()
            let all = entries(lib, now: now)
            var found: [(Entry, Build176.Field)] = []
            for e in all {
                if Task.isCancelled { return [] }
                if let f = Build176.epgField(words: words, title: e.title, desc: e.desc), f == .description { found.append((e, f)) }
            }
            found.sort { $0.0.program.start != $1.0.program.start ? $0.0.program.start < $1.0.program.start : $0.0.channel < $1.0.channel }
            var seen = Set<String>()
            var hits: [Hit] = []
            for (e, _) in found {
                let c = lib.channels[e.channel]
                guard seen.insert(c.id + "|\(e.program.start.timeIntervalSince1970)").inserted else { continue }
                guard let m = Build176.epgMatch(q, title: e.program.title, desc: e.program.description) else { continue }
                hits.append(Hit(channel: c, program: e.program, match: m))
                if hits.count >= 100 { break }
            }
            return hits
        }.value
    }

    /// Stukje beschrijving met het gevonden woord gemarkeerd
    static func snippet(_ h: Hit) -> AttributedString {
        let text = h.program.description ?? ""
        let chars = Array(text)
        guard let r = h.match.range, r.upperBound <= chars.count else { return AttributedString(Build176.snippet(text, around: nil)) }
        let width = 90
        let start = chars.count > width ? max(0, min(r.lowerBound - width / 3, chars.count - width)) : 0
        let end = min(chars.count, start + max(width, r.count))
        var out = AttributedString(start > 0 ? "…" : "")
        out += AttributedString(String(chars[start..<max(start, r.lowerBound)]))
        var hl = AttributedString(String(chars[max(start, r.lowerBound)..<min(end, r.upperBound)]))
        hl.swiftUI.foregroundColor = .white
        hl.swiftUI.font = .system(size: tvScaled(12), weight: .bold)
        out += hl
        out += AttributedString(String(chars[min(end, r.upperBound)..<end]))
        if end < chars.count { out += AttributedString("…") }
        return out
    }
}

/// Sectie "In de tv-gids" in Zoeken: treffers in de programmabeschrijving, met het gevonden woord gemarkeerd
struct EPGDescriptionHits: View {
    let hits: [EPGSearch176.Hit]
    let open: (Channel, EPGProgram) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("In the TV guide")).font(Theme.titleFont).padding(.leading, Theme.edge)
            LazyVStack(spacing: 4) {
                ForEach(hits) { h in
                    Button { open(h.channel, h.program) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            RemoteImage(url: h.channel.logo, contentMode: .fit, placeholder: String(h.channel.name.prefix(3)))
                                .frame(width: tvScaled(56), height: tvScaled(36))
                                .background(Theme.card, in: RoundedRectangle(cornerRadius: 4))
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    if h.program.isNow {
                                        Text(L("NOW")).font(.system(size: tvScaled(10), weight: .heavy)).foregroundStyle(Theme.red)
                                    }
                                    Text(CategoryName.display(h.program.title)).font(.system(size: tvScaled(14), weight: .semibold)).lineLimit(1)
                                }
                                Text(EPGSearch176.snippet(h))
                                    .font(.system(size: tvScaled(12))).foregroundStyle(Theme.secondary).lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Text("\(h.channel.name) · \(h.program.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))")
                                    .font(.system(size: tvScaled(11))).foregroundStyle(Theme.secondary).lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, Theme.edge).padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .plainTVButton()
                }
            }
        }
    }
}
