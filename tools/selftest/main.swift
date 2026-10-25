// Zelftest van de pure logica van build 128 (Shared/Account/CatalogMeta.swift), los van de app gebouwd in CI:
//   swiftc -O Shared/Account/CatalogMeta.swift Shared/Account/Build140.swift tools/selftest/main.swift -o selftest && ./selftest
import Foundation

var failures = 0
var checks = 0
func check(_ ok: Bool, _ what: String, file: String = #file, line: Int = #line) {
    checks += 1
    if !ok { failures += 1; print("FOUT (regel \(line)): \(what)") }
}
func eq<T: Equatable>(_ a: T, _ b: T, _ what: String, line: Int = #line) {
    check(a == b, "\(what): verwacht \(b), kreeg \(a)", line: line)
}

// MARK: normaliseren

eq(CatalogNorm.title("NL | The Batman (2022) [4K]").norm, "thebatman", "titel met label, jaar en 4K")
eq(CatalogNorm.title("NL | The Batman (2022) [4K]").year, 2022, "jaar uit de titel")
eq(CatalogNorm.title("The Batman 2022").norm, "thebatman", "jaar achteraan zonder haken")
eq(CatalogNorm.title("|EN| Amélie").norm, "amelie", "accenten en |EN|")
eq(CatalogNorm.title("[NL] Breaking Bad S01E02").norm, "breakingbad", "afleveringsmarkering weg")
eq(CatalogNorm.title("1917").norm, "1917", "titel die een jaartal is")
eq(CatalogNorm.title("Blade Runner 2049 (2017)").year, 2017, "laatste jaar telt")
eq(CatalogNorm.title("Blade Runner 2049 (2017)").norm, "bladerunner2049", "jaartal in de titel blijft")
eq(CatalogNorm.title("Dune: Part Two - NL").norm, "duneparttwo", "taal achteraan")
eq(CatalogNorm.title("Animal (IT)").norm, "animal", "taal tussen haken")
eq(CatalogNorm.channel("NL: NPO 1 FHD"), "npo1", "zender NL: … FHD")
eq(CatalogNorm.channel("|NL| NPO1 HD"), "npo1", "zender |NL|")
eq(CatalogNorm.channel("NPO 1 (4K)"), "npo1", "zender (4K)")
eq(CatalogNorm.channel("NL | RTL 4 HEVC 50fps"), "rtl4", "zender HEVC 50fps")
eq(CatalogNorm.channel("[BE] Eén HD"), "een", "zender [BE] met accent")
eq(CatalogNorm.channel("Discovery NL"), "discovery", "landcode achteraan")
eq(CatalogNorm.channel("NL - Ziggo Sport 2 UHD"), "ziggosport2", "zender NL - …")
eq(CatalogNorm.epg(" NPO1.nl "), "npo1.nl", "epg-id")
check(CatalogNorm.seasonEpisode("S1:E2 · Pilot")! == (1, 2), "s/e uit S1:E2")
check(CatalogNorm.seasonEpisode("S01E10")! == (1, 10), "s/e uit S01E10")
check(CatalogNorm.seasonEpisode("S2:A5 · Titel")! == (2, 5), "s/e uit Nederlandse ondertitel S2:A5")

// MARK: sleutels

eq(CatalogKey.normalize("ABCD-EF|xv123"), "abcd-ef|xv123", "sleutel: server-id klein, item exact")
eq(CatalogKey.normalize("ABCD|Item-X"), "abcd|Item-X", "item-id blijft exact")
eq(CatalogKey.remapKey("ABCD|Item-X"), "abcd|item-x", "remap-sleutel helemaal klein")
let u = UUID()
eq(CatalogRemap.appForm(u.uuidString.lowercased() + "|x1"), u.uuidString + "|x1", "app-vorm: UUID in hoofdletters")

// MARK: remap-ketens

var m = CatalogMeta()
check(m.addRemap(from: "A|1", to: "B|1", at: 10), "regel a→b")
check(m.addRemap(from: "b|1", to: "C|1", at: 11), "regel b→c")
eq(m.resolve("a|1"), "C|1", "keten a→b→c (hoofdletterongevoelig)")
eq(m.resolve("A|1"), "C|1", "keten vanaf hoofdletters")
eq(m.resolve("C|1"), nil as String?, "eindpunt heeft geen remap")
check(!m.addRemap(from: "c|1", to: "A|1", at: 12), "lus c→a geweigerd")
eq(m.resolve("a|1"), "C|1", "keten na geweigerde lus")
check(!m.addRemap(from: "x|1", to: "X|1", at: 1), "naar zichzelf geweigerd")
// lus van buitenaf (twee apparaten) → de oudste regel valt weg
var other = CatalogMeta()
other.remap["c|1"] = .init(to: "a|1", at: 5)
let merged = CatalogMeta.merge(m, other)
check(merged.resolve("a|1") != nil || merged.resolve("c|1") != nil, "na samenvoegen geen lus meer")
var loopFree = true
for k in merged.remap.keys where merged.resolve(k) == nil { loopFree = false }
check(loopFree, "elke regel in de samengevoegde meta leidt ergens heen")
eq(merged.remap["c|1"], nil as CatalogMeta.Remap?, "oudste regel van de lus weg")

// MARK: remap op lijsten

var rm = CatalogMeta()
let s1 = UUID(), s2 = UUID()
rm.addRemap(from: "\(s1.uuidString)|m1", to: "\(s2.uuidString.lowercased())|m9", at: 100)
let (newSet, ch) = CatalogRemap.set(["\(s1.uuidString)|m1", "\(s1.uuidString)|m2"], rm)
eq(newSet, ["\(s2.uuidString)|m9", "\(s1.uuidString)|m2"], "set remap")
eq(ch.count, 1, "één wijziging")
let (again, ch2) = CatalogRemap.set(newSet, rm)
eq(again, newSet, "idempotent")
eq(ch2.count, 0, "geen wijziging bij opnieuw toepassen")
let (lst, _) = CatalogRemap.list(["\(s1.uuidString.lowercased())|m1", "\(s2.uuidString)|m9", "x|y"], rm)
eq(lst, ["\(s2.uuidString)|m9", "x|y"], "lijst: zelfde plek, geen dubbele")

// MARK: catalogmeta JSON, samenvoegen, begrenzen

let now = Date().timeIntervalSince1970
var a = CatalogMeta()
a.set("S1|m1", .init(title: "Dune", year: 2021, kind: .movie, tmdb: 438631, image: nil, sid: "S1", serverName: "Een",
                     ep: nil, ch: nil, at: now - 10))
a.set("s1|c1", .init(title: "NPO 1", year: nil, kind: .channel, tmdb: nil, image: "https://x/logo.png", sid: "s1",
                     serverName: nil, ep: nil, ch: .init(name: "NPO 1 HD", epg: "npo1.nl"), at: now - 5))
a.set("s1|e1", .init(title: "Breaking Bad", year: 2008, kind: .episode, tmdb: nil, image: nil, sid: "s1", serverName: nil,
                     ep: .init(series: "s1|se1", seriesTitle: "Breaking Bad", season: 1, episode: 2), ch: nil, at: now))
a.extras["future"] = "[{\"x\":1}]"
let j = a.json()
check(JSONSerialization.isValidJSONObject(j), "geldige JSON")
let back = CatalogMeta(json: try! JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: j)))
eq(back.items.count, 3, "drie items terug")
eq(back.items["s1|m1"]?.tmdb, 438631, "tmdb terug")
eq(back.items["s1|e1"]?.ep?.episode, 2, "aflevering terug")
eq(back.items["s1|c1"]?.ch?.epg, "npo1.nl", "epg terug")
check(back.extras["future"] != nil, "onbekend veld blijft")
check(back.item(forKey: "S1|m1") != nil, "opzoeken hoofdletterongevoelig")
// tmdb als tekst (een andere app)
let txt = CatalogMeta(json: ["items": ["s9|z": ["t": "X", "k": "movie", "tmdb": "12", "sid": "s9", "at": "2026-01-01T00:00:00Z"]]])
eq(txt.items["s9|z"]?.tmdb, 12, "tmdb als tekst")

var b = CatalogMeta()
b.set("s1|m1", .init(title: "Dune (nieuw)", year: 2021, kind: .movie, tmdb: 438631, image: nil, sid: "s1", serverName: "Een",
                     ep: nil, ch: nil, at: now))
b.set("s1|m1x", .init(title: "Oud", year: nil, kind: .movie, tmdb: nil, image: nil, sid: "s1", serverName: nil,
                      ep: nil, ch: nil, at: now - 100 * 86400))
let mm = CatalogMeta.merge(a, b)
eq(mm.items["s1|m1"]?.title, "Dune (nieuw)", "nieuwste at wint")
eq(mm.items.count, 4, "alles samengevoegd")
var pr = mm
pr.prune(referenced: ["S1|m1"], now: now)
eq(pr.items["s1|m1x"], nil as CatalogMeta.Item?, "oud en niet verwezen: weg")
check(pr.items["s1|m1"] != nil, "verwezen blijft")
var oldRef = mm
oldRef.prune(referenced: ["s1|m1x"], now: now)
check(oldRef.items["s1|m1x"] != nil, "oud maar verwezen blijft")
var rr = CatalogMeta()
rr.remap["a|1"] = .init(to: "b|1", at: now - 200 * 86400)
rr.remap["c|1"] = .init(to: "d|1", at: now - 10)
rr.prune(referenced: [], now: now)
eq(rr.remap.count, 1, "remap ouder dan 180 dagen weg")

