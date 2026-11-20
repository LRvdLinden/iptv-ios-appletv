import Foundation

// Build 179, punt 16: WebDAV als bron (docs/ACCOUNT.md → "Build 179"). Mappen doorbladeren met PROPFIND (Depth: 1,
// Basic of Digest: URLSession handelt de 401-uitdaging af), recursief tot 6 niveaus en max. 20.000 bestanden; films en
// afleveringen herkennen uit map- en bestandsnamen (Build179.webdavParse); geen live tv en geen downloads.
// Het wachtwoord staat alleen in de sleutelhanger (`playlist.<id>.password`, via SourceSync versleuteld naar de server)
// en nooit in de bewaarde catalogus: de stream-adressen zijn zonder inloggegevens, de speler voegt ze toe (WebDAVAuth).

enum WebDAVError: LocalizedError {
    case notWebDAV
    var errorDescription: String? { L("This server doesn't answer as WebDAV. Check the address.") }
}

struct WebDAVClient {
    static let maxDepth = 6
    static let maxFiles = 20_000

    let base: URL
    let username: String
    let password: String

    init?(source: PlaylistSource, password: String) {
        var s = source.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.lowercased().hasPrefix("http") { s = "https://" + s }
        if !s.hasSuffix("/") { s += "/" }
        guard let u = s.urlValue, u.host != nil else { return nil }
        base = u
        username = source.username
        self.password = password
    }

    /// Beantwoordt de inlog-uitdaging (Basic of Digest) met de gegevens van de bron; één poging.
    private final class Auth: NSObject, URLSessionTaskDelegate {
        let credential: URLCredential?
        init(user: String, password: String) {
            credential = user.isEmpty ? nil : URLCredential(user: user, password: password, persistence: .none)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            let method = challenge.protectionSpace.authenticationMethod
            guard method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest else {
                completionHandler(.performDefaultHandling, nil); return
            }
            guard challenge.previousFailureCount == 0, let credential else {
                completionHandler(.cancelAuthenticationChallenge, nil); return
            }
            completionHandler(.useCredential, credential)
        }
    }

    struct Entry { var url: URL; var isFolder: Bool }

    /// Inhoud van één map.
    func list(_ folder: URL) async throws -> [Entry] {
        var req = URLRequest(url: folder)
        req.httpMethod = "PROPFIND"
        req.timeoutInterval = 30
        req.setValue("1", forHTTPHeaderField: "Depth")
        req.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("<?xml version=\"1.0\" encoding=\"utf-8\"?><D:propfind xmlns:D=\"DAV:\"><D:prop><D:resourcetype/></D:prop></D:propfind>".utf8)
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await HTTP.session.data(for: req, delegate: Auth(user: username, password: password))
        } catch let e as URLError where e.code == .userCancelledAuthentication || e.code == .userAuthenticationRequired {
            throw HTTPError.status(401, "")
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw HTTPError.status(code, "") }
        guard code == 207 else {
            if (200..<300).contains(code) || code == 405 || code == 501 { throw WebDAVError.notWebDAV }
            throw HTTPError.status(code, "")
        }
        let parser = PropfindParser()
        let own = Self.pathKey(folder)
        return parser.parse(data).compactMap { item in
            guard let u = URL(string: item.href, relativeTo: folder)?.absoluteURL
                    ?? URL(string: item.href.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "", relativeTo: folder)?.absoluteURL,
                  u.host == folder.host, Self.pathKey(u) != own, Self.pathKey(u).hasPrefix(Self.pathKey(base)) else { return nil }
            return Entry(url: u, isFolder: item.isFolder || item.href.hasSuffix("/"))
        }
    }

    private static func pathKey(_ u: URL) -> String {
        var p = u.path
        while p.hasSuffix("/") { p.removeLast() }
        return p + "/"
    }

    /// Controle bij toevoegen: de hoofdmap is leesbaar.
    func check() async throws { _ = try await list(base) }

    /// Alle videobestanden (breedte eerst), tot 6 niveaus diep en 20.000 bestanden.
    func files() async throws -> [URL] {
        var out: [URL] = []
        var level = [base]
        var seen = Set<String>()
        for depth in 0..<Self.maxDepth {
            var next: [URL] = []
            for folder in level {
                guard seen.insert(Self.pathKey(folder)).inserted else { continue }
                let entries: [Entry]
                do { entries = try await list(folder) } catch {
                    if depth == 0 { throw error }   // de hoofdmap moet lukken; een onleesbare submap slaan we over
                    continue
                }
                for e in entries {
                    if e.isFolder { next.append(e.url.absoluteString.hasSuffix("/") ? e.url : (URL(string: e.url.absoluteString + "/") ?? e.url)) }
                    else if Build179.videoExtensions.contains(e.url.pathExtension.lowercased()) {
                        out.append(e.url)
                        if out.count >= Self.maxFiles { return out }
                    }
                }
                try Task.checkCancellation()
            }
            if next.isEmpty { break }
            level = next
        }
        return out
    }

    /// Films en series uit de bestanden (titels en jaartallen uit de namen; posters en beschrijvingen komen van TMDB).
    func library() async throws -> Library {
        let urls = try await files()
        let basePath = Self.pathKey(base)
        let movieGroup = L("Movies"), seriesGroup = L("Series")
        return await Task.detached(priority: .utility) {
            var lib = Library()
            var seriesOrder: [String] = []
            var seriesBy: [String: Series] = [:]
            for u in urls {
                var rel = u.path
                if rel.hasPrefix(basePath) { rel = "/" + rel.dropFirst(basePath.count) }
                let item = Build179.webdavParse(rel)
                let hash = String(Sport173.hash(rel), radix: 16)
                switch item.kind {
                case "movie":
                    lib.movies.append(Movie(id: "wdm" + hash, title: item.title, year: item.year, poster: nil,
                                            group: movieGroup, streamURL: u))
                case "episode":
                    let key = Build179.norm(item.title)
                    guard !key.isEmpty, let s = item.season, let e = item.episode else { continue }
                    let sid = "wds" + String(Sport173.hash(key), radix: 16)
                    if seriesBy[key] == nil {
                        seriesBy[key] = Series(id: sid, title: item.title, year: nil, poster: nil, group: seriesGroup)
                        seriesOrder.append(key)
                    }
                    seriesBy[key]?.episodes.append(Episode(id: "wde" + hash, seriesID: sid, season: s, number: e,
                                                           title: L("Episode %d", e), streamURL: u))
                default: break
                }
            }
            lib.movies.sort { Sport173.jsLess(Build179.norm($0.title), Build179.norm($1.title)) }
            lib.series = seriesOrder.sorted().compactMap { key in
                guard var s = seriesBy[key] else { return nil }
                s.episodes.sort { $0.season != $1.season ? $0.season < $1.season : $0.number < $1.number }
                return s
            }
            return lib
        }.value
    }
}

