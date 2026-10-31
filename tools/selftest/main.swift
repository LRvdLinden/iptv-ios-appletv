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

// MARK: build 149: Ontdek categorieën (naam opschonen, streamingdienst herkennen)

eq(CategoryName.clean("NL | Netflix"), "Netflix", "NL | weg")
eq(CategoryName.clean("|EN| Disney+"), "Disney+", "|EN| weg")
eq(CategoryName.clean("[NL] HBO Max"), "HBO Max", "[NL] weg")
eq(CategoryName.clean("4K - Prime Video"), "Prime Video", "4K - weg")
eq(CategoryName.clean("NL | 4K - Netflix"), "Netflix", "twee voorvoegsels")
eq(CategoryName.clean("VOD: SkyShowtime"), "SkyShowtime", "VOD: weg")
eq(CategoryName.clean("Videoland 4K"), "Videoland", "4K achteraan weg")
eq(CategoryName.clean("NL: Sci-Fi"), "Sci-Fi", "streepje in de naam blijft")
eq(CategoryName.clean("Actie & Avontuur"), "Actie & Avontuur", "gewone naam blijft")
eq(CategoryName.clean("NL"), "NL", "alleen een label blijft staan")
let providers = ["Netflix": "/n.jpg", "Disney Plus": "/d.jpg", "HBO Max": "/h.jpg", "Amazon Prime Video": "/p.jpg",
                 "SkyShowtime": "/s.jpg", "Viaplay": "/v.jpg", "Videoland": "/vl.jpg", "Apple TV+": "/a.jpg"]
eq(ProviderMatch.match("NL | Netflix", providers: providers), "Netflix" as String?, "Netflix")
eq(ProviderMatch.match("Disney+", providers: providers), "Disney Plus" as String?, "Disney+ via de alias")
eq(ProviderMatch.match("NL | HBO", providers: providers), "HBO Max" as String?, "HBO via de alias")
eq(ProviderMatch.match("4K - Prime Video", providers: providers), "Amazon Prime Video" as String?, "Prime Video")
eq(ProviderMatch.match("Sky Showtime", providers: providers), "SkyShowtime" as String?, "Sky Showtime met spatie")
eq(ProviderMatch.match("Viaplay Series", providers: providers), "Viaplay" as String?, "begint met de dienst")
eq(ProviderMatch.match("VOD | Videoland", providers: providers), "Videoland" as String?, "Videoland")
eq(ProviderMatch.match("Apple TV+", providers: providers), "Apple TV+" as String?, "Apple TV+")
eq(ProviderMatch.match("Actie", providers: providers), nil as String?, "geen dienst")
eq(ProviderMatch.match("Netflix", providers: [:]), nil as String?, "zonder lijst (geen netwerk) geen logo")
check(ProviderMatch.paletteIndex("Netflix", count: 8) == ProviderMatch.paletteIndex("Netflix", count: 8), "vaste kleur op naam")

// MARK: build 149: bewaren in stukken (zelfde JSON, zonder volledige kopie in het geheugen)

struct Item149: Codable, Equatable { let id: String; let title: String; let group: String; let poster: URL?; let rating: Double?; let added: Date? }
struct Lib149: Codable, Equatable { var channels: [Item149] = []; var movies: [Item149] = []; var series: [Item149] = []; var epg: [String: [Item149]] = [:] }
func makeItems149(_ n: Int, _ p: String) -> [Item149] {
    var out: [Item149] = []
    out.reserveCapacity(n)
    for i in 0..<n {
        let poster: URL? = i % 3 == 0 ? nil : URL(string: "http://example.com/p/" + String(i) + ".jpg")
        let rating: Double? = i % 5 == 0 ? nil : Double(i % 100) / 10
        let added = Date(timeIntervalSince1970: 1_700_000_000 + Double(i))
        out.append(Item149(id: p + String(i), title: "Titel \"" + String(i) + "\" é ✓", group: "Groep " + String(i % 300),
                           poster: poster, rating: rating, added: added))
    }
    return out
}
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("selftest149-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    // klein: zelfde uitkomst, ook lege lijsten en een bestaand bestand overschrijven
    var small = Lib149(channels: makeItems149(5, "c"), movies: [], series: makeItems149(4501, "s"))
    small.epg = ["a": makeItems149(3, "e"), "b": [], "c\"x": makeItems149(1, "q")]
    let f = dir.appendingPathComponent("lib.json")
    try? Data("oud".utf8).write(to: f)
    func write(_ l: Lib149, _ url: URL, chunk: Int = 2000) throws {
        let w = try ChunkedJSONWriter(url: url, chunk: chunk)
        try w.array("channels", l.channels); try w.array("movies", l.movies); try w.array("series", l.series)
        try w.dictionary("epg", l.epg); try w.finish()
    }
    do {
        try write(small, f, chunk: 1000)
        let back = try JSONDecoder().decode(Lib149.self, from: Data(contentsOf: f))
        eq(back, small, "in stukken geschreven = origineel na inlezen")
        let viaWhole = try JSONDecoder().decode(Lib149.self, from: JSONEncoder().encode(small))
        eq(back, viaWhole, "zelfde als JSONEncoder in één keer")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        eq(left, ["lib.json"], "geen tijdelijke bestanden over")
    } catch { check(false, "schrijven in stukken: \(error)") }

    // groot: 123k films, 30k series, 12k zenders (zoals server 2): geheugen bij bewaren, vóór en na
    var big = Lib149(channels: makeItems149(12_000, "c"), movies: makeItems149(123_000, "m"), series: makeItems149(30_000, "s"))
    let f2 = dir.appendingPathComponent("big.json")
    var t0 = Date()
    let wholePeak = peakDuring148 { if let d = try? JSONEncoder().encode(big) { try? d.write(to: f2, options: .atomic) } }
    let wholeMs = Date().timeIntervalSince(t0) * 1000
    let wholeSize = (try? FileManager.default.attributesOfItem(atPath: f2.path)[.size] as? Int) ?? 0
    t0 = Date()
    let chunkPeak = peakDuring148 { try? write(big, f2) }
    let chunkMs = Date().timeIntervalSince(t0) * 1000
    let chunkSize = (try? FileManager.default.attributesOfItem(atPath: f2.path)[.size] as? Int) ?? 0
    eq(chunkSize, wholeSize, "zelfde bestandsgrootte")
    let back = try? JSONDecoder().decode(Lib149.self, from: Data(contentsOf: f2))
    eq(back?.movies.count, 123_000, "grote lijst terug ingelezen")
    print("build 149: bewaren 123k/30k/12k (\(wholeSize / 1_048_576) MB): in één keer +\(Int(wholePeak)) MB in \(Int(wholeMs)) ms, in stukken +\(Int(chunkPeak)) MB in \(Int(chunkMs)) ms")
    check(chunkPeak <= wholePeak + 5, "in stukken niet meer geheugen dan in één keer")
    big = Lib149()
}

// MARK: build 149: native strings bij het normaliseren

do {
    var titles: [String] = []
    for i in 0..<120_000 { titles.append("NL | Amélie de " + String(i % 977) + " Película (20" + String(i % 25 + 10) + ") [4K]") }
    var t0 = Date()
    var n1 = 0
    for t in titles { n1 += t.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).filter { $0.isLetter || $0.isNumber }.count }
    let bridgedMs = Date().timeIntervalSince(t0) * 1000
    t0 = Date()
    var n2 = 0
    for t in titles { n2 += t.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).nativeUTF8.filter { $0.isLetter || $0.isNumber }.count }
    let nativeMs = Date().timeIntervalSince(t0) * 1000
    eq(n2, n1, "zelfde uitkomst met native strings")
    t0 = Date()
    var n3 = 0
    for t in titles.prefix(30_000) { n3 += CatalogNorm.title(t).norm.count }
    let normMs = Date().timeIntervalSince(t0) * 1000 * 4
    check(n3 > 0, "titels genormaliseerd")
    print("build 149: 120k titels vouwen+filteren: overbrugd \(Int(bridgedMs)) ms, native \(Int(nativeMs)) ms; CatalogNorm.title 120k (geschat) \(Int(normMs)) ms")
}

// MARK: build 149: zoeken op woorden (accenten, volgorde, voorvoegsels, deelwoorden, typefout)

do {
    func sc(_ q: String, _ title: String, year: Int? = nil) -> Int? {
        let n = SearchMatch.normalize(title)
        return SearchMatch.score(SearchMatch.query(q), text: n.text, year: n.year ?? year)
    }
    eq(SearchMatch.normalize("NL | Amélie (2001)").text, "amelie", "voorvoegsel, accent en jaar weg")
    eq(SearchMatch.normalize("NL | Amélie (2001)").year, 2001, "jaar apart")
    eq(SearchMatch.normalize("Fast & Furious").text, "fast furious", "& telt niet mee")
    eq(SearchMatch.normalize("Fast and Furious").text, "fast furious", "and telt niet mee")
    eq(SearchMatch.normalize("Ex-Machina").text, "ex machina", "Ex- is geen label")
    eq(SearchMatch.normalize("(500) Days of Summer").text, "500 days of summer", "(500) blijft")
    eq(SearchMatch.normalize("[NL] Schindler's List 4K").text, "schindlers list", "[NL], apostrof en 4K")
    eq(sc("amelie", "NL | Amélie (2001)"), 1000, "zonder accent = exacte titel")
    eq(sc("AMÉLIE", "Amelie"), 1000, "hoofdletters en accent in de zoekterm")
    eq(sc("furious fast", "Fast & Furious"), 600, "woordvolgorde maakt niet uit")
    eq(sc("fast and furious", "Fast & Furious"), 1000, "and/& gelijk")
    eq(sc("batman", "[NL] The Batman"), 600, "woordbegin")
    eq(sc("the bat", "4K - The Batman"), 750, "begint met (deel van een woord)")
    eq(sc("the batman", "The Batman Returns"), 800, "begint met hele woorden")
    eq(sc("tman", "The Batman"), 400, "deel van een woord")
    eq(sc("dune two", "4K - Dune: Part Two"), 600, "woorden met voorvoegsel en leestekens")
    eq(sc("interstelar", "Interstellar"), 200, "één typefout bij 5+ letters")
    eq(sc("intrestellar", "Interstellar"), 200, "omgewisselde letters")
    eq(sc("btmn", "Batman"), nil as Int?, "geen typefout bij minder dan 5 letters")
    eq(sc("xyz", "Batman"), nil as Int?, "geen treffer")
    eq(sc("batman 2022", "The Batman (2022)"), 650, "jaartal in de zoekterm telt mee")
    eq(sc("ex machina", "Ex-Machina"), 1000, "Ex-Machina")
    eq(sc("500 days", "(500) Days of Summer"), 800, "(500) Days of Summer")
    eq(sc("npo 1", "NL: NPO 1 FHD"), 1000, "zender met voorvoegsel en kwaliteit")
    check(SearchMatch.boost(rating: 8, added: Date()) > SearchMatch.boost(rating: 5, added: nil), "recent en populair iets hoger")
    // snelheid: 123k titels met vooraf berekende sleutels
    var keys: [String] = []
    for i in 0..<123_000 { keys.append(SearchMatch.normalize("NL | Film nummer " + String(i) + " Deel " + String(i % 7) + " (2020)").text) }
    let q = SearchMatch.query("nummer deel 3")
    let t0 = Date()
    var hits = 0
    for k in keys where SearchMatch.score(q, text: k) != nil { hits += 1 }
    let ms = Date().timeIntervalSince(t0) * 1000
    check(hits > 0, "treffers in 123k titels")
    print("build 149: zoeken in 123k titels (vooraf berekende sleutels): \(Int(ms)) ms, \(hits) treffers")
}