// grootte: 7000 items → max 6000 en onder de byte-grens
var big = CatalogMeta()
for i in 0..<7000 {
    big.items["s1|item\(i)"] = .init(title: "Een vrij lange titel nummer \(i) met wat extra tekst erbij", year: 2000 + i % 25,
                                     kind: .movie, tmdb: i, image: "https://image.tmdb.org/t/p/w342/abcdefghijklmnop\(i).jpg",
                                     sid: "s1", serverName: "Server", ep: nil, ch: nil, at: now - Double(i))
}
big.prune(referenced: ["s1|item6999"], now: now, maxBytes: 900_000)
check(big.items.count <= CatalogMeta.maxItems, "max 6000 items (\(big.items.count))")
check((big.encodedSize() ?? .max) <= 900_000, "onder 900 KB (\(big.encodedSize() ?? -1))")
check(big.items["s1|item6999"] != nil, "verwezen item blijft bij begrenzen")

// MARK: koppelen

let idx = CatalogIndex(titles: [
    CatalogIndex.entry(id: "xv1", kind: .movie, title: "NL | Dune (2021)", year: nil, tmdb: nil),
    CatalogIndex.entry(id: "xv2", kind: .movie, title: "Dune", year: 1984, tmdb: nil),
    CatalogIndex.entry(id: "xv3", kind: .movie, title: "Oppenheimer [4K]", year: 2023, tmdb: 872585),
    CatalogIndex.entry(id: "xs1", kind: .series, title: "Breaking Bad", year: 2008, tmdb: nil),
], channels: [
    CatalogIndex.channelEntry(id: "c1", name: "NL: NPO 1 FHD", epg: "NPO1.nl"),
    CatalogIndex.channelEntry(id: "c2", name: "RTL 4 HD", epg: nil),
])
eq(idx.title(kind: .movie, title: "Dune", year: 2021, tmdb: nil), "xv1", "titel + jaar")
eq(idx.title(kind: .movie, title: "Dune", year: 2022, tmdb: nil), "xv1", "jaar ±1")
eq(idx.title(kind: .movie, title: "Dune", year: 1985, tmdb: nil), "xv2", "ander jaar = andere film")
eq(idx.title(kind: .movie, title: "Dune", year: 2010, tmdb: nil), nil as String?, "jaar te ver weg")
eq(idx.title(kind: .movie, title: "Iets anders", year: nil, tmdb: 872585), "xv3", "tmdb gaat voor")
eq(idx.title(kind: .series, title: "Dune", year: 2021, tmdb: nil), nil as String?, "film is geen serie")
eq(idx.channel(name: "NPO 1 HD", epg: nil), "c1", "zender op naam")
eq(idx.channel(name: "Iets", epg: "npo1.NL"), "c1", "zender op epg-id")
eq(idx.channel(name: "|NL| RTL4", epg: nil), "c2", "zender RTL4")
let epItem = CatalogMeta.Item(title: "Breaking Bad", year: 2008, kind: .episode, tmdb: nil, image: nil, sid: "s1",
                              serverName: nil, ep: .init(series: "s1|x", seriesTitle: "Breaking Bad", season: 1, episode: 1),
                              ch: nil, at: 0)
eq(idx.match(epItem), "xs1", "aflevering → serie")
eq(CatalogIdentity.title(kind: .movie, title: "NL | Dune (2021)", year: nil, tmdb: nil),
   CatalogIdentity.title(kind: .movie, title: "Dune [4K]", year: 2021, tmdb: nil), "zelfde werk = zelfde identiteit")


// MARK: build 140: kindercategorieën

check(KidsCategory.isKids("NL | Kinderfilms"), "NL | Kinderfilms")
check(KidsCategory.isKids("|EN| Kids"), "|EN| Kids")
check(KidsCategory.isKids("EN - Cartoon Network"), "EN - Cartoon Network")
check(KidsCategory.isKids("[NL] Disney+"), "[NL] Disney+")
check(KidsCategory.isKids("Familiefilms"), "Familiefilms")
check(KidsCategory.isKids("NL: Nick Jr."), "Nick Jr.")
check(KidsCategory.isKids("BE | Ketnet"), "Ketnet")
check(KidsCategory.isKids("Z@pp"), "Z@pp")
check(KidsCategory.isKids("Kid - Fun"), "Kid als eerste woord, geen landcode")
check(KidsCategory.isKids("Jeugdseries"), "Jeugdseries")
check(KidsCategory.isKids("Animatie"), "Animatie")
check(KidsCategory.isKids("Baby TV"), "Baby TV")
check(!KidsCategory.isKids("Anime"), "anime is geen kindercategorie")
check(!KidsCategory.isKids("NL | Kidnap thrillers"), "kidnap telt niet")
check(!KidsCategory.isKids("Babylon"), "babylon telt niet")
check(!KidsCategory.isKids("Adult Swim cartoons"), "adult wint altijd")
check(!KidsCategory.isKids("XXX Kids"), "xxx wint altijd")
check(!KidsCategory.isKids("Kinder 18+"), "18+ wint altijd")
check(!KidsCategory.isKids("NL | Films"), "gewone categorie")
check(!KidsCategory.isKids(""), "lege naam")
eq(KidsCategory.normalize("NL | |EN| Kids"), "kids", "landprefix herhaald weg")

// MARK: build 140: categorieën per account

eq(AccountCategories.key(sid: "ABCD-EF", group: "NL | Films"), "abcd-ef|NL | Films", "sleutel: server-id klein, naam exact")
eq(AccountCategories.normalize("ABCD|Sport|HD"), "abcd|Sport|HD", "normaliseren: alleen het eerste deel")
eq(AccountCategories.migrate([["AB|x", "cd|y"], ["ab|x", "EF|z"]]), Set(["ab|x", "cd|y", "ef|z"]), "migratie: unie, kleine letters")
eq(AccountCategories.groups(["ab|x", "AB|y", "cd|z"], sid: "Ab"), Set(["x", "y"]), "groepen per server, hoofdletterongevoelig")

// MARK: build 140: Mijn lijst — eigen toevoeging na een verwijdering met een latere tijd

eq(ListStamp.addedAt(now: 100, knownRemoval: nil), 100, "geen verwijdering bekend")
eq(ListStamp.addedAt(now: 100, knownRemoval: 50), 100, "oudere verwijdering")
check(ListStamp.addedAt(now: 100, knownRemoval: 150) > 150, "verwijdering met voorlopende klok: toevoeging komt erna")
check(ListStamp.addedAt(now: 100, knownRemoval: 100) > 100, "gelijke tijd: toevoeging wint")
eq(ListStamp.addedAt(now: 0, knownRemoval: 150), 0, "eerste afstemming (tijd 0) blijft oud")

// MARK: build 140: Mijn lijst — toevoegen, meteen syncen, tweede apparaat

do {
    // apparaat A: al afgestemd (Mijn lijst: x), voegt y toe en synct meteen; de server heeft y nog niet
    let knownA: ListMerge.Stamps = (["s|x": 10], [:])
    let afterAdd = ListMerge.diff(knownA, current: ["s|x", "s|y"], now: 100)
    let serverStale: ListMerge.Stamps = (["s|x": 10], [:])
    let mergedA = ListMerge.merge(local: afterAdd, server: serverStale)
    check(mergedA.present["s|y"] != nil, "toevoegen → meteen sync → nog aanwezig")
    // apparaat B (ander apparaat, ook afgestemd) leest de upload van A
    let knownB: ListMerge.Stamps = (["s|x": 10], [:])
    let localB = ListMerge.diff(knownB, current: ["s|x"], now: 105)
    let mergedB = ListMerge.merge(local: localB, server: mergedA)
    check(mergedB.present["s|y"] != nil, "tweede apparaat ziet het toegevoegde item")
    check(mergedB.present["s|x"] != nil, "bestaand item blijft")
    // eerder op een apparaat met een voorlopende klok verwijderd (t=150), nu hier (t=100) opnieuw toegevoegd
    let knownC: ListMerge.Stamps = ([:], ["s|z": 150])
    let localC = ListMerge.diff(knownC, current: ["s|z"], now: 100)
    let mergedC = ListMerge.merge(local: localC, server: ([:], ["s|z": 150]))
    check(mergedC.present["s|z"] != nil, "opnieuw toegevoegd na verwijdering met latere tijd: blijft in Mijn lijst")
    // echte latere verwijdering op een ander apparaat wint wel
    let mergedD = ListMerge.merge(local: afterAdd, server: (["s|x": 10], ["s|y": 200]))
    check(mergedD.present["s|y"] == nil && mergedD.removed["s|y"] != nil, "latere verwijdering elders wint")
}

// MARK: build 140: ouderpoort