/// Leest `href` en map/bestand uit een PROPFIND-antwoord (207 Multi-Status).
private final class PropfindParser: NSObject, XMLParserDelegate {
    struct Item { var href: String; var isFolder: Bool }
    private var items: [Item] = []
    private var href = ""
    private var folder = false
    private var inHref = false
    private var text = ""

    func parse(_ data: Data) -> [Item] {
        let p = XMLParser(data: data)
        p.shouldProcessNamespaces = true
        p.delegate = self
        p.parse()
        return items
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        switch name.lowercased() {
        case "response": href = ""; folder = false
        case "href": inHref = true; text = ""
        case "collection": folder = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { if inHref { text += string } }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name.lowercased() {
        case "href":
            inHref = false
            if href.isEmpty { href = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        case "response":
            if !href.isEmpty { items.append(Item(href: href, isFolder: folder)) }
        default: break
        }
    }
}

/// Inloggegevens voor het afspelen van een bestand op een WebDAV-bron van dit account.
@MainActor
enum WebDAVAuth {
    /// (gebruiker, wachtwoord) als dit adres onder een WebDAV-bron valt.
    static func credentials(for url: URL) -> (user: String, password: String)? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        let target = url.absoluteString
        for p in CloudStore.shared.playlists where p.kind == .webdav && !p.username.isEmpty {
            guard let c = WebDAVClient(source: p, password: Keychain.get(p.passwordKey) ?? "") else { continue }
            if url.host == c.base.host, url.port == c.base.port, target.hasPrefix(c.base.absoluteString) { return (c.username, c.password) }
        }
        return nil
    }

    /// `Authorization: Basic …` voor AVPlayer (Digest kan AVPlayer niet: dan neemt VLC het over, zie punt 3).
    static func basicHeader(for url: URL) -> String? {
        guard let c = credentials(for: url) else { return nil }
        return "Basic " + Data((c.user + ":" + c.password).utf8).base64EncodedString()
    }

    /// Adres met de inloggegevens erin voor VLC (Basic en Digest); alleen in het geheugen, nooit bewaard of gelogd.
    static func urlWithCredentials(_ url: URL) -> URL {
        guard let c = credentials(for: url), var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        comps.user = c.user
        comps.password = c.password
        return comps.url ?? url
    }

    nonisolated static func isWebDAV(_ id: String) -> Bool { id.hasPrefix("wdm") || id.hasPrefix("wde") || id.hasPrefix("wds") }
}