// MARK: build 150: taal- en landvoorvoegsels overal weg, gelijke categorieën samen

do {
    func cn(_ s: String) -> String { CategoryName.clean(s) }
    // voorbeelden uit de opdracht
    eq(cn("| NL | NETFLIX"), "Netflix", "| NL | NETFLIX")
    eq(cn("| MULTI / LINGO | NETFLIX"), "Netflix", "| MULTI / LINGO | NETFLIX")
    eq(cn("NL: Bioscoop"), "Bioscoop", "NL: Bioscoop")
    eq(cn("[EN] Disney+ 4K"), "Disney+", "[EN] Disney+ 4K")
    eq(cn("BE ¦ VTM GO"), "VTM GO", "BE ¦ VTM GO")
    eq(cn("NETFLIX (NL)"), "Netflix", "NETFLIX (NL)")
    eq(cn("TR - DIZI"), "Dizi", "TR - DIZI")
    eq(cn("4K | UHD | SPORT"), "Sport", "4K | UHD | SPORT")
    eq(cn("| NL | BIOSCOOP"), "Bioscoop", "rijkop | NL | BIOSCOOP")
    eq(cn("| NL | VIDEOLAND"), "Videoland", "| NL | VIDEOLAND")
    // randgevallen
    eq(cn("NL"), "NL", "alleen NL blijft")
    eq(cn("4K"), "4K", "4K als echte categorie blijft")
    eq(cn("| NL |"), "NL", "alleen een label met pipes")
    eq(cn("Kids NL"), "Kids", "Kids NL")
    eq(cn("NL Kids"), "Kids", "NL Kids")
    eq(cn("│ NL │ Netflix"), "Netflix", "box-pipe")
    eq(cn("｜EN｜ Netflix"), "Netflix", "brede pipe")
    eq(cn("NL • Netflix"), "Netflix", "punt")
    eq(cn("» NL « Netflix"), "Netflix", "» «")
    eq(cn("★ NL ★ Netflix"), "Netflix", "sterren")
    eq(cn("{NL} Netflix"), "Netflix", "accolades")
    eq(cn("NL — Netflix"), "Netflix", "lang streepje")
    eq(cn("MULTI-LINGO: Netflix"), "Netflix", "MULTI-LINGO")
    eq(cn("MULTI LANG | Netflix"), "Netflix", "MULTI LANG")
    eq(cn("MULTISUB | Netflix"), "Netflix", "MULTISUB")
    eq(cn("VOSTFR - Netflix"), "Netflix", "VOSTFR")
    eq(cn("SERIES | NETFLIX"), "Netflix", "SERIES als voorvoegsel")
    eq(cn("FILMS: Actie"), "Actie", "FILMS als voorvoegsel")
    eq(cn("Series"), "Series", "SERIES alleen blijft")
    eq(cn("Nederlands | Kids"), "Kids", "taal voluit")
    eq(cn("Dutch: Kids"), "Kids", "Dutch voluit")
    eq(cn("Kids - Vlaams"), "Kids", "taal voluit achteraan")
    eq(cn("Netflix - NL"), "Netflix", "- NL achteraan")
    eq(cn("Netflix [MULTI]"), "Netflix", "[MULTI] achteraan")
    eq(cn("NL | HEVC | H265 | HDR | Films 2024"), "Films 2024", "kwaliteit in de rij")
    eq(cn("NLD | Netflix"), "Netflix", "drieletterig")
    eq(cn("SCI-FI"), "Sci-Fi", "SCI-FI blijft heel")
    eq(cn("NL: Sci-Fi"), "Sci-Fi", "Sci-Fi blijft heel")
    eq(cn("AC/DC Live"), "AC/DC Live", "AC/DC blijft")
    eq(cn("Actie & Avontuur"), "Actie & Avontuur", "gewone naam")
    eq(cn("Disney+"), "Disney+", "Disney+")
    eq(cn("NPO 1 FHD"), "NPO 1", "NPO 1 FHD")
    eq(cn("Serie A"), "Serie A", "Serie A")
    // hoofdletters
    eq(cn("NL | HBO MAX"), "HBO Max", "HBO Max")
    eq(cn("BBC"), "BBC", "BBC")
    eq(cn("UK | BBC ONE"), "BBC One", "BBC One")
    eq(cn("NL | NPO START"), "NPO Start", "NPO Start")
    eq(cn("NL | RTL 4"), "RTL 4", "RTL 4")
    eq(cn("NL | SBS6"), "SBS6", "SBS6")
    eq(cn("US | ESPN"), "ESPN", "ESPN")
    eq(cn("F1 TV"), "F1 TV", "F1 TV")
    eq(cn("SKYSHOWTIME"), "SkyShowtime", "SkyShowtime")
    eq(cn("NL | ZIGGO SPORT"), "Ziggo Sport", "Ziggo Sport")
    eq(cn("TOP 10"), "Top 10", "woord met cijfer blijft, TOP wordt Top")
    eq(cn("NL | DE BESTE FILMS"), "De Beste Films", "DE als lidwoord")
    eq(cn("Netflix"), "Netflix", "gemengd blijft")
    // labels (chips) en snelknoppen
    eq(CategoryName.parse("| MULTI / LINGO | NETFLIX").labels, ["Multi"], "label Multi")
    eq(CategoryName.parse("| NL | NETFLIX").labels, ["NL"], "label NL")
    eq(CategoryName.prefixLabel("BE ¦ VTM GO"), "BE" as String?, "snelknop BE")
    eq(CategoryName.prefixLabel("Netflix"), nil as String?, "geen voorvoegsel")
    eq(CategoryName.prefixLabel("NLD | Netflix"), "NL" as String?, "NLD = NL")
    // samenvoegen (hoofdletterongevoelig, over talen en kwaliteit heen)
    let a = CategoryName.mergeKey(cn("| NL | NETFLIX")), b = CategoryName.mergeKey(cn("| MULTI / LINGO | NETFLIX"))
    eq(a, b, "Netflix 2x = 1 categorie")
    eq(CategoryName.mergeKey(cn("4K | Netflix")), a, "Netflix 4K = Netflix")
    check(CategoryName.mergeKey(cn("NL | Videoland")) != a, "Videoland apart")
    // ontdubbelen
    struct T150 { let id: String; let title: String; let year: Int?; let tmdb: Int? }
    let items = [T150(id: "1", title: "The Batman", year: 2022, tmdb: 414906), T150(id: "2", title: "The Batman", year: 2022, tmdb: 414906),
                 T150(id: "3", title: "Dune", year: 2021, tmdb: nil), T150(id: "4", title: "DUNE", year: 2021, tmdb: nil),
                 T150(id: "5", title: "Halloween", year: nil, tmdb: nil), T150(id: "6", title: "Halloween", year: nil, tmdb: nil)]
    let u = CategoryMerge.unique(items) { CategoryMerge.titleKey(id: $0.id, title: $0.title, year: $0.year, tmdb: $0.tmdb, imdb: nil) }
    eq(u.map(\.id), ["1", "3", "5", "6"], "zelfde TMDB-id of titel + jaar één keer; zonder jaar niet samen")
    let pref = CategoryMerge.unique(items.prefix(2).map { $0 }, key: { _ in "x" }, better: { n, _ in n.id == "2" })
    eq(pref.map(\.id), ["2"], "voorkeursbron")
    // logo's: de opgeschoonde naam matcht
    let prov150 = ["Netflix": "/n", "Videoland": "/v", "Disney Plus": "/d", "HBO Max": "/h", "Amazon Prime Video": "/p",
                   "SkyShowtime": "/s", "Viaplay": "/vp", "Apple TV+": "/a", "NPO Start": "/npo"]
    eq(ProviderMatch.match("| NL | NETFLIX", providers: prov150), "Netflix" as String?, "logo Netflix")
    eq(ProviderMatch.match("| MULTI / LINGO | NETFLIX", providers: prov150), "Netflix" as String?, "logo Netflix (multi)")
    eq(ProviderMatch.match("| NL | VIDEOLAND", providers: prov150), "Videoland" as String?, "logo Videoland")
    eq(ProviderMatch.match("[EN] Disney+ 4K", providers: prov150), "Disney Plus" as String?, "logo Disney+")
    eq(ProviderMatch.match("NL | HBO MAX", providers: prov150), "HBO Max" as String?, "logo HBO Max")
    eq(ProviderMatch.match("NL | HBO MAX", providers: ["Max": "/m"]), "Max" as String?, "logo HBO Max als Max")
    eq(ProviderMatch.match("NL ¦ PRIME VIDEO", providers: prov150), "Amazon Prime Video" as String?, "logo Prime Video")
    eq(ProviderMatch.match("NL | SKYSHOWTIME", providers: prov150), "SkyShowtime" as String?, "logo SkyShowtime")
    eq(ProviderMatch.match("NL | VIAPLAY", providers: prov150), "Viaplay" as String?, "logo Viaplay")
    eq(ProviderMatch.match("EN | APPLE TV+", providers: prov150), "Apple TV+" as String?, "logo Apple TV+")
    eq(ProviderMatch.match("EN | APPLE TV+", providers: ["Apple TV": "/a"]), "Apple TV" as String?, "logo Apple TV (nieuwe naam)")
    eq(ProviderMatch.match("NL | NPO START", providers: prov150), "NPO Start" as String?, "logo NPO Start")
    eq(ProviderMatch.match("NL | NPO", providers: ["NPO Plus": "/np"]), "NPO Plus" as String?, "logo NPO Plus")
    // zoeken: dezelfde pipes
    eq(SearchMatch.normalize("│NL│ Amélie (2001)").text, "amelie", "zoeken met box-pipe")
    // snelheid: 2000 categorieën
    let t0 = Date()
    for i in 0..<2000 { _ = CategoryName.parse("| NL | CATEGORIE \(i) 4K") }
    let ms = Date().timeIntervalSince(t0) * 1000
    print("build 150: 2000 categorienamen opschonen \(Int(ms)) ms")
    check(ms < 2000, "2000 categorienamen binnen 2 s")
}

