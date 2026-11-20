import Foundation

// Build 179 (versie 1.0.8), X3: iPhone Duo (opvouwbaar, iOS 27). Pure logica zonder UI, getest in
// tools/selftest/main.swift. Zie docs/IPHONE_DUO.md.
// - layout per size class in plaats van "is dit een iPhone/iPad" (buitenscherm = compacte breedte, binnenscherm en iPad
//   = reguliere breedte, ook Split View)
// - rasters met een even aantal kolommen op reguliere breedte (de vouw valt dan tussen twee kolommen)
// - speler in tafelstand: beeld boven de vouw, bediening eronder
// - AirPlay-video (ook CarPlay als de auto stilstaat, iOS 26): VLC-stream naar de Apple-speler

enum Duo179 {
    // MARK: schermen (in punten, @3x)

    /// iPhone Duo: binnenscherm 1878×2670 px, buitenscherm 1398×2034 px, beide @3x
    static let innerPixels = (w: 1878.0, h: 2670.0)
    static let outerPixels = (w: 1398.0, h: 2034.0)
    static func points(_ px: Double, scale: Double = 3) -> Double { (px / scale).rounded(.down) }

    // MARK: tabbladen per size class

    /// De tabbladen in vaste volgorde (tags van MainTabView): Home 0, Live TV 1, Films 2, Series 3, Sport 8,
    /// Categorieën 7, Zoeken 4, Downloads 6 (alleen iOS), Mijn Bingr 5 (alleen Apple TV).
    /// `compact`: compacte breedte (iPhone, buitenscherm van de iPhone Duo, iPad in een smal venster): max. 5 tabbladen
    /// (anders "Meer"); Zoeken zit dan als vergrootglas op Home/Films/Series, Downloads in Mijn Bingr, Categorieën via
    /// Home en Live TV als er Sport is.
    static func tabs(compact: Bool, live: Bool, movies: Bool, series: Bool, sport: Bool,
                     downloads: Bool, tv: Bool) -> [Int] {
        var t = [0]
        if live { t.append(1) }
        if movies { t.append(2) }
        if series { t.append(3) }
        if sport { t.append(8) }
        if !compact || !sport { t.append(7) }
        if !compact { t.append(4) }
        if downloads && !compact { t.append(6) }
        if tv { t.append(5) }
        return t
    }

    /// Tabblad na open- of dichtklappen: blijft hetzelfde als het er nog is; Zoeken en Downloads (alleen breed)
    /// vallen terug op Home.
    static func keepTab(_ tab: Int, available: [Int]) -> Int { available.contains(tab) ? tab : 0 }

    // MARK: rasters

    /// Aantal kolommen voor een raster met tegels van minstens `minItem` breed. Op reguliere breedte (binnenscherm,
    /// iPad) een even aantal, zodat de vouw tussen twee kolommen valt; compact gewoon zoveel als past (min. 2).
    static func columns(width: Double, minItem: Double, spacing: Double, regular: Bool) -> Int {
        guard width > 0, minItem > 0 else { return 2 }
        let n = max(1, Int(((width + spacing) / (minItem + spacing)).rounded(.down)))
        guard regular else { return max(2, n) }
        let even = n % 2 == 0 ? n : n - 1
        return max(2, even)
    }

    // MARK: speler in tafelstand

    struct Rect: Equatable, Sendable {
        var x, y, w, h: Double
        var maxY: Double { y + h }
    }

    /// Indeling van de speler als het toestel half open staat met de vouw horizontaal (tafelstand): `videoBottom` =
    /// ruimte onder het beeld (vanaf de onderkant van het scherm), `controlsTop` = waar de bediening begint (vanaf de
    /// bovenkant). nil = gewoon schermvullend (plat, dicht, vouw verticaal of te kleine helften).
    struct Tabletop: Equatable, Sendable {
        var videoBottom: Double
        var controlsTop: Double
    }

    static func tabletop(container w: Double, _ h: Double, fold: Rect?) -> Tabletop? {
        guard let f = fold, w > 0, h > 0 else { return nil }
        // horizontale vouw: breder dan hoog en (bijna) over de hele breedte
        guard f.w >= w * 0.8, f.h < h * 0.2 else { return nil }
        let top = f.y, bottom = h - f.maxY
        // beide helften moeten bruikbaar zijn (bediening heeft ±200 pt nodig)
        guard top >= 160, bottom >= 160 else { return nil }
        return Tabletop(videoBottom: h - top, controlsTop: f.maxY)
    }

    // MARK: AirPlay-video (CarPlay als de auto stilstaat)

    /// Een AirPlay-route wordt actief terwijl VLC speelt: naar de Apple-speler op dezelfde positie (alleen die kan
    /// video via AirPlay sturen). Eén keer per AirPlay-route (geen heen-en-weer als de Apple-speler het niet kan),
    /// niet voor voorbeelden of stille spelers, en alleen als de Apple-speler het adres kan openen. CarPlay-audio
    /// (rijden) is geen AirPlay en wisselt dus niet.
    static func switchForAirPlay(usingApple: Bool, airPlay: Bool, alreadyForThisRoute: Bool,
                                 preview: Bool, appleCanOpen: Bool) -> Bool {
        airPlay && !usingApple && !alreadyForThisRoute && !preview && appleCanOpen
    }

    /// Kan de Apple-speler dit adres openen (voor AirPlay)? http(s) of een bestand, geen rtsp/rtmp/udp.
    static func appleCanOpen(scheme: String?, isFile: Bool) -> Bool {
        if isFile { return true }
        return ["http", "https"].contains(scheme?.lowercased() ?? "")
    }
}
