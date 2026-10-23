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

// MARK: build 140: server automatisch vernieuwen

check(!AutoRefresh.isDue(policy: "manual", age: nil), "handmatig nooit")
check(AutoRefresh.isDue(policy: "daily", age: nil), "geen cache = nu")
check(AutoRefresh.isDue(policy: "daily", age: 25 * 3600), "dagelijks na 25 uur")
check(!AutoRefresh.isDue(policy: "daily", age: 3 * 3600), "dagelijks niet na 3 uur")
check(AutoRefresh.isDue(policy: "weekly", age: 8 * 86_400), "wekelijks na 8 dagen")
check(!AutoRefresh.isDue(policy: "weekly", age: 2 * 86_400), "wekelijks niet na 2 dagen")
check(AutoRefresh.isDue(policy: "launch", age: 120), "bij elke start")
check(!AutoRefresh.isDue(policy: "launch", age: 120, periodic: true), "bij elke start: niet periodiek")
check(AutoRefresh.isDue(policy: "garbage", age: 30 * 3600), "onbekend = dagelijks")
let refNow = Date(timeIntervalSince1970: 1_000_000)
eq(AutoRefresh.due(policy: "daily", servers: [("A", 30 * 3600), ("B", 3600), ("C", nil), ("D", 40 * 3600)],
                   lastAttempt: ["D": refNow.addingTimeInterval(-60)], now: refNow, periodic: true),
   ["A", "C"], "alle servers van het account die te oud zijn, niet net geprobeerd")
eq(AutoRefresh.due(policy: "daily", servers: [("D", 40 * 3600)], lastAttempt: ["D": refNow.addingTimeInterval(-3600)],
                   now: refNow, periodic: true), ["D"], "na 15 minuten opnieuw proberen")

// MARK: build 140: Voor jou

eq(ForYouSeeds.rank([.init(key: "s1", at: 10), .init(key: "m1", at: 50), .init(key: "s1", at: 20), .init(key: "m2", at: 40)], limit: 2),
   ["s1", "m1"], "meest bekeken, dan laatst bekeken")
eq(ForYouSeeds.score(genres: [16, 35], group: "Kids", seedGenres: [16: 3], seedGroups: ["Kids": 1]), 5, "score")

print("\(checks) controles, \(failures) fout")
exit(failures == 0 ? 0 : 1)