// MARK: build 151: verborgen categorieën niet inlezen (tellen + compacte zoekindex), bronvoorkeur bij samenvoegen

struct Dto151: Decodable { let stream_id: Int; let name: String?; let stream_icon: String?; let category_id: String?
                           let container_extension: String?; let rating: String?; let added: String?; let year: String? }
/// Zoals `Movie` in de app (twee URL's, datum, getallen)
struct Full151 { var id: String; var title: String; var year: Int?; var poster: URL?; var group: String; var streamURL: URL?
                 var rating: Double?; var addedAt: Date?; var vodID: Int?; var plot: String? }
func json151(_ n: Int, prefix: String, cats: Int) -> Data {
    var out = "["
    out.reserveCapacity(n * 230)
    for i in 0..<n {
        if i > 0 { out += "," }
        out += "{\"num\":\(i),\"name\":\"NL | \(prefix) titel \(i) (20\(10 + i % 15))\",\"stream_type\":\"movie\",\"stream_id\":\(i),"
        out += "\"stream_icon\":\"http://img.example.com/posters/\(prefix)/\(i).jpg\",\"rating\":\"\(i % 10).5\",\"rating_5based\":3.2,"
        out += "\"added\":\"\(1_700_000_000 + i)\",\"category_id\":\"\(i % cats)\",\"container_extension\":\"mkv\",\"custom_sid\":\"\",\"direct_source\":\"\"}"
    }
    return Data((out + "]").utf8)
}
do {
    // klein: tellen per categorie, rijen, geleverd, opnieuw ophalen
    let skip = SkipFilter { $0.hasPrefix("FR") }
    let b = SkippedCatalog.Builder()
    var asked = 0
    let memo = SkipFilter { g in asked += 1; return g == "X" }
    for _ in 0..<5 { _ = memo.skip("X"); _ = memo.skip("Y") }
    eq(asked, 2, "per categorie één keer gevraagd")
    check(skip.skip("FR | Films") && !skip.skip("NL | Films"), "verborgen categorie")
    b.count(.live, "FR | Info"); b.count(.live, "FR | Info"); b.count(.live, "FR | Sport")
    b.add(.movie, id: "xv1", title: "FR | Amélie (2001)", group: "FR | Films", year: 2001, poster: "http://x/1.jpg", ext: "mkv", tmdb: 194)
    b.add(.movie, id: "xv2", title: "FR | Léon", group: "FR | Films", ext: "mp4")
    b.add(.series, id: "xs9", title: "FR | Lupin", group: "FR | Séries")
    let sk = b.finish()!
    eq(sk.count(.live), 3, "zenders geteld")
    eq(sk.count(.movie), 2, "films geteld")
    eq(sk.counts(.live)["FR | Info"], 2 as Int?, "per categorie")
    eq(sk.groupNames(.live), ["FR | Info", "FR | Sport"], "volgorde categorieën")
    eq(sk.rows.count, 3, "alleen films en series als rij")
    eq(sk.group(of: sk.rows[2]), "FR | Séries", "categorie van een rij")
    eq(sk.rows[1].x, nil as String?, "mp4 niet bewaard")
    eq(sk.rows[0].x, "mkv" as String?, "andere extensie wel")
    eq(SkippedCatalog.delivered(loaded: 10, sk, .live), 13, "geleverd = ingelezen + overgeslagen")
    let gc = SkippedCatalog.groupCounts(loaded: ["NL | Info", "NL | Info", "FR | Info"], sk, .live)
    eq(gc.map(\.group), ["NL | Info", "FR | Info", "FR | Sport"], "categorieën met de overgeslagen erbij")
    eq(gc.map(\.count), [2, 3, 1], "aantallen opgeteld")
    check(!sk.needsRefetch(stillHidden: { $0.hasPrefix("FR") }), "alles nog verborgen: niet opnieuw ophalen")
    check(sk.needsRefetch(stillHidden: { $0 != "FR | Sport" }), "categorie aangezet: opnieuw ophalen")
    check(SkippedCatalog.Builder().finish() == nil, "niets overgeslagen = geen index")
    let back = try? JSONDecoder().decode(SkippedCatalog.self, from: JSONEncoder().encode(sk))
    eq(back, sk, "index bewaren en terug inlezen")

    // bronvoorkeur
    let want = SourcePreference.want(audio: ["nl"], app: "en")
    eq(want, ["NL", "BE", "EN", "UK", "US"], "gewenste labels: audio eerst, dan app-taal")
    check(SourcePreference.rank(group: "| NL | NETFLIX", want: want) < SourcePreference.rank(group: "| MULTI | NETFLIX", want: want), "NL voor Multi")
    check(SourcePreference.rank(group: "| MULTI | NETFLIX", want: want) < SourcePreference.rank(group: "| DE | NETFLIX", want: want), "Multi voor DE")
    check(SourcePreference.rank(group: "EN | Netflix", want: want) < SourcePreference.rank(group: "Netflix", want: want), "EN voor zonder label")
    check(!SourcePreference.better("DE | Netflix", than: "FR | Netflix", want: want), "gelijke rang: de eerste blijft")
    struct T151 { let id: String; let key: String; let group: String }
    let items = [T151(id: "a", key: "k1", group: "DE | Netflix"), T151(id: "b", key: "k1", group: "NL | Netflix"),
                 T151(id: "c", key: "k2", group: "MULTI | Netflix"), T151(id: "d", key: "k2", group: "DE | Netflix")]
    let u = CategoryMerge.unique(items, key: { $0.key }, better: { SourcePreference.better($0.group, than: $1.group, want: want) })
    eq(u.map(\.id), ["b", "c"], "dubbel: NL wint van DE, Multi van DE")

    // groot: 123k films, 30k series, 12k zenders, 80% in verborgen categorieën (100 categorieën per soort, 0–79 uit)
    let sizes = [("m", 123_000), ("s", 30_000), ("c", 12_000)]
    func run(skipping: Bool) -> (peak: Double, kept: Double, full: Int, rows: Int, ms: Double, cacheMB: Double) {
        var full: [Full151] = []
        var catalog: SkippedCatalog?
        var keptMB = 0.0, cacheMB = 0.0
        let t0 = Date()
        let peak = peakDuring148 {
            let base = footprintMB148()
            let builder = SkippedCatalog.Builder()
            let filter = SkipFilter { g in (Int(g.dropFirst(4)) ?? 0) < 80 }
            for (p, n) in sizes {
                var data: Data? = json151(n, prefix: p, cats: 100)
                let kind: SkippedCatalog.Kind = p == "m" ? .movie : (p == "s" ? .series : .live)
                _ = JSONChunks.decode(Dto151.self, from: data!, chunk: 1500) { chunk in
                    for v in chunk {
                        let g = "Cat " + (v.category_id ?? "0")
                        if skipping, filter.skip(g) {
                            if kind == .live { builder.count(.live, g) }
                            else { builder.add(kind, id: "x" + p + String(v.stream_id), title: v.name ?? "", group: g,
                                               year: v.year.flatMap { Int($0) }, poster: v.stream_icon, ext: v.container_extension) }
                            continue
                        }
                        full.append(Full151(id: "x" + p + String(v.stream_id), title: v.name ?? "", year: v.year.flatMap { Int($0) },
                                            poster: v.stream_icon.flatMap { URL(string: $0) }, group: g,
                                            streamURL: URL(string: "http://server.example.com:8080/movie/user/pass/\(v.stream_id).mkv"),
                                            rating: v.rating.flatMap { Double($0) }, addedAt: v.added.flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) },
                                            vodID: v.stream_id, plot: nil))
                    }
                }
                data = nil
            }
            catalog = builder.finish()
            keptMB = footprintMB148() - base
            // bewaarde lijst (cache): grootte van de index
            if let c = catalog, let d = try? JSONEncoder().encode(c) { cacheMB = Double(d.count) / 1_048_576 }
        }
        let ms = Date().timeIntervalSince(t0) * 1000
        let out = (peak, keptMB, full.count, catalog?.rows.count ?? 0, ms, cacheMB)
        full = []; catalog = nil
        return out
    }
    let before = run(skipping: false)
    let after = run(skipping: true)
    eq(before.full, 165_000, "zonder overslaan alles ingelezen")
    eq(after.full, 33_000, "met overslaan 20% ingelezen")
    eq(after.rows, 122_400, "films en series uit verborgen categorieën in de zoekindex")
    print("build 151: 123k/30k/12k, 80% verborgen: vóór piek +\(Int(before.peak)) MB, vast +\(Int(before.kept)) MB (\(Int(before.ms)) ms); "
          + "na piek +\(Int(after.peak)) MB, vast +\(Int(after.kept)) MB (\(Int(after.ms)) ms), index \(String(format: "%.1f", after.cacheMB)) MB als JSON")
    check(after.kept < before.kept * 0.7, "vast geheugen met overslaan duidelijk lager (\(Int(after.kept)) vs \(Int(before.kept)) MB)")
}

// MARK: build 151: rij Zenders op Home
do {
    let groups: [(group: String, ids: [String])] = [("Klein", ["k1"]), ("Groot", ["g1", "g2", "g3", "g4"]), ("Midden", ["m1", "m2", "m3"])]
    let logo: (String) -> Bool = { $0 != "g2" }
    eq(ChannelLogoRow.pick(first: ["m2", "x9", "m2"], groups: groups, hasLogo: logo, max: 6), ["m2", "x9", "g1", "m1", "k1", "g3"],
       "recent/favorieten eerst, dan om de beurt uit de grootste categorieën, met logo eerst")
    eq(ChannelLogoRow.pick(first: [], groups: groups, hasLogo: logo, max: 20).count, 8, "alle zenders hooguit één keer")
    eq(ChannelLogoRow.pick(first: [], groups: groups, hasLogo: logo, max: 20).last, "g2", "zonder logo als laatste")
    eq(ChannelLogoRow.pick(first: (0..<30).map { "r\($0)" }, groups: groups, hasLogo: logo).count, 15, "hooguit 15")
}