struct FixedGen: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
}
var gen = FixedGen(state: 42)
for _ in 0..<500 {
    let s = ParentGateSum.random(using: &gen)
    if s.multiply { check((6...12).contains(s.a) && (3...9).contains(s.b), "vermenigvuldiging binnen bereik") }
    else { check((11...49).contains(s.a) && (11...49).contains(s.b), "optelling tweecijferig") }
    check(s.answer < 1000, "antwoord past in 3 cijfers")
}
eq(ParentGateSum(a: 7, b: 8, multiply: true).text, "7 × 8 = ?", "tekst vermenigvuldiging")
eq(ParentGateSum(a: 23, b: 46, multiply: false).answer, 69, "optelling")
var gate = ParentGateState(sum: ParentGateSum(a: 7, b: 8, multiply: true))
eq(ParentGateState.sanitize("5a6x7 9"), "567", "alleen cijfers, max 3")
check(!gate.readyToCheck("5"), "nog niet vanzelf controleren")
check(gate.readyToCheck("56"), "vanzelf controleren bij 2 cijfers")
eq(gate.submit("55"), .wrong, "fout 1")
eq(gate.submit("54"), .wrong, "fout 2")
let otherSum = ParentGateSum(a: 9, b: 9, multiply: true)
eq(gate.submit("1", next: { otherSum }), .newSum, "fout 3 = nieuwe som")
eq(gate.sum, otherSum, "nieuwe som gezet")
eq(gate.attempts, 0, "pogingen opnieuw")
eq(gate.submit("81"), .correct, "goed antwoord")

// MARK: build 140: uitgelicht

