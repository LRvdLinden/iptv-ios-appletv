import Foundation

/// Build 194: terugkijken via een tweeling (zie `Build194.twins`). Heeft een zender zelf geen terugkijken maar een gelijke
/// zender op dezelfde server wel, dan krijgt de eerste de terugkijkgegevens van de tweeling (`catchupDays`, type,
/// bron, `catchupVia`); live kijken blijft op de originele zender. Idempotent: al gekoppelde zenders blijven zoals ze zijn.
extension Library {
    func linkingCatchupTwins() -> Library {
        guard channels.contains(where: { $0.catchupDays > 0 && $0.catchupVia == nil }),
              channels.contains(where: { $0.catchupDays == 0 && $0.catchupVia == nil }) else { return self }
        let inputs = channels.filter { $0.catchupVia == nil }
            .map { Build194.TwinInput(id: $0.id, name: $0.name, epg: $0.epgID, days: $0.catchupDays, server: "") }
        let matches = Build194.twins(inputs)
        guard !matches.isEmpty else { return self }
        var twinOf: [String: String] = [:]
        for m in matches { twinOf[m.id] = m.twin }
        var byID: [String: Channel] = [:]
        for c in channels where byID[c.id] == nil { byID[c.id] = c }
        var lib = self
        lib.channels = channels.map { c in
            guard c.catchupDays == 0, c.catchupVia == nil, let t = twinOf[c.id], let tw = byID[t] else { return c }
            var x = c
            x.catchupDays = tw.catchupDays
            x.catchupType = tw.catchupType
            x.catchupSource = tw.catchupSource
            x.catchupVia = tw.id
            x.catchupViaStream = tw.streamURL
            return x
        }
        return lib
    }
}