// MARK: build 151: geen dubbele titels op Home bij twee servers
do {
    struct H151 { let id: String; let server: String; let title: String; let year: Int?; let tmdb: Int?; let audio: String?; let at: Double }
    // server A (actief) en B met overlappende titels
    let a = [H151(id: "a1", server: "A", title: "The Batman", year: 2022, tmdb: 414906, audio: "en", at: 5),
             H151(id: "a2", server: "A", title: "Dune", year: 2021, tmdb: nil, audio: nil, at: 4),
             H151(id: "a3", server: "A", title: "Oppenheimer", year: 2023, tmdb: 872585, audio: nil, at: 1)]
    let b = [H151(id: "b1", server: "B", title: "The Batman", year: 2022, tmdb: nil, audio: "nl", at: 9),
             H151(id: "b2", server: "B", title: "Dune", year: 2021, tmdb: 438631, audio: nil, at: 8),
             H151(id: "b3", server: "B", title: "Barbie", year: 2023, tmdb: 346698, audio: nil, at: 2),
             H151(id: "b4", server: "B", title: "Oppenheimer", year: 2023, tmdb: 872585, audio: nil, at: 7)]
    func keys(_ x: H151) -> [String] { HomeDedupe.titleKeys(series: false, title: x.title, year: x.year, tmdb: x.tmdb, imdb: nil) }
    func rank(_ x: H151) -> Int { HomeDedupe.rank(audio: x.audio, multi: false, preferredAudio: "nl", appLanguage: "nl", active: x.server == "A") }
    let row = HomeDedupe.unique(a + b, keys: keys, rank: rank)
    eq(row.map(\.id), ["b1", "a2", "a3", "b3"], "één per titel: NL-bron wint, anders de actieve server")
    let byTitle = Dictionary(grouping: row, by: { $0.title })
    check(byTitle.values.allSatisfy { $0.count == 1 }, "geen dubbelen in de rij")
    // Verder kijken: op tijd (nieuwste eerst), dezelfde titel één tegel met de meest recente voortgang
    let cont = HomeDedupe.unique((a + b).sorted { $0.at > $1.at }, keys: keys)
    eq(cont.map(\.id), ["b1", "b2", "b4", "b3"], "Verder kijken: meest recente voortgang blijft")
    // zenders op de opgeschoonde naam
    eq(HomeDedupe.channelKey("NL | NPO 1"), HomeDedupe.channelKey("NPO 1"), "zender: zelfde opgeschoonde naam")
    let ch = HomeDedupe.unique(["NL | NPO 1", "RTL 4", "NPO 1", "NL: RTL 4"], keys: { [HomeDedupe.channelKey($0)] })
    eq(ch, ["NL | NPO 1", "RTL 4"], "zenders ontdubbeld")
    eq(HomeDedupe.rank(audio: nil, multi: true, preferredAudio: "nl", appLanguage: "en", active: false), 5, "meertalig, andere server")
}

// MARK: build 152: verborgen categorieën goed verwerken (samengevoegd, sync, overslaan, weer aanzetten)
do {
    let sidA = "6F1C2D3E-0000-4000-8000-00000000000A", sidB = "6F1C2D3E-0000-4000-8000-00000000000B"
    // zoals Instellingen → Categorieën: per samenvoegsleutel één regel met per server de exacte namen
    let raws: [(sid: String, name: String)] = [(sidA, "| NL | NETFLIX"), (sidA, "| MULTI / LINGO | NETFLIX"), (sidB, "NL: Netflix HD"),
                                               (sidA, "| NL | VIDEOLAND"), (sidB, "FR | Films")]
    var map: [String: [(sid: String, name: String)]] = [:]
    var shownOf: [String: String] = [:]
    for r in raws {
        let name = CategoryName.parse(r.name).name, k = CategoryName.mergeKey(name)
        let shown = shownOf[k] ?? name
        shownOf[k] = shown
        map[shown, default: []].append(r)
    }
    eq(map.keys.sorted(), ["Films", "Netflix", "Videoland"], "samengevoegd: één regel Netflix")
    let netflix = CategoryHide.sources(of: "Netflix", in: map)
    eq(netflix.map { $0.name }, ["| NL | NETFLIX", "| MULTI / LINGO | NETFLIX", "NL: Netflix HD"], "Netflix: alle bronnen, exacte namen")
    // andere spelling na opnieuw opbouwen: via de samenvoegsleutel, nooit de weergavenaam als bron
    eq(CategoryHide.sources(of: "NETFLIX", in: map).count, 3, "andere spelling vindt dezelfde bronnen")
    eq(CategoryHide.sources(of: "Bestaat niet", in: map).count, 0, "onbekend: geen bron (geen opgeschoonde sleutel)")

    // verbergen: sleutels met de exacte ruwe naam, server-id klein
    let keys = CategoryHide.keys(netflix)
    eq(keys, [sidA.lowercased() + "|| NL | NETFLIX", sidA.lowercased() + "|| MULTI / LINGO | NETFLIX", sidB.lowercased() + "|NL: Netflix HD"],
       "sleutels: server-id klein + exacte naam")
    check(!keys.contains { $0.hasSuffix("|Netflix") }, "geen opgeschoonde naam in een sleutel")
    var set = Set(keys)
    let gA = AccountCategories.groups(set, sid: sidA), gB = AccountCategories.groups(set, sid: sidB)
    check(CategoryHide.hidden("| NL | NETFLIX", merged: [:], groups: gA) && CategoryHide.hidden("| MULTI / LINGO | NETFLIX", merged: [:], groups: gA),
          "beide bronnen op server A uit")
    check(CategoryHide.hidden("NL: Netflix HD", merged: [:], groups: gB), "bron op server B uit")
    check(!CategoryHide.hidden("| NL | VIDEOLAND", merged: [:], groups: gA), "andere categorie blijft aan")
    // een (fout) opgeschoonde sleutel verbergt niets: daarom mag die er nooit in
    check(!CategoryHide.hidden("| NL | NETFLIX", merged: [:], groups: AccountCategories.groups([sidA.lowercased() + "|Netflix"], sid: sidA)),
          "opgeschoonde sleutel verbergt de ruwe naam niet")
    // samengevoegd in Beheren (Videoland → Netflix): volgt het doel, zoals Android
    check(CategoryHide.hidden("| NL | VIDEOLAND", merged: ["| NL | VIDEOLAND": "| NL | NETFLIX"], groups: gA), "samengevoegd in Beheren: doel uit = uit")
    check(!CategoryHide.hidden("x", merged: ["x": "x"], groups: []), "lege set: niets uit")

    // sync: apparaat 1 (Apple) zet uit, apparaat 2 (Android/web) voegt samen: dezelfde sleutels, dezelfde betekenis
    let local = ListMerge.diff((present: [:], removed: [:]), current: set, now: 1000)
    let other = ListMerge.merge(local: (present: [:], removed: [:]), server: local)
    eq(Set(other.present.keys), set, "sync: zelfde sleutels op het andere apparaat")
    // oude sleutel (build 128, server-id in hoofdletters) betekent hetzelfde
    eq(AccountCategories.normalize(sidA + "|| NL | NETFLIX"), keys[0], "oude sleutel met hoofdletters = nieuwe sleutel")
    eq(AccountCategories.groups([sidA + "|| NL | NETFLIX"], sid: sidA), Set(["| NL | NETFLIX"]), "oude sleutel leest als dezelfde categorie")

    // weer tonen: alle bronnen tegelijk aan, als verwijdering gesynct
    for k in keys { set.remove(k) }
    let back = ListMerge.diff(local, current: set, now: 2000)
    check(keys.allSatisfy { back.removed[$0] == 2000 && back.present[$0] == nil }, "weer aan: verwijdering per bron")
    let other2 = ListMerge.merge(local: other, server: back)
    check(other2.present.isEmpty, "weer aan op het andere apparaat")

    // overslaan bij het inlezen en terugkomen na weer aanzetten (ook na herstart: de samenvatting is bewaard)
    let hiddenA = AccountCategories.groups(Set(keys), sid: sidA)
    let skip = SkipFilter { CategoryHide.hidden($0, merged: [:], groups: hiddenA) }
    let b = SkippedCatalog.Builder()
    var loaded: [String] = []
    for (i, g) in ["| NL | NETFLIX", "| NL | VIDEOLAND", "| MULTI / LINGO | NETFLIX", "| NL | NETFLIX"].enumerated() {
        if skip.skip(g) { b.add(.movie, id: "xv\(i)", title: "T\(i)", group: g) } else { loaded.append(g) }
    }
    let sk = b.finish()!
    eq(loaded, ["| NL | VIDEOLAND"], "verborgen bronnen niet ingelezen")
    eq(sk.count(.movie), 3, "overgeslagen geteld")
    let sum = sk.summary
    eq(sum.rows.count, 0, "samenvatting zonder zoekindex")
    eq(sum.count(.movie), 3, "samenvatting houdt de aantallen")
    let restored = try? JSONDecoder().decode(SkippedCatalog.self, from: JSONEncoder().encode(sum))
    eq(restored, sum, "samenvatting bewaren en terug inlezen (herstart)")
    check(!sum.needsRefetch(stillHidden: { CategoryHide.hidden($0, merged: [:], groups: hiddenA) }), "nog uit: niet opnieuw ophalen")
    check(sum.needsRefetch(stillHidden: { CategoryHide.hidden($0, merged: [:], groups: []) }), "weer aan: opnieuw ophalen (ook andere server)")
    // kinderprofiel: account-verbergen telt niet, alleen kindercategorieën; een overgeslagen kindercategorie komt terug
    let kidsSum = { () -> SkippedCatalog in let k = SkippedCatalog.Builder(); k.count(.movie, "NL | Kids"); k.count(.movie, "NL | Horror"); return k.finish()! }()
    check(kidsSum.needsRefetch(stillHidden: { !KidsCategory.isKids($0) }), "kinderprofiel: verborgen kindercategorie opnieuw ophalen")
    check(!SkippedCatalog(cats: [.init(k: .movie, g: "NL | Horror", n: 4)]).needsRefetch(stillHidden: { !KidsCategory.isKids($0) }),
          "kinderprofiel: geen kindercategorie = niet ophalen")

    // opnieuw ophalen: nu, later (er loopt al iets) of niet
    eq(CategoryHide.refetch(needed: true, busy: false), .now, "weer aan, niets bezig: nu ophalen")
    eq(CategoryHide.refetch(needed: true, busy: true), .later, "weer aan tijdens bijwerken: daarna alsnog")
    eq(CategoryHide.refetch(needed: false, busy: true), .none, "niets weer aan: niets doen")
}