eq(HeroRotation.pick(forYou: ["a", "b", "c"], new: ["x", "b", "y"]), ["a", "x", "b", "c", "y"], "om en om, zonder dubbele")
eq(HeroRotation.pick(forYou: (1...20).map(String.init), new: []).count, 8, "maximaal 8")
eq(HeroRotation.rotated(["a", "b", "c"], day: 4), ["b", "c", "a"], "start schuift per dag")
eq(HeroRotation.rotated(["a", "b", "c"], day: 4), HeroRotation.rotated(["a", "b", "c"], day: 4), "deterministisch")
eq(HeroRotation.start(day: -1, count: 3), 2, "negatieve dag")
let utc = { () -> Calendar in var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
eq(HeroRotation.day(Date(timeIntervalSince1970: 86_400 * 3 + 100), calendar: utc), 3, "dagnummer")

// MARK: build 140: Nieuw op Bingr

var seenMap: [String: Double] = [:]
check(FirstSeen.update(&seenMap, ids: ["a", "b"], now: 500, seeded: false), "eerste keer: vastgelegd")
eq(seenMap["a"], 0 as Double?, "eerste keer telt niet als nieuw")
FirstSeen.update(&seenMap, ids: ["a", "b", "c"], now: 600, seeded: true)
eq(seenMap["c"], 600 as Double?, "nieuw id krijgt nu")
check(!FirstSeen.update(&seenMap, ids: ["a", "c"], now: 700, seeded: true), "niets nieuws")
eq(FirstSeen.newest([("a", nil), ("b", 300), ("c", nil), ("d", 900)], firstSeen: seenMap, limit: 10), ["d", "c", "b"],
   "provider-datum, anders eerste keer gezien; zonder tijd niet")
eq(FirstSeen.newest([("x", 5), ("y", 5)], firstSeen: [:], limit: 1), ["x"], "gelijke tijd op id, limiet")

// MARK: build 145: servers laden bij openen (Vragen / Altijd / Nooit)

eq(StartLoad.mode(nil), .ask, "standaard Vragen")
eq(StartLoad.mode("garbage"), .ask, "onbekend = Vragen")
eq(StartLoad.mode("never"), .never, "Nooit")
for old in ["manual", "launch", "sixHours", "daily", "weekly", nil] as [String?] {
    eq(StartLoad.migrated(legacy: old, current: nil), .ask, "oude termijn \(old ?? "-") wordt Vragen")
}
eq(StartLoad.migrated(legacy: "daily", current: "always"), .always, "al gekozen instelling blijft")
eq(StartLoad.migrated(legacy: nil, current: "x"), .ask, "ongeldige nieuwe waarde = Vragen")
// Vragen
eq(StartLoad.decide(mode: .ask, hasCache: true, kids: false, decided: false), .ask, "Vragen met bewaarde lijst: vraag")
eq(StartLoad.decide(mode: .ask, hasCache: false, kids: false, decided: false), .none, "geen cache: al geladen, geen vraag")
eq(StartLoad.decide(mode: .ask, hasCache: true, kids: true, decided: false), .none, "kinderprofiel: Later")
eq(StartLoad.decide(mode: .ask, hasCache: true, kids: false, decided: true), .none, "één keer per sessie")
// Altijd
eq(StartLoad.decide(mode: .always, hasCache: true, kids: false, decided: false), .update, "Altijd: meteen bijwerken")
eq(StartLoad.decide(mode: .always, hasCache: true, kids: true, decided: false), .update, "Altijd ook bij een kinderprofiel")
eq(StartLoad.decide(mode: .always, hasCache: false, kids: false, decided: false), .update, "Altijd zonder cache: de rest bijwerken")
eq(StartLoad.decide(mode: .always, hasCache: true, kids: false, decided: true), .none, "Altijd: één keer per sessie")
// Nooit
eq(StartLoad.decide(mode: .never, hasCache: true, kids: false, decided: false), .none, "Nooit: niets")
eq(StartLoad.decide(mode: .never, hasCache: false, kids: false, decided: false), .none, "Nooit zonder cache: alleen het laden zelf")
// sessie
check(StartLoad.consumes(mode: .ask, kids: false, decided: false), "vraag gesteld: sessie beslist")
check(!StartLoad.consumes(mode: .ask, kids: true, decided: false), "kinderprofiel: vraag later bij een gewoon profiel")
check(StartLoad.consumes(mode: .always, kids: true, decided: false), "Altijd bij kinderprofiel: beslist")
check(!StartLoad.consumes(mode: .never, kids: true, decided: false), "Nooit bij kinderprofiel: niet beslist")
check(StartLoad.consumes(mode: .never, kids: true, decided: true), "eenmaal beslist blijft beslist")
// reeks: kinderprofiel, dan hoofdprofiel, dan terug uit de achtergrond / ander profiel
do {
    var decided = false
    var asked = 0
    for kids in [true, false, false, true, false] {
        if StartLoad.decide(mode: .ask, hasCache: true, kids: kids, decided: decided) == .ask { asked += 1 }
        decided = StartLoad.consumes(mode: .ask, kids: kids, decided: decided)
    }
    eq(asked, 1, "Vragen: precies één keer per keer openen")
}
check(StartLoad.skipJustLoaded(age: 30, justLoaded: true), "net geladen: niet nog eens")
check(!StartLoad.skipJustLoaded(age: 30, justLoaded: false), "bewaarde lijst: wel bijwerken")
check(!StartLoad.skipJustLoaded(age: 3600, justLoaded: true), "oud: wel bijwerken")

// MARK: build 140: Voor jou

eq(ForYouSeeds.rank([.init(key: "s1", at: 10), .init(key: "m1", at: 50), .init(key: "s1", at: 20), .init(key: "m2", at: 40)], limit: 2),
   ["s1", "m1"], "meest bekeken, dan laatst bekeken")
eq(ForYouSeeds.score(genres: [16, 35], group: "Kids", seedGenres: [16: 3], seedGroups: ["Kids": 1]), 5, "score")

// MARK: build 141: Mijn lijst na zoeken (zoekresultaat, andere server, TMDB) — meteen zichtbaar, na sync, tweede apparaat

eq(MyListID.forTitle(id: "m-123", tmdb: 603, isShow: false), "m-123" as String?, "titel uit een bibliotheek houdt zijn id")
eq(MyListID.forTitle(id: "rec-tt0133093", tmdb: 603, isShow: false), "tmdb-movie-603" as String?, "aanbeveling → TMDB-id")
eq(MyListID.forTitle(id: "rec-Dark", tmdb: 70523, isShow: true), "tmdb-tv-70523" as String?, "aanbeveling serie → TMDB-id")
eq(MyListID.forTitle(id: "rec-x", tmdb: nil, isShow: false), nil as String?, "zonder TMDB-id geen Mijn lijst")
let S1 = "AAAAAAAA-0000-0000-0000-000000000001", S2 = "BBBBBBBB-0000-0000-0000-000000000002"
eq(MyListID.origin(of: "\(S1)|m7", activeSID: S1), .active, "open server")
eq(MyListID.origin(of: "\(S1.lowercased())|m7", activeSID: S1), .active, "open server, kleine letters (web/Android)")
eq(MyListID.origin(of: "\(S2)|m42", activeSID: S1), .otherServer, "andere server")
eq(MyListID.origin(of: "\(S1)|tmdb-movie-603", activeSID: S1), .external, "TMDB-titel")
eq(MyListID.origin(of: "\(S2)|tmdb-tv-1", activeSID: S1), .external, "TMDB-titel onder een andere server-id")
eq(MyListID.origin(of: "kapot", activeSID: S1), nil as MyListID.Origin?, "geen geldige sleutel")
do {
    // apparaat A (open server S1) zoekt en zet drie treffers in Mijn lijst: van S1, van S2 en een TMDB-aanbeveling
    let added = ["\(S1)|m7", "\(S2)|m42", "\(S1)|tmdb-movie-603"]
    let knownA: ListMerge.Stamps = (["\(S1)|old": 10], [:])
    let localA = ListMerge.diff(knownA, current: Set(added + ["\(S1)|old"]), now: 1_000)
    // meteen zichtbaar: S1 uit de bibliotheek, S2 via CrossServer.noteListed (genormaliseerde sleutel), TMDB via DiscoverKnown
    let shownA = MyListID.visible(keys: localA.present.map { ($0.key, $0.value) }, activeSID: S1,
                                  active: ["m7": "Film 7", "old": "Oud"], other: ["\(S2.lowercased())|m42": "Film 42"],
                                  external: ["tmdb-movie-603": "The Matrix"])
    eq(Set(shownA), Set(["Film 7", "Film 42", "The Matrix", "Oud"]), "meteen zichtbaar in Mijn lijst (alle drie)")
    eq(shownA.last, "Oud" as String?, "laatst toegevoegd eerst")
    // sync: de server had alleen het oude item
    let server0: ListMerge.Stamps = (["\(S1)|old": 10], [:])
    let afterSync = ListMerge.merge(local: localA, server: server0)
    for k in added { check(afterSync.present[k] != nil, "na sync nog aanwezig: \(k)") }
    // tweede sync-ronde (de server geeft terug wat A uploadde): niets verdwijnt
    let again = ListMerge.merge(local: ListMerge.diff(afterSync, current: Set(afterSync.present.keys), now: 1_010), server: afterSync)
    eq(Set(again.present.keys), Set(afterSync.present.keys), "volgende ronde: lijst blijft gelijk")
    // apparaat B (zelfde profiel, open server S2, al afgestemd op de oude stand) leest de upload
    let knownB: ListMerge.Stamps = (["\(S1)|old": 10], [:])
    let localB = ListMerge.diff(knownB, current: ["\(S1)|old"], now: 1_020)
    let mergedB = ListMerge.merge(local: localB, server: afterSync)
    for k in added { check(mergedB.present[k] != nil, "tweede apparaat heeft \(k)") }
    let shownB = MyListID.visible(keys: mergedB.present.map { ($0.key, $0.value) }, activeSID: S2,
                                  active: ["m42": "Film 42"], other: ["\(S1.lowercased())|m7": "Film 7", "\(S1.lowercased())|old": "Oud"],
                                  external: ["tmdb-movie-603": "The Matrix"])
    eq(Set(shownB), Set(["Film 7", "Film 42", "The Matrix", "Oud"]), "zichtbaar op het tweede apparaat")
    // nieuw apparaat zonder eerdere afstemming (tijd 0) neemt alles over
    let fresh = ListMerge.merge(local: ListMerge.diff(([:], [:]), current: [], now: 0), server: afterSync)
    for k in added { check(fresh.present[k] != nil, "nieuw apparaat heeft \(k)") }
}

// MARK: build 141: Home — Nieuw op Bingr op de plek van Nieuw toegevoegd

typealias HR = (key: String, visible: Bool)
func rows(_ r: [HR]) -> [HR] { HomeRowOrder.newOnBingrAtRecent(r, key: { $0.key }, visible: { $0.visible }, make: { ($0, $1) }) }
eq(rows([("continue", true), ("mylist", true), ("recent", true), ("upcoming", true), ("streaming", true), ("foryou", true)]).map(\.key),
   ["continue", "mylist", "streaming", "upcoming", "foryou"], "Nieuw op Bingr verhuist naar de plek van Nieuw toegevoegd")
eq(rows([("recent", true), ("streaming", false)]).map(\.visible), [false], "eigen aan/uit van Nieuw op Bingr blijft")
eq(rows([("foryou", true), ("recent", false)]).map(\.key), ["foryou", "streaming"], "zonder streaming: op de plek van recent")
eq(rows([("recent", false)]).map(\.visible), [false], "dan het aan/uit van recent")
eq(rows([("streaming", true), ("foryou", true)]).map(\.key), ["streaming", "foryou"], "zonder recent: ongewijzigd")
eq(rows([("recent", true), ("streaming", true)]).filter { $0.key == "streaming" }.count, 1, "maar één rij Nieuw op Bingr")

// MARK: build 143: startdiagnose

do {
    var r = StartDiag.Record(build: "1.0.1 (143)", os: "tvOS 27.2", started: 1000)
    r.marks = [.init(name: "gestart", t: 0, mb: 80), .init(name: "opslag", t: 0.4, mb: 120), .init(name: "catalogus", t: 6.2, mb: 610)]
    r.peakMB = 640
    let nf = StartDiag.analyze(r)
    eq(nf?.kind, .notFinished as StartDiag.Problem.Kind?, "niet bij klaar: rapport")
    eq(nf?.lastMark, "catalogus" as String?, "laatste mijlpaal")
    check(StartDiag.text(nf!).contains("hoogste 640 MB"), "geheugen in het rapport")
    check(StartDiag.text(nf!).contains("catalogus 6.2s 610MB"), "mijlpaal met tijd en geheugen")
    var ok = r; ok.marks.append(.init(name: "klaar", t: 20)); ok.finished = true
    eq(StartDiag.analyze(ok), nil as StartDiag.Problem?, "klaar zonder crash of hang: geen rapport")
    var hung = ok; hung.hang = 12.5; hung.hangAt = "profiel gekozen"
    eq(StartDiag.analyze(hung)?.kind, .hang as StartDiag.Problem.Kind?, "hoofdthread > 10 s vast: watchdog-vermoeden")
    eq(StartDiag.analyze(hung)?.lastMark, "profiel gekozen" as String?, "mijlpaal van de hang")
    let crashed = StartDiag.analyze(r, crashLog: "signal 05\n0 Bingr 0x1 main + 4\n1 libswiftCore 0x2 x")
    eq(crashed?.kind, .crash as StartDiag.Problem.Kind?, "signaalbestand: crash")
    eq(crashed?.crash, "signal 05" as String?, "type van de crash")
    eq(crashed?.stack.count, 3, "stackregels")
    var ex = r; ex.crash = "NSInvalidArgumentException: mail jan@example.com https://srv.example/get.php?username=a"
    let exText = StartDiag.text(StartDiag.analyze(ex)!)
    check(!exText.contains("jan@example.com") && !exText.contains("username"), "geen e-mail of URL in het rapport")
    check(StartDiag.scrub("/Users/leon/Library/x").hasPrefix("/~"), "geen gebruikersnaam in paden")
    let rt = try! JSONDecoder().decode(StartDiag.Record.self, from: try! JSONEncoder().encode(r))
    eq(rt, r, "record via JSON")
}

// MARK: build 146: pincode als hash (testvectoren uit docs/ACCOUNT.md)

do {
    func b64(_ s: String) -> Data { Data(base64Encoded: s)! }
    let salt1 = b64("AAECAwQFBgcICQoLDA0ODw==")
    eq(salt1, Data((0..<16).map { UInt8($0) }), "salt 1 = 00…0f")
    eq(PinHash.derive(pin: "1234", salt: salt1, iterations: 100_000)?.base64EncodedString(),
       "hp5sg1DFvrCsw5n7qsO2DSIEM4lrJqZHc00NjxWG4fo=" as String?, "vector 1234")
    let salt2 = b64("QmluZ3ItcGluLXRlc3QtMQ==")
    eq(String(data: salt2, encoding: .utf8), "Bingr-pin-test-1" as String?, "salt 2 = ASCII")
    eq(PinHash.derive(pin: "0000", salt: salt2, iterations: 100_000)?.base64EncodedString(),
       "+fGTeA7fJpt28Rrq3DjQxUFemZFqDW4eAb85/ZRYHg8=" as String?, "vector 0000")
    let salt3 = b64("//79/Pv6+fj39vX08/Lx8A==")
    eq(salt3, Data((0..<16).map { UInt8(0xff - $0) }), "salt 3 = ff…f0")
    eq(PinHash.derive(pin: "98765432", salt: salt3, iterations: 100_000)?.base64EncodedString(),
       "ZPbmm6a1FOjvmJWC0XNDHIDHyxK4739iaGZkx4Oid7c=" as String?, "vector 98765432")
    eq(PinHash.derive(pin: "1234", salt: salt1, iterations: 1)?.base64EncodedString(),
       "i/F57D1qcIBBiv5AzlKB8LqqXqCNwubIJuZH8P6K1uI=" as String?, "1 iteratie")
    eq(PinHash.derive(pin: "1234", salt: salt1, iterations: 2)?.base64EncodedString(),
       "oNCs4eO5peWpZXM8MGUdRebd/Uv8TI0RC7CQ7Ngh0N4=" as String?, "2 iteraties")
    let v1 = PinHash(json: ["alg": "pbkdf2-sha256", "iter": 100000, "salt": "AAECAwQFBgcICQoLDA0ODw==",
                            "hash": "hp5sg1DFvrCsw5n7qsO2DSIEM4lrJqZHc00NjxWG4fo="])
    check(v1 != nil, "geldig pinHash-object")
    check(v1?.verify("1234") == true, "1234 klopt")
    check(v1?.verify("1235") == false, "1235 fout")
    check(v1?.verify("01234") == false, "01234 fout (voorloopnul telt)")
    check(v1?.verify("123") == false, "te kort")
    eq(PinHash.make(pin: "1234", salt: salt1), v1, "make met vaste salt = vector")
    let made = PinHash.make(pin: "4321")!
    eq(made.iter, 100_000, "schrijven: 100.000 iteraties")
    eq(made.salt.count, 16, "salt 16 bytes")
    eq(made.hash.count, 32, "hash 32 bytes")
    check(made.verify("4321") && !made.verify("4322"), "nieuwe hash controleren")
    check(PinHash.make(pin: "4321")!.salt != made.salt, "nieuwe salt per pincode")
    eq(PinHash(string: made.string), made, "lokale tekst terug naar de hash")
    eq(PinHash(json: made.json), made, "json terug naar de hash")
    check(PinHash.make(pin: "12a4") == nil && PinHash.make(pin: "123456789") == nil, "ongeldige pincode")
    check(PinHash(json: ["alg": "sha1", "iter": 100000, "salt": made.json["salt"]!, "hash": made.json["hash"]!]) == nil, "onbekend alg")
    check(PinHash(json: ["alg": "pbkdf2-sha256", "iter": 1000, "salt": made.json["salt"]!, "hash": made.json["hash"]!]) == nil, "te weinig iteraties")
    check(PinHash(json: ["alg": "pbkdf2-sha256", "iter": 100000, "salt": made.json["salt"]!, "hash": "AAAA"]) == nil, "hash te kort")
    check(PinHash.matches(stored: made.string, pin: "4321"), "lokaal: hash")
    check(PinHash.matches(stored: "4321", pin: "4321") && !PinHash.matches(stored: "4321", pin: "1234"), "lokaal: oude pincode")
    check(!PinHash.matches(stored: nil, pin: "4321"), "lokaal: geen pincode")
    check(PinHash.isLegacyPlain("0123") && !PinHash.isLegacyPlain(made.string), "oude pincode herkennen")
    check(PinHash.constantTimeEqual(Data([1, 2]), Data([1, 2])) && !PinHash.constantTimeEqual(Data([1, 2]), Data([1, 2, 3])), "vaste-tijdvergelijking")

    // regels voor het lezen van profile.<id>
    func t(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
    eq(PinState.read(["pinHash": v1!.json, "pin": "9999", "pinUpdatedAt": 50], sectionAt: 99, time: t), .hash(v1!, at: 50), "hash wint van pin")
    eq(PinState.read(["pin": "1234", "pinUpdatedAt": 40], sectionAt: 99, time: t), .legacy("1234", at: 40), "oude pin: migreren met dezelfde tijd")
    eq(PinState.read(["pin": "1234", "pinHash": NSNull(), "pinUpdatedAt": 40], sectionAt: 99, time: t), .legacy("1234", at: 40), "pinHash null + pin")
    eq(PinState.read(["pin": NSNull(), "pinHash": NSNull(), "pinUpdatedAt": 70], sectionAt: 99, time: t), .removed(at: 70), "verwijderd")
    eq(PinState.read(["pin": NSNull()], sectionAt: 99, time: t), .removed(at: 0), "pin null zonder tijd = heel oud")
    eq(PinState.read(["prefs": [:]], sectionAt: 99, time: t), .absent, "niets over de pincode")
    eq(PinState.read(["pinHash": ["alg": "argon2", "x": 1]], sectionAt: 99, time: t), .absent, "onbekend formaat wist niets")
}

// MARK: build 146: support, apparaat, diagnose, tv-gids

do {
    eq(SupportLogic.group(status: "new", group: nil), .open, "new = Open")
    eq(SupportLogic.group(status: "pending", group: nil), .inProgress, "pending = In behandeling")
    eq(SupportLogic.group(status: "open", group: nil), .inProgress, "open = In behandeling")
    eq(SupportLogic.group(status: "resolved", group: nil), .closed, "resolved = Gesloten")
    eq(SupportLogic.group(status: "x", group: "closed"), .closed, "group van de server wint")
    eq(SupportLogic.validate(subject: "Hi", message: "lang genoeg bericht", reply: false), "subject_missing" as String?, "onderwerp te kort")
    eq(SupportLogic.validate(subject: "Hallo", message: "kort", reply: false), "message_too_short" as String?, "bericht te kort")
    eq(SupportLogic.validate(subject: nil, message: "ok", reply: true), nil as String?, "reactie mag kort")
    eq(SupportLogic.validate(subject: nil, message: String(repeating: "https://a.nl ", count: 7), reply: true), "too_many_links" as String?, "te veel links")
    let d1 = SupportLogic.deeplink(URL(string: "bingr://support/ticket?n=1042")!)
    check(d1.isSupport && d1.number == 1042, "deeplink ticket")
    let d2 = SupportLogic.deeplink(URL(string: "bingr://support")!)
    check(d2.isSupport && d2.number == nil, "deeplink lijst")
    let d3 = SupportLogic.deeplink(URL(string: "bingr:support/ticket?n=7")!)
    check(d3.isSupport && d3.number == 7, "deeplink zonder //")
    check(!SupportLogic.deeplink(URL(string: "bingr://live?channel=1")!).isSupport, "andere deeplink")
    check(SupportLogic.deeplink(URL(string: "bingr://support/ticket?n=abc")!).number == nil, "ongeldig nummer = lijst")

    eq(DeviceModelName.name("AppleTV14,1"), "Apple TV 4K (3rd generation)", "Apple TV 4K 3e generatie")
    eq(DeviceModelName.name("iPhone17,1"), "iPhone 16 Pro", "iPhone 16 Pro")
    eq(DeviceModelName.name("iPad16,5"), "iPad Pro 13-inch (M4)", "iPad Pro M4")
    eq(DeviceModelName.name("MacBookPro18,3"), "MacBook Pro", "Mac-familie")
    eq(DeviceModelName.name("iPhone99,9"), "iPhone99,9", "onbekend = identifier")

    eq(SupportDiagnostics.milestoneName("profiel gekozen"), "profiel_gekozen" as String?, "mijlpaal met spatie")
    eq(SupportDiagnostics.milestoneName("1abc"), "abc" as String?, "mijlpaal begint met letter")
    eq(SupportDiagnostics.buildNumber("1.0.1 (146)"), 146 as Int?, "build uit de versie")
    var diag = SupportDiagnostics(kind: .app, platform: "tvos", version: "1.0.1", build: 146, engine: "vlc", deviceType: "tv",
                                  model: "Apple TV 4K (3rd generation)", os: "tvOS", osVersion: "26.1", language: "nl-NL")
    diag.milestones = [("gestart", 0, nil), ("profiel gekozen", 1.31, nil), ("gestart", 2, nil), ("servers_loaded", 5.2, true)]
    let j = diag.json
    eq(j["schema"] as? Int, 3 as Int?, "schema 3 (build 148)")
    eq((j["app"] as? [String: Any])?["platform"] as? String, "tvos" as String?, "platform")
    let ms = j["milestones"] as? [[String: Any]] ?? []
    eq(ms.map { $0["code"] as? String ?? "" }, ["started", "profile_picked", "servers_loaded"], "mijlpalen als code, uniek en geldig")
    eq(ms[1]["ms"] as? Int, 1310 as Int?, "ms")
    check(JSONSerialization.isValidJSONObject(j), "geldige JSON")
    let p = StartDiag.Problem(kind: .crash, build: "1.0.1 (145)", os: "tvOS 26.1", at: 0, lastMark: "x", seconds: 1, marks: [],
                              crash: "NSRangeException: index 3 beyond bounds jan@example.com", stack: ["0 Bingr x + 1"])
    let c = SupportDiagnostics.crash(from: p)
    eq(c?["type"] as? String, "NSRangeException" as String?, "crash-type")
    check(!(c?["reason"] as? String ?? "").contains("@"), "geen e-mail in de crash")
    eq(c?["build"] as? Int, 145 as Int?, "crash-build")

    let now = Date(timeIntervalSince1970: 1_000_000)
    check(GuideExpiry.isExpired(latestEnd: now.addingTimeInterval(600), now: now), "gids loopt over 10 min leeg: verlopen")
    check(!GuideExpiry.isExpired(latestEnd: now.addingTimeInterval(6 * 3600), now: now), "gids voor 6 uur: niet verlopen")
    check(!GuideExpiry.isExpired(latestEnd: nil, now: now), "geen gids: geen melding")
}

// MARK: build 147: starttijden, vorige start, ophalen, opslag en de hoofdthread (10k titels onder een tijdsgrens)

do {
    func ms(_ t0: Date) -> Double { Date().timeIntervalSince(t0) * 1000 }
    // eerlijke starttijden: wachten op de gebruiker (profielkeuze → profiel gekozen, pincodescherm → pincode goed)
    let marks: [StartDiag.Mark] = [.init(name: "gestart", t: 0), .init(name: "account", t: 0.2), .init(name: "profielkeuze", t: 4.1),
                                   .init(name: "profiel gekozen", t: 6.8), .init(name: "pincodescherm", t: 6.9),
                                   .init(name: "pincode goed", t: 10.9), .init(name: "klaar", t: 14.4)]
    let sp = StartTiming.split(marks, end: 14.4)
    eq(sp.userWaitMs, 6700, "wachten op de gebruiker: 2,7 s profielkeuze + 4,0 s pincode")
    eq(sp.appMs, 7700, "app-tijd = totaal min wachten")
    eq(StartTiming.split(Array(marks.prefix(5)), end: 8).userWaitMs, 3800, "pincodescherm zonder einde loopt tot het eind")
    eq(StartTiming.summary(appMs: 3000, hang: 0, crashed: false), .good, "goed")
    eq(StartTiming.summary(appMs: 7700, hang: nil, crashed: false), .slow, "app-tijd boven 5 s = traag")
    eq(StartTiming.summary(appMs: 1000, hang: 2.5, crashed: false), .slow, "hang boven 2 s = traag")
    eq(StartTiming.summary(appMs: 1000, hang: 80.1, crashed: false), .hung, "hang boven 10 s = vastgelopen")
    eq(StartTiming.summary(appMs: 1000, hang: nil, crashed: true), .hung, "crash = vastgelopen")
    // vorige start
    check(StartPrevious.waitingOnUser(Array(marks.prefix(5))), "op het pincodescherm: wachten op de gebruiker")
    check(!StartPrevious.waitingOnUser(marks), "pincode goed: niet meer wachten")
    eq(StartPrevious.problem(crashed: false, hang: nil, finished: false, waitingOnUser: true), .none, "niet klaar maar wachtend: geen probleem")
    eq(StartPrevious.problem(crashed: false, hang: nil, finished: false, waitingOnUser: false), .notFinished, "niet klaar")
    eq(StartPrevious.problem(crashed: false, hang: 80.1, finished: true, waitingOnUser: false), .hang, "hang")
    eq(StartPrevious.problem(crashed: true, hang: 80.1, finished: true, waitingOnUser: false), .crash, "crash gaat voor")
    var rec = StartDiag.Record(build: "1.0.1 (147)", os: "iOS 27.2", started: 0)
    rec.marks = Array(marks.prefix(5))
    check(StartDiag.analyze(rec) == nil, "op het pincodescherm gestopt: geen rapport (wachten op de gebruiker)")
    rec.hang = 12; rec.hangTask = "sync toepassen"; rec.hangFg = true; rec.hangStack = ["0 Bingr +0x10", "1 Bingr /Users/jan/x.swift"]
    let hp = StartDiag.analyze(rec)
    eq(hp?.kind, StartDiag.Problem.Kind.hang as StartDiag.Problem.Kind?, "hang boven 10 s: rapport")
    eq(hp?.task, "sync toepassen" as String?, "taak in het rapport")
    check(!(hp?.stack.joined() ?? "").contains("/Users/jan"), "geen gebruikersmap in de stack")
    check(StartDiag.text(hp!).contains("Taak: sync toepassen"), "taak in de tekst")
    // oude records (build 146) blijven leesbaar
    let old = #"{"build":"1.0.1 (146)","os":"iOS 27.2","started":1,"marks":[],"finished":true,"stack":[]}"#
    check((try? JSONDecoder().decode(StartDiag.Record.self, from: Data(old.utf8))) != nil, "record van build 146 leesbaar")

    // taak/fase op de hoofdthread
    let a = MainTasks.shared.begin("catalogus filteren")
    let b = MainTasks.shared.begin("sync toepassen")
    eq(MainTasks.shared.current, "sync toepassen, catalogus filteren" as String?, "laatste taak eerst")
    MainTasks.shared.end(b); MainTasks.shared.end(a)
    eq(MainTasks.shared.current, nil as String?, "geen taak meer")
    eq(MainTasks.shared.run("x") { 7 }, 7, "run geeft de uitkomst")

    // ophalen per soort
    eq(FetchStatus.status(delivered: 10259, visible: 10259), .ok, "geleverd")
    eq(FetchStatus.status(delivered: 0, visible: 0), .empty, "provider leverde niets")
    eq(FetchStatus.status(delivered: nil, visible: nil), .failed, "mislukt")
    eq(FetchStatus.status(delivered: 120, visible: 0), .hidden, "alles verborgen")
    eq(FetchStatus.code(URLError(.timedOut)), "timeout", "foutcode time-out")
    let rows = FetchStatus.rows(servers: [[.init(kind: .live, delivered: 1056, error: nil, at: 0),
                                           .init(kind: .movie, delivered: 10259, error: nil, at: 0),
                                           .init(kind: .series, delivered: nil, error: "timeout", at: 0)]],
                                visible: [[.live: 1056, .movie: 0, .series: 0]])
    eq(rows.count, 3, "drie soorten")
    eq(rows[0]["server"] as? String, "s1" as String?, "server geanonimiseerd")
    eq(rows[1]["status"] as? String, "hidden" as String?, "films verborgen")
    eq(rows[2]["status"] as? String, "failed" as String?, "series mislukt")
    eq(rows[2]["error"] as? String, "timeout" as String?, "foutcode mee")
    check(JSONSerialization.isValidJSONObject(rows), "fetch is geldige JSON")

    // opslag telt op tot het totaal
    let st = StorageBreakdown.make(appBytes: 156 << 20, catalogBytes: 40 << 20, downloadBytes: 10 << 20, freeBytes: 2000 << 20)
    eq(st.cacheMB + st.catalogMB + st.downloadsMB, st.totalMB, "cache + catalogus + downloads = totaal")
    eq(st.totalMB, 156, "totaal")
    eq(st.freeMB, 2000 as Int?, "vrij")
    let st2 = StorageBreakdown.make(appBytes: 1 << 20, catalogBytes: 5 << 20, downloadBytes: 0, freeBytes: nil)
    eq(st2.totalMB, 5, "totaal nooit kleiner dan de delen")

    eq(StackFormat.line(3, image: "/private/var/containers/Bundle/Application/X/Bingr.app/Bingr", symbol: nil, offset: 0, imageOffset: 0x1a2b),
       "3 Bingr +0x1a2b", "stackregel zonder symbool: alleen de naam van het bestand")
    eq(StackFormat.line(0, image: "SwiftUI", symbol: "body.getter", offset: 12, imageOffset: 0), "0 SwiftUI body.getter + 12", "stackregel met symbool")

    // 10k films / 1k zenders: wat er nu nog op de hoofdthread draait, ruim onder 250 ms
    let pid = UUID().uuidString
    let movieIDs = (0..<10_000).map { "xv\($0)" }
    var myList = Set<String>()
    for i in stride(from: 0, to: 10_000, by: 20) { myList.insert(pid + "|xv\(i)") }        // 500 in Mijn lijst
    for i in 0..<200 { myList.insert(pid.lowercased() + "|xs\(i)") }                      // web: kleine letters
    var t0 = Date()
    var hits = 0
    for id in movieIDs where ListKeys.contains(myList, playlist: pid, item: id) { hits += 1 }
    for i in 0..<1_000 where ListKeys.contains(myList, playlist: pid, item: "x\(i)") { hits += 1 }
    let tKeys = ms(t0)
    eq(hits, 500, "Mijn lijst: 500 treffers")
    check(ListKeys.contains(myList, playlist: pid, item: "xs5"), "sleutel met kleine letters")
    check(tKeys < 250, "10k films + 1k zenders langs Mijn lijst: \(Int(tKeys)) ms (max. 250)")

    t0 = Date()
    var known: [String: Double] = [:]
    FirstSeen.update(&known, ids: movieIDs.map { "m|" + $0 }, now: 1, seeded: false)
    let more = (0..<10_100).map { "m|xv\($0)" }
    check(FirstSeen.update(&known, ids: more, now: 2, seeded: true), "100 nieuwe titels")
    let items = more.map { (id: $0, provider: Double?.none) }
    let newest = FirstSeen.newest(items, firstSeen: known, limit: 120)
    let tSeen = ms(t0)
    eq(newest.count, 100, "nieuw op Bingr: alleen de nieuwe")
    check(tSeen < 250, "eerste keer gezien + nieuwste met 10k titels: \(Int(tSeen)) ms (max. 250)")

    t0 = Date()
    var origins = 0
    for k in myList where MyListID.origin(of: k, activeSID: pid) == .active { origins += 1 }
    let tOrigin = ms(t0)
    eq(origins, 700, "herkomst: open server")
    check(tOrigin < 250, "herkomst van Mijn lijst: \(Int(tOrigin)) ms (max. 250)")
}

// MARK: build 148: codes, schema 3, bijwerken per server, geleverd/zichtbaar, haperingen, grote catalogus in stukken

func footprintMB148() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
}

/// Hoogste geheugengebruik tijdens `work` (elke 2 ms gemeten op een eigen thread), boven het beginniveau
final class Peak148: @unchecked Sendable {
    let lock = NSLock()
    var peak: Double
    var running = true
    init(_ p: Double) { peak = p }
}

func peakDuring148(_ work: () -> Void) -> Double {
    let base = footprintMB148()
    let box = Peak148(base)
    let t = Thread {
        while true {
            let v = footprintMB148()
            box.lock.lock(); box.peak = max(box.peak, v); let go = box.running; box.lock.unlock()
            if !go { break }
            usleep(2000)
        }
    }
    t.start()
    work()
    box.lock.lock(); box.running = false; box.lock.unlock()
    usleep(10_000)
    box.lock.lock(); defer { box.lock.unlock() }
    return max(0, max(box.peak, footprintMB148()) - base)
}

do {
    // codes
    eq(DiagCode.code("profiel gekozen"), "profile_picked" as String?, "oude naam → code")
    eq(DiagCode.code("klaar"), "ready" as String?, "klaar → ready")
    eq(DiagCode.code("ready"), "ready" as String?, "code blijft")
    eq(DiagCode.code("gefilterde catalogus tonen"), "apply" as String?, "taak → apply")
    eq(DiagCode.code("servers_loaded"), "servers_loaded" as String?, "oude snake-naam blijft")
    eq(DiagCode.code("1 x"), nil as String?, "ongeldig")
    eq(DiagCode.task("catalog_filter, sync_apply"), "catalog_filter" as String?, "laatste taak eerst")
    check(DiagCode.fixed.allSatisfy(DiagCode.isValid) && DiagCode.isValid(DiagCode.playbackStall), "alle codes geldig")
    eq(DiagCode.fixed.count, 26, "vaste lijst")
    eq(AppLang.code("nl"), "nl", "taal nl"); eq(AppLang.code("zh-Hans"), "zh-Hans", "taal zh-Hans"); eq(AppLang.code("NL!"), "en", "ongeldige taal")
    let old: [StartDiag.Mark] = [.init(name: "gestart", t: 0), .init(name: "profielkeuze", t: 1), .init(name: "profile_picked", t: 3), .init(name: "ready", t: 5)]
    eq(StartTiming.split(old, end: 5).userWaitMs, 2000, "wachten: oude naam en code door elkaar")
    eq(StartDiag.finalMark, "ready", "klaar = ready")

    // JSON in stukken
    let j1 = Data(#" [ {"a":"x,]}","b":[1,2,{"c":"\"]"}]} , 5, "s" , null ] "#.utf8)
    eq(JSONChunks.elementRanges(j1)?.count, 4 as Int?, "lijst met lastige strings")
    let j2 = Data(#"{"2":{"n":2},"0":{"n":0},"1":{"n":1}}"#.utf8)
    struct N: Decodable { let n: Int }
    var got: [Int] = []
    JSONChunks.decode(N.self, from: j2, chunk: 2) { got += $0.map(\.n) }
    eq(got, [0, 1, 2], "genummerd object op volgorde")
    eq(JSONChunks.elementRanges(Data("false".utf8)), nil as [Range<Int>]?, "false = geen lijst")
    eq(JSONChunks.elementRanges(Data("[]".utf8))?.count, 0 as Int?, "lege lijst")
    var lossy: [Int] = []
    let st = JSONChunks.decode(N.self, from: Data(#"[{"n":1},{"x":1},{"n":3}]"#.utf8), chunk: 2) { lossy += $0.map(\.n) }
    eq(lossy, [1, 3], "kapot item overgeslagen"); eq(st?.elements, 3 as Int?, "elementen geteld")

    // bijwerken per server
    var u = UpdatePhases.Update(server: "A", at: 0)
    UpdatePhases.add(&u, code: "parse", ms: 20, memMB: 300)
    UpdatePhases.add(&u, code: "fetch", ms: 10, memMB: 200)
    UpdatePhases.add(&u, code: "fetch", ms: 5, memMB: 250)
    UpdatePhases.add(&u, code: "onbekend", ms: 5, memMB: 999)
    eq(u.phases.map(\.code), ["fetch", "parse"], "fasen op volgorde"); eq(u.phases[0].ms, 15, "fase opgeteld"); eq(u.peakMB, 300 as Int?, "piek")
    var list: [UpdatePhases.Update] = []
    for i in 0..<7 { var x = u; x.server = i % 2 == 0 ? "A" : "Z"; x.at = Double(i); UpdatePhases.push(&list, x) }
    eq(list.count, 5, "max. 5 bewaard"); eq(list.first?.at, 6 as Double?, "nieuwste eerst")
    let rows = UpdatePhases.rows(list, servers: ["B", "A"], iso: { "\($0.timeIntervalSince1970)" })
    eq(rows.count, 3, "onbekende server valt weg"); eq(rows.first?["server"] as? String, "s2" as String?, "server geanonimiseerd")
    check(JSONSerialization.isValidJSONObject(rows), "updates geldige JSON")

    // geleverd en zichtbaar
    eq(HiddenCounts.make(delivered: 36593, visible: 10286, categories: 26307, kids: 0, duplicates: 0),
       HiddenCounts.Counts(categories: 26307, kids: 0, duplicates: 0, other: 0), "films: verborgen door categorieën")
    eq(HiddenCounts.make(delivered: 100, visible: 40, categories: 30, kids: 50, duplicates: 5),
       HiddenCounts.Counts(categories: 30, kids: 30, duplicates: 0, other: 0), "nooit meer dan het verschil")
    eq(HiddenCounts.make(delivered: 100, visible: 40, categories: 10, kids: 0, duplicates: 5).other, 45, "rest = overig")

    // haperingen
    var tr = StallTracker()
    eq(tr.tick(.buffering, now: 0), nil as StallTracker.Stall?, "opstarten telt niet")
    _ = tr.tick(.playing, now: 1)
    _ = tr.tick(.playing, now: 5.5)
    _ = tr.tick(.buffering, now: 6)
    eq(tr.tick(.playing, now: 7.2), StallTracker.Stall(at: 5, ms: 1200), "hapering na 5 s, 1,2 s lang")
    eq(tr.tick(.playing, now: 8), nil as StallTracker.Stall?, "geen tweede melding")

    let lh = LongestHang.json(seconds: 5.5, task: "gefilterde catalogus tonen", milestone: "klaar", foreground: true, stack: ["0 Bingr x"])
    eq(lh["ms"] as? Int, 5500 as Int?, "hang ms"); eq(lh["task"] as? String, "apply" as String?, "hang taak als code")
    eq(lh["milestone"] as? String, "ready" as String?, "hang mijlpaal als code")

    // grote catalogus (37k films, 12k zenders, 9k series) in stukken inlezen: tijd per stap en geheugen
    struct Vod148: Decodable {
        let stream_id: Int; let name: String?; let stream_icon: String?; let category_id: String?; let added: String?
        let container_extension: String?; let rating: Double?
    }
    struct Light148 { let id: String; let title: String; let group: String; let poster: URL? }
    func makeJSON(_ n: Int, kind: String) -> Data {
        var out = Data("[".utf8)
        out.reserveCapacity(n * 420)
        for i in 0..<n {
            if i > 0 { out.append(0x2C) }
            out.append(contentsOf: Array(#"{"num":\#(i),"name":"NL | \#(kind) titel nummer \#(i) (20\#(10 + i % 15))","stream_type":"\#(kind)","stream_id":\#(i),"stream_icon":"https://img.example.org/p/\#(i % 9000).jpg","rating":"\#(i % 10).5","rating_5based":3.2,"added":"17\#(i % 100)00000","is_adult":"0","category_id":"\#(i % 600)","container_extension":"mkv","custom_sid":"","direct_source":"","plot":"Een korte beschrijving van titel \#(i), met \"aanhalingstekens\" en een [haak]."}"#.utf8))
        }
        out.append(0x5D)
        return out
    }
    struct Flexy148: Decodable {
        let stream_id: Int; let name: String?; let stream_icon: String?; let category_id: String?
        enum K: String, CodingKey { case stream_id, name, stream_icon, category_id }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: K.self)
            stream_id = try c.decode(Int.self, forKey: .stream_id)
            name = try? c.decode(String.self, forKey: .name); stream_icon = try? c.decode(String.self, forKey: .stream_icon)
            category_id = try? c.decode(String.self, forKey: .category_id)
        }
    }
    _ = Vod148.self
    let sets: [(String, Int)] = [("movie", 37_000), ("live", 12_000), ("series", 9_000)]
    var datas: [Data] = sets.map { makeJSON($0.1, kind: $0.0) }
    print("build 148: testlijsten \(datas.map { $0.count / 1_048_576 }) MB")
    var groups: [String: String] = [:]
    for g in 0..<600 { groups["\(g)"] = "Categorie \(g)" }
    var chunkedTotal = 0.0, worst = 0.0
    var counts: [Int] = []
    let chunkedPeak = peakDuring148 {
        for (k, d) in datas.enumerated() {
            let t0 = Date()
            var light: [Light148] = []
            light.reserveCapacity(sets[k].1)
            let st = JSONChunks.decode(Flexy148.self, from: d, chunk: 1500) { items in
                for v in items {
                    light.append(Light148(id: "xv\(v.stream_id)", title: v.name ?? "", group: groups[v.category_id ?? ""] ?? "Overig",
                                          poster: v.stream_icon.flatMap(URL.init(string:))))
                }
            }
            let ms = Date().timeIntervalSince(t0) * 1000
            chunkedTotal += ms
            worst = max(worst, st?.maxChunkMs ?? 0)
            counts.append(light.count)
            print("build 148: \(sets[k].0) \(sets[k].1): \(Int(ms)) ms in \(st?.chunks ?? 0) stappen, langste stap \(Int(st?.maxChunkMs ?? 0)) ms")
        }
    }
    eq(counts, [37_000, 12_000, 9_000], "37k films, 12k zenders, 9k series in stukken ingelezen")
    if worst > 250 { print("WAARSCHUWING build 148: langste stap \(Int(worst)) ms (doel max. 250 ms; gedeelde CI-runner)") }
    var wholeCounts: [Int] = []
    let wholePeak = peakDuring148 {
        for d in datas {
            let all = (try? JSONDecoder().decode([Flexy148].self, from: d)) ?? []
            wholeCounts.append(all.map { Light148(id: "xv\($0.stream_id)", title: $0.name ?? "", group: groups[$0.category_id ?? ""] ?? "Overig",
                                                    poster: $0.stream_icon.flatMap(URL.init(string:))) }.count)
        }
    }
    eq(wholeCounts, counts, "zelfde uitkomst als in één keer")
    print("build 148: geheugen tijdens inlezen: in één keer +\(Int(wholePeak)) MB, in stukken +\(Int(chunkedPeak)) MB; totaal in stukken \(Int(chunkedTotal)) ms")
    datas = []
}

// MARK: build 149: snelle ISO-8601-parser en -opmaker (geen DateFormatter per item)

do {
    let ref = ISO8601DateFormatter(); ref.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let refPlain = ISO8601DateFormatter(); refPlain.formatOptions = [.withInternetDateTime]
    func near(_ a: Double?, _ b: Double?, _ what: String, line: Int = #line) {
        guard let a, let b else { check(a == nil && b == nil, "\(what): verwacht \(String(describing: b)), kreeg \(String(describing: a))", line: line); return }
        check(abs(a - b) < 0.0005, "\(what): verwacht \(b), kreeg \(a)", line: line)
    }
    let cases = ["2026-10-25T09:09:14.123Z", "2026-10-25T09:09:14Z", "2026-10-25T11:09:14+02:00", "1999-12-31T23:59:59.999Z",
                 "2024-02-29T00:00:00.000-05:30", "1970-01-01T00:00:00Z", "2038-01-19T03:14:08.5Z", "1969-07-20T20:17:40Z"]
    for c in cases {
        near(FastISO.seconds(c), (ref.date(from: c) ?? refPlain.date(from: c))?.timeIntervalSince1970, "iso \(c)")
    }
    // Postgres-vormen
    near(FastISO.seconds("2026-10-12T10:15:30.123456+00:00"), 1_791_800_130.123456, "postgres met microseconden")
    near(FastISO.seconds("2026-10-12 10:15:30+00"), 1_791_800_130, "postgres met spatie en +00")
    near(FastISO.seconds("2026-10-12T10:15:30.1234567Z"), 1_791_800_130.1234567, "jellyfin 7 decimalen")
    near(FastISO.seconds("2026-10-12T10:15:30", defaultUTC: true), 1_791_800_130, "zonder zone als UTC")
    near(FastISO.seconds("2026-10-12T12:15:30+0200"), 1_791_800_130, "zone zonder dubbele punt")
    near(FastISO.seconds("2026-10-12T10:15Z"), 1_791_800_100, "zonder seconden")
    // ongeldig
    for bad in ["", "2026-10-12", "2026-10-12T10:15:30", "2026-13-01T00:00:00Z", "2026-02-30T00:00:00Z", "2025-02-29T00:00:00Z",
                "2026-10-12T24:00:00Z", "2026-10-12T10:15:30.Z", "2026-10-12T10:15:30Zx", "abcd-10-12T10:15:30Z", "1791022530"] {
        check(FastISO.seconds(bad) == nil, "ongeldig geweigerd: '\(bad)'")
    }
    // schrijven = ISO8601DateFormatter met fracties, en heen en terug stabiel
    var rng = SystemRandomNumberGenerator()
    var mismatch = 0, unstable = 0
    for _ in 0..<5000 {
        let t = Double(Int.random(in: -2_000_000_000...4_000_000_000, using: &rng)) + Double(Int.random(in: 0...999, using: &rng)) / 1000
        let s = FastISO.string(t)
        let r = ref.string(from: Date(timeIntervalSince1970: t))
        // zelfde seconde; de milliseconden mogen 1 verschillen (afronden of afkappen bij ISO8601DateFormatter)
        if s.prefix(19) != r.prefix(19) || s.count != r.count || abs((FastISO.seconds(s) ?? 0) - (FastISO.seconds(r) ?? 99)) > 0.0011 {
            mismatch += 1; if mismatch <= 3 { print("verschil: \(s) / \(r)") }
        }
        if let back = FastISO.seconds(s), FastISO.string(back) == s, abs(back - t) < 0.0005 {} else { unstable += 1 }
    }
    eq(mismatch, 0, "opmaak gelijk aan ISO8601DateFormatter (5000 willekeurige tijden)")
    eq(unstable, 0, "heen en terug stabiel")
    eq(FastISO.string(0), "1970-01-01T00:00:00.000Z", "nulpunt")
    eq(FastISO.string(1_791_800_130.5, fraction: false), "2026-10-12T10:15:30Z", "zonder fractie")
    eq(CatalogTime.parse("2026-10-12T10:15:30.000Z"), 1_791_800_130, "CatalogTime via de snelle parser")
    eq(CatalogTime.iso(1_791_800_130), "2026-10-12T10:15:30.000Z", "CatalogTime.iso via de snelle opmaker")
    // alleen datum, in de eigen tijdzone (zoals DateFormatter "yyyy-MM-dd")
    let dayRef = DateFormatter(); dayRef.locale = Locale(identifier: "en_US_POSIX"); dayRef.dateFormat = "yyyy-MM-dd"
    for tz in ["Europe/Amsterdam", "America/New_York", "Asia/Tokyo", "UTC"] {
        let zone = TimeZone(identifier: tz)!
        dayRef.timeZone = zone
        for d in ["2026-10-25", "2026-03-29", "2024-02-29", "2000-01-01"] {
            eq(FastISO.day(d + "T12:00:00Z", timeZone: zone), dayRef.date(from: d), "dag \(d) in \(tz)")
        }
    }
    check(FastISO.day("2026-02-30") == nil && FastISO.day("2026-10") == nil, "ongeldige dag geweigerd")
    // XMLTV
    let x = DateFormatter(); x.locale = Locale(identifier: "en_US_POSIX"); x.dateFormat = "yyyyMMddHHmmss Z"
    for c in ["20261025120000 +0100", "20261025120000 -0530", "20260101000000 +0000"] {
        eq(FastISO.xmltv(c), x.date(from: c), "xmltv \(c)")
    }
    eq(FastISO.xmltv("20261025120000")?.timeIntervalSince1970, 1_792_929_600, "xmltv zonder zone = UTC")
    eq(FastISO.xmltv(" 20261025120000 +0100 ")?.timeIntervalSince1970, 1_792_926_000, "xmltv met spaties")
    check(FastISO.xmltv("2026102512") == nil && FastISO.xmltv("x") == nil, "xmltv te kort geweigerd")
    eq(SharedFormatters.posix("yyyy-MM-dd") === SharedFormatters.posix("yyyy-MM-dd"), true, "gedeelde opmaker per formaat")

    // snelheid: 100.000 tijdstempels (sync van een groot account)
    let stamps = (0..<100_000).map { FastISO.string(1_700_000_000 + Double($0) * 37.123) }
    var t0 = Date()
    var sum = 0.0
    for s in stamps { sum += FastISO.seconds(s) ?? 0 }
    let fastMs = Date().timeIntervalSince(t0) * 1000
    t0 = Date()
    for s in stamps.prefix(5_000) {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        sum += f.date(from: s)?.timeIntervalSince1970 ?? 0
    }
    let oldMs = Date().timeIntervalSince(t0) * 1000 * 20
    t0 = Date()
    for i in 0..<100_000 { sum += Double(FastISO.string(Double(i) * 11.5).utf8.count) }
    let writeMs = Date().timeIntervalSince(t0) * 1000
    check(sum > 0, "som")
    print("build 149: 100k tijdstempels lezen \(Int(fastMs)) ms (oud, opmaker per item, geschat \(Int(oldMs)) ms); 100k schrijven \(Int(writeMs)) ms")
    check(fastMs < 1000, "100k tijdstempels lezen binnen 1 s (was \(Int(fastMs)) ms)")
}

print("\(checks) controles, \(failures) fout")
exit(failures == 0 ? 0 : 1)