// MARK: build 152: rij Nu in de bioscoop
do {
    let rows = [NowPlaying.Row(id: 1, popularity: 10, adult: false), NowPlaying.Row(id: 2, popularity: 50, adult: false),
                NowPlaying.Row(id: 3, popularity: 99, adult: true), NowPlaying.Row(id: 2, popularity: 50, adult: false),
                NowPlaying.Row(id: 4, popularity: 10, adult: false), NowPlaying.Row(id: 0, popularity: 80, adult: false)]
    eq(NowPlaying.pick(rows), [2, 1, 4], "populairste eerst, zonder volwassenen/dubbele, gelijk = TMDB-volgorde")
    eq(NowPlaying.pick((1...40).map { NowPlaying.Row(id: $0, popularity: Double($0), adult: false) }).count, 20, "hooguit 20")
    eq(NowPlaying.pick([]), [], "leeg: geen rij")
    eq(NowPlaying.region, "NL", "regio NL")
}

// MARK: build 153: landaanduidingen tussen pipes overal weg (┃NL┃, ｜DE｜, | MULTI / LINGO |), ook bij zendernamen
do {
    func cn(_ s: String) -> String { CategoryName.clean(s) }
    func ch(_ s: String) -> String { CategoryName.channel(s) }
    // dezelfde gevallen voor categorieën en zendernamen (gelijk aan Android en web)
    let cases153: [(String, String)] = [
        ("┃NL┃ NPO 1", "NPO 1"), ("┃NL┃NPO 1", "NPO 1"), ("|NL| Netflix", "Netflix"),
        ("| MULTI / LINGO | NETFLIX", "Netflix"), ("┃NL┃ ┃HD┃ RTL 4", "RTL 4"), ("NL┃ Videoland", "Videoland"),
        ("RTL 4 ┃NL┃", "RTL 4"), ("｜DE｜ Sky Cinema", "Sky Cinema"), ("Kids | NL", "Kids"), ("Film | 2024", "Film | 2024"),
        ("NL ┃ NPO 1", "NPO 1"), ("NL┃NPO 1", "NPO 1"), ("|NL||HD|NPO 2", "NPO 2"), ("┇NL┇ NPO 3", "NPO 3"),
        ("❘NL❘ NPO 1", "NPO 1"), ("︳NL︳ NPO 1", "NPO 1"), ("ǀNLǀ NPO 1", "NPO 1"), ("⏐NL⏐ NPO 1", "NPO 1"),
        ("|4K| Netflix", "Netflix"), ("|NL| |HD| Videoland", "Videoland"), ("|Iets Willekeurigs| Netflix", "Netflix"),
    ]
    for (raw, want) in cases153 {
        eq(cn(raw), want, "categorie \(raw)")
        eq(ch(raw), want, "zender \(raw)")
    }
    // alleen een stuk tussen pipes: nooit leeg
    check(!cn("|ABC 123|").isEmpty && cn("|ABC 123|").contains("ABC"), "categorie |ABC 123| niet leeg")
    check(!ch("|ABC 123|").isEmpty && ch("|ABC 123|").contains("ABC"), "zender |ABC 123| niet leeg")
    eq(cn("|NL|"), "NL", "categorie alleen |NL|")
    eq(ch("|NL|"), "NL", "zender alleen |NL|")
    check(cn("Film | 2024").contains("Film"), "Film blijft")
    // labels (chips) blijven werken
    eq(CategoryName.parse("┃NL┃ NETFLIX").labels, ["NL"], "label NL uit ┃NL┃")
    eq(CategoryName.parse("┃NL┃ NETFLIX").prefixLabels, ["NL"], "snelknop NL uit ┃NL┃")
    eq(CategoryName.parse("RTL 4 ┃NL┃").prefixLabels, [], "achteraan is geen snelknop")
    // een lang stuk tussen pipes (> 25 tekens) blijft
    let long = "|Dit is een hele lange categorienaam| Netflix"
    check(cn(long).contains("lange"), "lang stuk tussen pipes blijft")
    // zenders zonder pipe blijven zoals ze zijn (kwaliteit zonder pipe blijft: HD en SD zijn verschillende zenders)
    eq(ch("NPO 1 HD"), "NPO 1 HD", "zender NPO 1 HD blijft")
    eq(ch("NPO 1 SD"), "NPO 1 SD", "zender NPO 1 SD blijft")
    eq(ch("Ziggo Sport 2"), "Ziggo Sport 2", "gewone zender blijft")
    eq(ch("NL | NPO 1 HD"), "NPO 1 HD", "zender: alleen NL weg")
    eq(ch("NL: NPO 1"), "NL: NPO 1", "zender zonder pipe ongewijzigd")
    // titels en zoeken
    eq(SearchMatch.normalize("┃NL┃The Batman (2022)").text, "the batman", "zoeken ┃NL┃ zonder spatie")
    eq(SearchMatch.normalize("| MULTI / LINGO | The Witcher").text, "the witcher", "zoeken MULTI / LINGO")
    eq(SearchMatch.normalize("｜DE｜ Dune").text, "dune", "zoeken ｜DE｜")
    eq(CategoryName.clean("┃NL┃ ┃4K┃ Dune", title: true), "Dune", "titel met twee pipe-stukken")
    eq(CategoryName.clean("Dune", title: true), "Dune", "gewone titel blijft")
    // pipeBlocks zelf
    check(CategoryName.pipeBlocks("Netflix") == nil, "zonder pipes: niets")
    check(CategoryName.pipeBlocks("|NL|") == nil, "alleen een stuk: niets (oude opschoning)")
    eq(CategoryName.pipeBlocks("|NL| |HD| RTL 4 |EN|")?.blocks ?? [], ["NL", "HD", "EN"], "stukken voor- en achteraan")
    eq(CategoryName.pipeBlocks("|NL| |HD| RTL 4 |EN|")?.leading ?? -1, 2, "twee vooraan")
    // snelheid: 20.000 zendernamen
    let t0 = Date()
    for i in 0..<20_000 { _ = CategoryName.channel("┃NL┃ ┃HD┃ ZENDER \(i)") }
    let ms = Date().timeIntervalSince(t0) * 1000
    print("build 153: 20000 zendernamen opschonen \(Int(ms)) ms")
    check(ms < 4000, "20000 zendernamen binnen 4 s")
}

// MARK: build 154: gezien over alle servers (inhoudssleutels) en betrouwbare Trakt-sync
// De gedeelde gevallen komen uit docs/watched_keys_cases.json (bron: iptv-ios-appletv, niet hier wijzigen).
do {
    let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let paths = [here.appendingPathComponent("docs/watched_keys_cases.json"),
                 URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent().appendingPathComponent("docs/watched_keys_cases.json")]
    let caseData = paths.lazy.compactMap { try? Data(contentsOf: $0) }.first
    check(caseData != nil, "build 154: docs/watched_keys_cases.json gevonden")
    let cases = caseData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    func str(_ v: Any?) -> String? { v as? String }
    func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }
    func strs(_ v: Any?) -> [String] { (v as? [Any])?.compactMap { $0 as? String } ?? [] }

    // norm
    let norms = (cases["norm"] as? [[Any]]) ?? []
    check(norms.count >= 10, "build 154: norm-gevallen geladen")
    for c in norms { if let a = str(c[0]), let b = str(c[1]) { eq(WatchKeys.norm(a), b, "norm \(a)") } }
    // titelopschoning
    let cleans = (cases["clean"] as? [[Any]]) ?? []
    check(cleans.count >= 13, "build 154: clean-gevallen geladen")
    for c in cleans {
        guard let a = str(c[0]), let b = str(c[1]) else { continue }
        let r = TitleRules154.clean(a)
        eq(r.title, b, "clean titel \(a)")
        eq(r.year, int(c[2]), "clean jaar \(a)")
    }
    // filmsleutels
    let mk = (cases["movieKeys"] as? [[String: Any]]) ?? []
    check(mk.count >= 4, "build 154: movieKeys geladen")
    for c in mk {
        let t = str(c["title"]) ?? ""
        eq(WatchKeys.movie(title: t, year: int(c["year"]), tmdb: str(c["tmdb"]), imdb: str(c["imdb"])), strs(c["keys"]), "filmsleutels \(t)")
    }
    // afleveringssleutels
    let ek = (cases["episodeKeys"] as? [[String: Any]]) ?? []
    check(ek.count >= 3, "build 154: episodeKeys geladen")
    for c in ek {
        let t = str(c["show"]) ?? ""
        eq(WatchKeys.episode(show: t, year: int(c["year"]), tmdb: str(c["tmdb"]), imdb: str(c["imdb"]),
                             season: int(c["season"]), episode: int(c["episode"])), strs(c["keys"]), "afleveringssleutels \(t)")
    }
    // seriesleutels
    let sk = (cases["showKeys"] as? [[String: Any]]) ?? []
    check(sk.count >= 1, "build 154: showKeys geladen")
    for c in sk {
        let t = str(c["show"]) ?? ""
        eq(WatchKeys.show(title: t, year: int(c["year"]), tmdb: str(c["tmdb"]), imdb: str(c["imdb"])), strs(c["keys"]), "seriesleutels \(t)")
    }
    // opzoeken (jaar ±1, jaar 0 alleen 0, tmdb/imdb)
    let lk = (cases["lookup"] as? [[String: Any]]) ?? []
    check(lk.count >= 6, "build 154: lookup-gevallen geladen")
    for (i, c) in lk.enumerated() {
        let keys = WatchKeys.movie(title: str(c["title"]) ?? "", year: int(c["year"]), tmdb: str(c["tmdb"]), imdb: str(c["imdb"]))
        eq(WatchKeys.matches(Set(strs(c["stored"])), keys: keys), (c["watched"] as? Bool) ?? false, "lookup geval \(i + 1)")
    }

    // nieuwste gebeurtenis over alle kandidaatsleutels wint (contract-aanvulling f93f008)
    let lt = (cases["latest"] as? [[String: Any]]) ?? []
    check(lt.count >= 3, "build 154: latest-gevallen geladen")
    func stamps(_ v: Any?) -> [String: Double] {
        var out: [String: Double] = [:]
        for (k, x) in (v as? [String: Any]) ?? [:] { if let n = x as? NSNumber { out[k] = n.doubleValue } }
        return out
    }
    for (i, c) in lt.enumerated() {
        let keys = WatchKeys.movie(title: str(c["title"]) ?? "", year: int(c["year"]), tmdb: str(c["tmdb"]), imdb: str(c["imdb"]))
        eq(WatchKeys.latestWins(present: stamps(c["watched"]), removed: stamps(c["removed"]), ownIDs: [], keys: keys),
           (c["result"] as? Bool) ?? false, "latest geval \(i + 1)")
    }
    // lokaal net toegevoegd (nog zonder at) wint van een oudere verwijdering
    check(WatchKeys.latestWins(present: [:], removed: ["w:m:tmdb:1": 500], ownIDs: [], keys: ["w:m:tmdb:1"], inSet: ["w:m:tmdb:1"]),
          "latest: lokaal toegevoegd wint")
    check(!WatchKeys.latestWins(present: ["w:m:tmdb:1": 100], removed: ["w:m:t:x|2020": 200], ownIDs: [],
                                keys: ["w:m:tmdb:1", "w:m:t:x|2021"], inSet: ["w:m:tmdb:1"]),
          "latest: verwijdering van de titelsleutel (jaar ±1) wint van een oudere tmdb-sleutel")
    check(WatchKeys.norm("がっこう") == "かっこう", "norm: dakuten weg")

    // uitvinken haalt alle sleutels weg (ook de oude id-sleutel en een titelsleutel met jaar ±1)
    let dune = WatchKeys.movie(title: "Dune", year: 2022, tmdb: "438631", imdb: "tt1160419")
    let stored: Set<String> = ["xv123", "w:m:tmdb:438631", "w:m:imdb:tt1160419", "w:m:t:dune|2021", "w:m:t:anders|2021"]
    let gone = WatchKeys.removal(stored, ownIDs: ["xv123"], keys: dune)
    let left = stored.subtracting(gone)
    eq(left, ["w:m:t:anders|2021"], "uitvinken: alle sleutels van het item weg")
    check(!WatchKeys.matches(left, keys: dune), "uitvinken: daarna niet meer gezien")

    // migratie van oude id-sleutels: alleen wat bij een bekend item hoort, met de oude sleutel als bron van `at`
    let old: Set<String> = ["xv1", "ep:s9|1-2", "onbekend", "w:m:tmdb:5"]
    let plan = WatchKeys.migration(old) { k in
        switch k {
        case "xv1": return WatchKeys.movie(title: "The Matrix", year: 1999, tmdb: "603", imdb: nil)
        case "ep:s9|1-2": return WatchKeys.episode(show: "Game of Thrones", year: 2011, tmdb: "1399", imdb: nil, season: 1, episode: 2)
        default: return nil
        }
    }
    eq(plan["w:m:tmdb:603"], "xv1", "migratie: film tmdb")
    eq(plan["w:m:t:thematrix|1999"], "xv1", "migratie: film titel")
    eq(plan["w:e:tmdb:1399|1-2"], "ep:s9|1-2", "migratie: aflevering")
    eq(plan.count, 4, "migratie: niets geraden voor onbekende sleutels")
    // de `at` gaat mee: ListMerge.diff ziet een sleutel die al een `at` heeft niet als nieuw
    var known: ListMerge.Stamps = (["xv1": 100], [:])
    for (n, o) in plan { if let at = known.present[o] { known.present[n] = at } }
    let after = ListMerge.diff(known, current: old.union(plan.keys), now: 500)
    eq(after.present["w:m:tmdb:603"], 100, "migratie: zelfde at als de oude sleutel")
    // uitvinken → alle sleutels in removed met dezelfde tijd
    let un = ListMerge.diff(after, current: old.union(plan.keys).subtracting(["xv1", "w:m:tmdb:603", "w:m:t:thematrix|1999"]), now: 900)
    eq(un.removed["xv1"], 900, "uitvinken: oude id in removed")
    eq(un.removed["w:m:tmdb:603"], 900, "uitvinken: tmdb in removed")
    eq(un.removed["w:m:t:thematrix|1999"], 900, "uitvinken: titel in removed")

    // serie gezien
    check(WatchKeys.seriesComplete(watched: 10, aired: 10, onServer: 8), "serie: alle uitgezonden gezien")
    check(!WatchKeys.seriesComplete(watched: 8, aired: 10, onServer: 8), "serie: Trakt-aantal gaat voor")
    check(WatchKeys.seriesComplete(watched: 8, aired: nil, onServer: 8), "serie: zonder Trakt het aantal op de server")
    check(!WatchKeys.seriesComplete(watched: 0, aired: nil, onServer: 0), "serie: zonder afleveringen nooit gezien")

    // token: niet verversen bij > 1 uur geldig, wel bij < 1 uur (401: zie TraktClient, altijd één keer verversen)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    check(!TraktTokenPolicy.needsRefresh(expiresAt: now.addingTimeInterval(3 * 3600), now: now), "token: 3 uur geldig, niet verversen")
    check(!TraktTokenPolicy.needsRefresh(expiresAt: now.addingTimeInterval(23 * 3600), now: now), "token: 23 uur geldig, niet verversen")
    check(TraktTokenPolicy.needsRefresh(expiresAt: now.addingTimeInterval(1800), now: now), "token: 30 min geldig, verversen")
    check(TraktTokenPolicy.needsRefresh(expiresAt: now.addingTimeInterval(-60), now: now), "token: verlopen, verversen")
    // mislukte verversing zet nooit null: alleen houden of een nieuwer token uit het account overnemen
    let loc = (access: "a", expiresAt: now)
    eq(TraktTokenPolicy.afterFailedRefresh(local: loc, account: nil), .keep, "mislukt zonder account-token: houden")
    eq(TraktTokenPolicy.afterFailedRefresh(local: loc, account: (access: "a", expiresAt: now)), .keep, "mislukt, zelfde token: houden")
    eq(TraktTokenPolicy.afterFailedRefresh(local: loc, account: (access: "b", expiresAt: now.addingTimeInterval(86400))), .adopt,
       "mislukt, nieuwer token in het account: overnemen")
    eq(TraktTokenPolicy.afterFailedRefresh(local: loc, account: (access: "b", expiresAt: now.addingTimeInterval(-86400))), .keep,
       "mislukt, ouder token in het account: houden")

    // wachtrij overleeft een herstart, nieuwere wijziging vervangt de oudere, backoff en Retry-After
    let qURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("selftest-trakt-queue-\(getpid()).json")
    var q = TraktQueue()
    q.enqueue(TraktQueueEntry(op: .add, kind: .movie, tmdb: 603, imdb: nil, title: "The Matrix", year: 1999, season: nil, episode: nil, watchedAt: 1000))
    q.enqueue(TraktQueueEntry(op: .add, kind: .episode, tmdb: 1399, imdb: "tt0944947", title: "Game of Thrones", year: 2011, season: 1, episode: 2, watchedAt: 1001))
    q.enqueue(TraktQueueEntry(op: .remove, kind: .movie, tmdb: 603, imdb: nil, title: "The Matrix", year: 1999, season: nil, episode: nil, watchedAt: 1002))
    eq(q.entries.count, 2, "wachtrij: nieuwere wijziging vervangt de oudere")
    q.save(qURL)
    let q2 = TraktQueue.load(qURL)
    eq(q2, q, "wachtrij: overleeft een herstart")
    try? FileManager.default.removeItem(at: qURL)
    var q3 = q2
    let batch = q3.due(now: 2000)
    eq(batch.count, 2, "wachtrij: alles klaar om te sturen")
    q3.failed(batch, now: 2000)
    eq(q3.due(now: 2010).count, 0, "wachtrij: backoff na een mislukking")
    eq(q3.due(now: 2031).count, 2, "wachtrij: na 30 s opnieuw")
    q3.failed(batch, now: 3000, retryAfter: 120)
    eq(q3.due(now: 3100).count, 0, "wachtrij: Retry-After wordt gevolgd")
    eq(TraktBackoff.retryAfter("120"), 120, "Retry-After in seconden")
    check(TraktBackoff.delay(attempts: 30) <= 1800, "backoff hooguit 30 min")
    let body = TraktQueue.body(batch.filter { $0.op == .add })
    let eps = ((body["shows"] as? [[String: Any]])?.first?["seasons"] as? [[String: Any]])?.first?["episodes"] as? [[String: Any]]
    check(eps?.first?["watched_at"] != nil, "history: watched_at meegestuurd")
    let ids = (body["shows"] as? [[String: Any]])?.first?["ids"] as? [String: Any]
    eq(ids?["tmdb"] as? Int, 1399, "history: ids.tmdb")
    eq(ids?["imdb"] as? String, "tt0944947", "history: ids.imdb")
    let nf = TraktQueue.notFound(in: ["not_found": ["movies": [["ids": ["tmdb": 603]]]]], batch: batch)
    eq(nf.count, 1, "not_found herkend (niet als gelukt)")
    // zonder id niet sturen (eerst zoeken)
    var q4 = TraktQueue()
    q4.enqueue(TraktQueueEntry(op: .add, kind: .movie, tmdb: nil, imdb: nil, title: "X", year: nil, season: nil, episode: nil, watchedAt: 1))
    eq(q4.due(now: 10).count, 0, "wachtrij: zonder id niet sturen")

    // zoektreffer alleen met de juiste titel en het juiste jaar
    check(TraktMatch.accept(title: "NL | Dune (2021)", year: 2021, hitTitle: "Dune", hitYear: 2021), "zoeken: zelfde titel en jaar")
    check(TraktMatch.accept(title: "Dune", year: 2022, hitTitle: "Dune", hitYear: 2021), "zoeken: jaar ±1")
    check(!TraktMatch.accept(title: "Dune", year: 2021, hitTitle: "Dune", hitYear: 1984), "zoeken: ander jaar geweigerd")
    check(!TraktMatch.accept(title: "Dune", year: 2021, hitTitle: "Dune: Part Two", hitYear: 2021), "zoeken: andere titel geweigerd")
    let picked = TraktMatch.pick([("Dune", 1984), ("Dune", 2021)], title: "Dune", year: nil, hitTitle: { $0.0 }, hitYear: { $0.1 })
    check(picked == nil, "zoeken zonder jaar: twee treffers, geen keus")

    // gezien-grens
    check(WatchedThreshold.reached(position: 0.86, duration: 6000, currentTime: 5160), "grens 85%")
    check(WatchedThreshold.reached(position: 0.75, duration: 700, currentTime: 525), "grens 70% en < 3 min over")
    check(!WatchedThreshold.reached(position: 0.8, duration: 6000, currentTime: 4800), "80% met 20 min over: niet gezien")
}

// MARK: build 157: Gratis en Lifetime aangepast (2 apparaten; Verder kijken, kinderprofielen, OpenSubtitles Lifetime)
do {
    // Gratis van de nieuwe server: alle nieuwe vlaggen uit
    let freeNew: [String: Any] = ["plan": "free",
        "limits": ["streams": 1, "devices": 2, "servers": 1],
        "features": ["stats": false, "now_watching": false, "trakt": false, "multi_server": false, "themes": false,
                     "continue_watching": false, "kids_profiles": false, "opensubtitles": false],
        "plans": ["free": ["streams": 1, "devices": 2, "servers": 1], "lifetime": ["streams": 3, "devices": 15, "servers": NSNull()] as [String: Any]] as [String: Any]]
    let f1 = FeatureFlags157.parse(freeNew)
    check(f1 != nil, "157: Gratis gelezen")
    eq(f1, FeatureFlags157(all: false), "157: Gratis = alles uit")
    // Lifetime van de nieuwe server: alles aan
    let lifeNew: [String: Any] = ["entitlements": ["plan": "lifetime",
        "features": ["stats": true, "now_watching": true, "trakt": true, "multi_server": true, "themes": true,
                     "continue_watching": true, "kids_profiles": true, "opensubtitles": true]] as [String: Any]]
    eq(FeatureFlags157.parse(lifeNew), FeatureFlags157(all: true), "157: Lifetime (genest onder entitlements) = alles aan")
    // oude server zonder de nieuwe vlaggen: Gratis = op slot, Lifetime = open
    let freeOld: [String: Any] = ["plan": "free", "features": ["stats": false, "now_watching": false, "trakt": false,
                                                              "multi_server": false, "themes": false]]
    let f2 = FeatureFlags157.parse(freeOld)
    eq(f2?.continueWatching, false, "157: oude server, Gratis: Verder kijken op slot")
    eq(f2?.kidsProfiles, false, "157: oude server, Gratis: kinderprofielen op slot")
    eq(f2?.openSubtitles, false, "157: oude server, Gratis: OpenSubtitles op slot")
    let lifeOld: [String: Any] = ["plan": "lifetime", "features": ["stats": true]]
    eq(FeatureFlags157.parse(lifeOld), FeatureFlags157(all: true), "157: oude server, Lifetime: alles open")
    // vlag die afwijkt van het abonnement (bijv. eigen instelling op de server) wint
    let mixed: [String: Any] = ["plan": "free", "features": ["opensubtitles": true]]
    eq(FeatureFlags157.parse(mixed)?.openSubtitles, true, "157: expliciete vlag wint")
    eq(FeatureFlags157.parse(mixed)?.continueWatching, false, "157: ontbrekende vlag volgt Gratis")
    // NSNumber als vlag
    eq(FeatureFlags157(json: ["kids_profiles": NSNumber(value: 1)], lifetime: false).kidsProfiles, true, "157: NSNumber 1 = aan")
    // geen abonnement in het antwoord: niets
    check(FeatureFlags157.parse(["features": [String: Any]()]) == nil, "157: zonder plan geen vlaggen")
    // onbekend abonnement telt als Lifetime (zoals voorheen: nooit iets op slot door een onbekende waarde)
    eq(FeatureFlags157.isLifetime(["plan": "pro"]), true, "157: onbekend abonnement = Lifetime")
    // 403 feature_locked zet alleen die vlag uit
    var f3 = FeatureFlags157(all: true)
    f3.lock("continue_watching"); f3.lock("kids_profiles"); f3.lock("opensubtitles"); f3.lock("onbekend")
    check(!f3.continueWatching && !f3.kidsProfiles && !f3.openSubtitles && f3.stats && f3.trakt && f3.themes,
          "157: feature_locked zet alleen die vlaggen uit")

    // standaardlimieten: Gratis 1/2/1, Lifetime 3/15/onbeperkt
    eq(PlanDefaults157.free, PlanDefaults157.Limits(streams: 1, devices: 2, servers: 1), "157: Gratis 1 scherm, 2 apparaten, 1 server")
    eq(PlanDefaults157.lifetime, PlanDefaults157.Limits(streams: 3, devices: 15, servers: nil), "157: Lifetime 3/15/onbeperkt")
    let pl = PlanDefaults157.plans(freeNew["plans"])
    eq(pl["free"]?.devices, 2, "157: plans Gratis 2 apparaten")
    check(pl["lifetime"]?.servers == nil && pl["lifetime"]?.devices == 15, "157: plans Lifetime null = onbeperkt")
    eq(PlanDefaults157.plans(nil)["free"]?.devices, 2, "157: zonder plans: Gratis 2 apparaten")
    eq(PlanDefaults157.plans(["lifetime": ["streams": 3]] as [String: Any])["free"]?.devices, 2, "157: plans zonder free: standaard 2")
    eq(PlanDefaults157.plans(["free": ["devices": "4"]] as [String: Any])["free"]?.devices, 4, "157: getal als tekst")

    // Verder kijken
    eq(ContinueWatching157.row(allowed: false, hasItems: true), .locked, "157: Gratis met voortgang: rij met slotje")
    eq(ContinueWatching157.row(allowed: false, hasItems: false), .hidden, "157: Gratis zonder voortgang: geen rij")
    eq(ContinueWatching157.row(allowed: true, hasItems: true), .items, "157: Lifetime: gewone rij")
    eq(ContinueWatching157.row(allowed: true, hasItems: false), .hidden, "157: Lifetime zonder voortgang: geen rij")
    check(ContinueWatching157.saveProgress(allowed: false), "157: Gratis: voortgang wel bewaard en gesynct")
    check(ContinueWatching157.resume(allowed: false), "157: Gratis: hervatten blijft werken")

    // Kinderprofielen
    eq(KidsProfiles157.edit(allowed: false, isKids: false), .lockedToCreate, "157: Gratis: nieuw kinderprofiel = slotje")
    eq(KidsProfiles157.edit(allowed: false, isKids: true), .readOnly, "157: Gratis: bestaand kinderprofiel alleen te lezen")
    eq(KidsProfiles157.edit(allowed: true, isKids: true), .editable, "157: Lifetime: kinderprofiel aan te passen")
    eq(KidsProfiles157.edit(allowed: true, isKids: false), .editable, "157: Lifetime: kinderprofiel te maken")
    check(!KidsProfiles157.savedKids(requested: true, allowed: false, wasKids: false), "157: Gratis: geen nieuw kinderprofiel bewaard")
    check(KidsProfiles157.savedKids(requested: false, allowed: false, wasKids: true), "157: Gratis: bestaand kinderprofiel blijft kinderprofiel")
    check(KidsProfiles157.savedKids(requested: true, allowed: true, wasKids: false), "157: Lifetime: kinderprofiel maken")
    check(!KidsProfiles157.savedKids(requested: false, allowed: true, wasKids: true), "157: Lifetime: kinderprofiel uitzetten")
    eq(KidsProfiles157.savedAgeLimit(requested: 16, allowed: false, wasKids: true, previous: 9), 9, "157: Gratis: leeftijd kinderprofiel ongewijzigd")
    eq(KidsProfiles157.savedAgeLimit(requested: 16, allowed: false, wasKids: false, previous: nil), 16, "157: Gratis: leeftijd gewoon profiel aan te passen")
    eq(KidsProfiles157.savedAgeLimit(requested: 6, allowed: true, wasKids: true, previous: 9), 6, "157: Lifetime: leeftijd kinderprofiel aan te passen")
    check(KidsProfiles157.filtered(isKids: true, allowed: false), "157: bestaand kinderprofiel blijft gefilterd bij Gratis")
    check(KidsProfiles157.filtered(isKids: true, allowed: true), "157: kinderprofiel gefilterd bij Lifetime")
    check(!KidsProfiles157.filtered(isKids: false, allowed: false), "157: gewoon profiel niet als kinderprofiel gefilterd")
    check(KidsProfiles157.canDelete(allowed: false), "157: kinderprofiel verwijderen mag altijd")
    // een bestaand kinderprofiel blijft na het lezen van een Gratis-antwoord gefilterd (de vlag raakt het profiel niet)
    let flagsFree = FeatureFlags157.parse(freeNew)!
    let kidsAfter = KidsProfiles157.savedKids(requested: false, allowed: flagsFree.kidsProfiles, wasKids: true)
    check(KidsProfiles157.filtered(isKids: kidsAfter, allowed: flagsFree.kidsProfiles), "157: kinderprofiel na Gratis-antwoord nog gefilterd")

    // OpenSubtitles
    check(!OpenSubtitles157.usable(allowed: false, signedIn: true), "157: Gratis: OpenSubtitles niet gebruikt")
    check(OpenSubtitles157.usable(allowed: true, signedIn: true), "157: Lifetime: OpenSubtitles met koppeling")
    check(!OpenSubtitles157.usable(allowed: true, signedIn: false), "157: Lifetime zonder koppeling: niet")
    check(OpenSubtitles157.keepConnection(allowed: false), "157: Gratis: koppeling blijft bewaard")
    check(OpenSubtitles157.streamSubtitles(allowed: false), "157: Gratis: ondertitels uit de stream blijven")
}

// MARK: build 158: start op Apple TV robuust bij onverwachte gegevens (geen crash, wel een terugval)
do {
    // sleutels uit de account-sync kunnen alles bevatten: een "jaar" dat bij ±1 zou overlopen gaf een crash
    let huge = "w:m:t:dune|\(Int.max)"
    let c1 = WatchKeys.candidates([huge, "w:s:t:x|\(Int.min)", "w:e:t:x|-5|1-2", "w:m:t:|", "w:m:t:", "w:e:t:a|b|c|d"])
    check(c1.contains(huge) && c1.count == 6, "158: kandidaten met een onmogelijk jaar: alleen de sleutel zelf")
    eq(WatchKeys.candidates(["w:m:t:dune|2021"]), ["w:m:t:dune|2021", "w:m:t:dune|2020", "w:m:t:dune|2022"], "158: gewoon jaar ±1 blijft")
    check(WatchKeys.matches(["w:m:t:dune|\(Int.max)"], keys: ["w:m:t:dune|\(Int.max)"]), "158: onmogelijk jaar: gewoon zoeken")
    check(WatchKeys.latestWins(present: [huge: 1], removed: [:], ownIDs: [], keys: [huge]), "158: latestWins met onmogelijk jaar")

    // titels van echte servers: lege, alleen tekens, haakjes zonder inhoud, alleen een jaartal
    let odd = ["", " ", "(", ")", "()", "[]", "[", "]", "(2021)", "[2021]", "|", "||", "|||NL|||", "- 2021", ":", "NL:", "NL: ",
               "┃NL┃", "x)", "(x", "((2021))", "Dune (", "Dune (20211)", "Dune (2021", "🎬", "👨‍👩‍👧 (2020)", "\u{0301}", "  -  ",
               "NL - ", "[4K] ", "| 2021", "Movie | ", "A|B|C|D|E|F|G|H", String(repeating: "|", count: 40)]
    for t in odd {
        let c = TitleRules154.clean(t)
        _ = WatchKeys.norm(t); _ = WatchKeys.norm(c.title)
        let keys = WatchKeys.movie(title: t, year: nil, tmdb: nil, imdb: nil)
        _ = WatchKeys.candidates(keys)
        _ = WatchKeys.showForms(title: t, year: Int.max, tmdb: "", imdb: "tt")
        _ = TitleRules154.extractYear(t)
        _ = TitleRules154.stripPrefixes(t)
    }
    check(true, "158: vreemde titels geven geen crash")
    eq(WatchKeys.yearPart(Int.max), 0, "158: onmogelijk jaar telt als 0")

    // abonnement: onverwachte waarden volgen het abonnement, geen crash
    let weird: [String: Any] = ["plan": "free", "limits": ["streams": "x", "devices": NSNull(), "servers": [1]],
                                "features": ["stats": "true", "trakt": NSNull(), "themes": [true], "opensubtitles": 1],
                                "plans": ["free": "x", "lifetime": ["devices": "15", "servers": NSNull()], "": [:]]]
    let fw = FeatureFlags157.parse(weird)
    check(fw != nil && fw?.stats == false && fw?.trakt == false && fw?.openSubtitles == true, "158: vreemde vlaggen volgen Gratis")
    let pw = PlanDefaults157.plans(weird["plans"])
    eq(pw["free"], PlanDefaults157.free, "158: onleesbaar plan Gratis = standaard")
    eq(pw["lifetime"]?.devices, 15, "158: apparaten als tekst gelezen")
    check(pw["lifetime"]?.servers == nil, "158: servers null = onbeperkt")
    check(FeatureFlags157.parse([:]) == nil && FeatureFlags157.parse(["plan": 3]) == nil, "158: geen abonnement in het antwoord")
    check(PlanDefaults157.plans(nil)["free"] == PlanDefaults157.free && PlanDefaults157.plans("x").count == 2, "158: plans ontbreekt")

    // Trakt-wachtrij: leeg, half geschreven of oud bestand → lege wachtrij en het bestand weg
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bingr-selftest-158-\(getpid())")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (i, raw) in ["", "{", "null", "[]", "{\"entries\":5}", "{\"entries\":[{\"op\":\"x\"}]}"].enumerated() {
        let u = dir.appendingPathComponent("q\(i).json")
        try? Data(raw.utf8).write(to: u)
        let q = TraktQueue.load(u)
        check(q.entries.isEmpty, "158: wachtrij uit onleesbaar bestand \(i) is leeg")
        check(!FileManager.default.fileExists(atPath: u.path), "158: onleesbaar wachtrijbestand \(i) weggehaald")
    }
    check(TraktQueue.load(dir.appendingPathComponent("bestaat-niet.json")).entries.isEmpty, "158: geen wachtrijbestand")
    var good = TraktQueue()
    good.enqueue(TraktQueueEntry(op: .add, kind: .movie, tmdb: 1, imdb: nil, title: "A", year: 2020, season: nil, episode: nil, watchedAt: 1))
    let gu = dir.appendingPathComponent("goed.json")
    good.save(gu)
    eq(TraktQueue.load(gu), good, "158: geldige wachtrij blijft")
    // aflevering zonder seizoen/nummer of zonder id's: niet in de body, geen crash
    let bad = [TraktQueueEntry(op: .add, kind: .episode, tmdb: 5, imdb: nil, title: nil, year: nil, season: nil, episode: 1, watchedAt: 0),
               TraktQueueEntry(op: .remove, kind: .episode, tmdb: nil, imdb: nil, title: "x", year: nil, season: 1, episode: 1, watchedAt: 0)]
    check(TraktQueue.body(bad).isEmpty, "158: onvolledige afleveringen niet naar Trakt")
    try? FileManager.default.removeItem(at: dir)
}

// MARK: build 158: UserDefaults klein (tvOS: hooguit 1 MB samen, anders stopt de app bij het openen), grote gegevens in bestanden
do {
    for k in ["account.stateMeta.v1", "photos.v1", "categories.account.v140", "watched.v1.6F1C2B9E-0000-4000-8000-000000000001",
              "discover.known", "discover.upcoming.nl.NL", "account.sourceExtras.v1", "custom.v1",
              "categories.v1.6F1C2B9E-0000-4000-8000-000000000001", "history.v1.6F1C2B9E-0000-4000-8000-000000000001", "progress.v1"] {
        check(DefaultsPolicy158.isFileKey(k), "158: \(k) in een bestand")
    }
    for k in ["lastPlaylistID", "categories.migrated.v140", "watched", "photos", "discoverX", "entitlements.themes", "player.engine"] {
        check(!DefaultsPolicy158.isFileKey(k), "158: \(k) blijft in UserDefaults")
    }
    check(DefaultsPolicy158.fitsInDefaults(size: 100 * 1024, others: 0), "158: 100 KB per sleutel mag")
    check(!DefaultsPolicy158.fitsInDefaults(size: 100 * 1024 + 1, others: 0), "158: meer dan 100 KB per sleutel niet")
    check(!DefaultsPolicy158.fitsInDefaults(size: 10, others: 900 * 1024), "158: samen niet boven 900 KB")
    check(DefaultsPolicy158.maxTotal < 1_048_576, "158: grens onder de 1 MB van tvOS")
    for k in ["a/b", "../x", ".", "", "watched.v1.ÄÖ|x", "discover.upcoming.nl.NL"] {
        eq(DefaultsPolicy158.key(fromFileName: DefaultsPolicy158.fileName(k)), k, "158: bestandsnaam heen en terug (\(k))")
        check(!DefaultsPolicy158.fileName(k).contains("/"), "158: geen / in de bestandsnaam (\(k))")
    }

    // de stand uit de log van Léon (tvOS 27): samen boven 1 MB
    let suite = "nl.lrvdlinden.bingr.selftest158.\(getpid())"
    let ud = UserDefaults(suiteName: suite)!
    ud.removePersistentDomain(forName: suite)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bingr-selftest-defaults-\(getpid())")
    try? FileManager.default.removeItem(at: dir)
    func blob(_ n: Int, _ seed: UInt8) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: $0) &+ seed }) }
    let log: [(String, Int)] = [("account.stateMeta.v1", 667_861), ("photos.v1", 234_785), ("categories.account.v140", 82_170),
                                ("watched.v1.6F1C2B9E-0000-4000-8000-000000000001", 69_142), ("discover.known", 21_542),
                                ("discover.upcoming.nl.NL", 19_607), ("account.sourceExtras.v1", 12_842), ("custom.v1", 12_155),
                                ("andere.grote.data", 150_000)]
    for (i, x) in log.enumerated() { ud.set(blob(x.1, UInt8(i)), forKey: x.0) }
    ud.set("ABC", forKey: "lastPlaylistID")
    ud.set(true, forKey: "entitlements.themes")
    let big = BigDefaults(defaults: ud, dir: dir, domain: suite)
    let moved = big.migrate()
    check(moved.contains("account.stateMeta.v1") && moved.contains("photos.v1") && moved.contains("andere.grote.data"), "158: grote sleutels verplaatst")
    check(big.defaultsBytes() <= DefaultsPolicy158.maxTotal, "158: na de migratie onder 900 KB (\(big.defaultsBytes()))")
    let dom = ud.persistentDomain(forName: suite) ?? [:]
    check(dom.allSatisfy { DefaultsPolicy158.size(of: $0.value) <= DefaultsPolicy158.maxPerKey }, "158: geen sleutel boven 100 KB in UserDefaults")
    check(dom.keys.allSatisfy { !DefaultsPolicy158.isFileKey($0) }, "158: bestandssleutels uit UserDefaults")
    for (i, x) in log.enumerated() { eq(big.data(forKey: x.0), blob(x.1, UInt8(i)), "158: \(x.0) na de migratie gelijk") }
    eq(ud.string(forKey: "lastPlaylistID"), "ABC", "158: kleine instelling blijft in UserDefaults")
    check(big.bool(forKey: "entitlements.themes") && ud.bool(forKey: "entitlements.themes"), "158: bool blijft leesbaar")
    eq(big.migrate(), [], "158: migratie één keer per start")

    // schrijven: een bestandssleutel nooit in UserDefaults, en elke andere grote waarde ook niet (de grens)
    big.set(blob(700_000, 9), forKey: "account.stateMeta.v1")
    check(ud.object(forKey: "account.stateMeta.v1") == nil, "158: stateMeta nooit in UserDefaults")
    big.set(blob(2_000_000, 7), forKey: "nog.groter")
    check(ud.object(forKey: "nog.groter") == nil && big.data(forKey: "nog.groter") == blob(2_000_000, 7), "158: 2 MB naar een bestand")
    for i in 0..<12 { big.set(blob(95_000, UInt8(i)), forKey: "veel.\(i)") }
    check(big.defaultsBytes() <= DefaultsPolicy158.maxTotal, "158: veel kleine sleutels samen onder 900 KB")
    for i in 0..<12 { eq(big.data(forKey: "veel.\(i)"), blob(95_000, UInt8(i)), "158: veel.\(i) leesbaar") }
    big.set("klein", forKey: "nog.groter")
    eq(big.string(forKey: "nog.groter"), "klein", "158: klein overschrijft het bestand")
    check(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(DefaultsPolicy158.fileName("nog.groter")).path), "158: oud bestand weg")
    // een sleutel die (nog) in UserDefaults staat, gaat bij het lezen naar een bestand
    ud.set(blob(500, 1), forKey: "history.v1.x")
    eq(big.data(forKey: "history.v1.x"), blob(500, 1), "158: history uit UserDefaults gelezen")
    check(ud.object(forKey: "history.v1.x") == nil, "158: history daarna uit UserDefaults")
    big.removeObject(forKey: "photos.v1")
    check(big.data(forKey: "photos.v1") == nil, "158: verwijderen")
    // na een herstart (nieuwe instantie) staat alles er nog; een gewist cachemap = gewoon leeg (opnieuw uit het account)
    let again = BigDefaults(defaults: ud, dir: dir, domain: suite)
    eq(again.data(forKey: "account.stateMeta.v1"), blob(700_000, 9), "158: na herstart uit het bestand")
    try? FileManager.default.removeItem(at: dir)
    let wiped = BigDefaults(defaults: ud, dir: dir, domain: suite)
    check(wiped.data(forKey: "account.stateMeta.v1") == nil, "158: cache gewist: leeg, geen crash")
    wiped.set(blob(10, 1), forKey: "account.stateMeta.v1")
    eq(wiped.data(forKey: "account.stateMeta.v1"), blob(10, 1), "158: na wissen weer te schrijven")
    ud.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: dir)
}

print("\(checks) controles, \(failures) fout")
exit(failures == 0 ? 0 : 1)
