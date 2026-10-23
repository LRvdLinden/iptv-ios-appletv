import Foundation

enum HTTPError: LocalizedError {
    case badURL, status(Int, String), decoding(String)
    var errorDescription: String? {
        switch self {
        case .badURL: return L("Invalid URL")
        case .status(let c, _) where [401, 403, 511].contains(c):
            return L("Sign-in failed (%d). Check the username and password of this playlist.", c)
        case .status(let c, let b): return L("Server error %d: %@", c, String(b.prefix(200)))
        case .decoding(let m): return L("Couldn't read the response: %@", m)
        }
    }
}

enum HTTP {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 300
        c.httpAdditionalHeaders = ["User-Agent": Secrets.userAgent]
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        Screenshots.configure(c)   // App Store-screenshots: geen netwerk
        return URLSession(configuration: c)
    }()

    static func data(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (d, r) = try await session.data(for: req)
        guard let h = r as? HTTPURLResponse else { throw HTTPError.status(0, "") }
        return (d, h)
    }

    static func get(_ url: URL, headers: [String: String] = [:]) async throws -> Data {
        // start-rooktest: welke catalogus wordt wanneer opgehaald (alleen het pad, geen query/inloggegevens)
        if SmokeTest.isActive, url.host == "127.0.0.1" {
            SmokeTest.say("HTTP GET \(url.path) [\(Int(StartDiagnostics.shared.uptime))s] \(Thread.callStackSymbols.dropFirst().prefix(6).map { $0.split(separator: " ").dropFirst(3).first.map(String.init) ?? "" }.joined(separator: " < "))")
        }
        var r = URLRequest(url: url)
        headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
        let (d, h) = try await data(r)
        guard (200..<300).contains(h.statusCode) else {
            throw HTTPError.status(h.statusCode, String(data: d, encoding: .utf8) ?? "")
        }
        return d
    }

    static func json<T: Decodable>(_ t: T.Type, _ url: URL, headers: [String: String] = [:]) async throws -> T {
        let d = try await get(url, headers: headers)
        do { return try JSONDecoder.lenient.decode(T.self, from: d) }
        catch { throw HTTPError.decoding(String(describing: error)) }
    }
}

extension JSONDecoder {
    static let lenient: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            for f in [ISO8601DateFormatter.withFraction, ISO8601DateFormatter.plain] {
                if let date = f.date(from: s) { return date }
            }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "datum \(s)")
        }
        return d
    }()
}

extension ISO8601DateFormatter {
    static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    static let plain = ISO8601DateFormatter()
}

/// IPTV-API's geven getallen vaak als string of als getal terug. Dit leest beide.
struct Flex: Decodable, Hashable {
    let string: String?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { string = s }
        else if let i = try? c.decode(Int.self) { string = String(i) }
        else if let d = try? c.decode(Double.self) { string = String(d) }
        else if let b = try? c.decode(Bool.self) { string = b ? "1" : "0" }
        else { string = nil }
    }
    var int: Int? { string.flatMap { Int($0) ?? Double($0).map { Int($0) } } }
    var double: Double? { string.flatMap(Double.init) }
}

extension String {
    var urlValue: URL? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return URL(string: t) ?? URL(string: t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
    }
    var trimmedSlash: String { var s = trimmingCharacters(in: .whitespaces); while s.hasSuffix("/") { s.removeLast() }; return s }
}

extension KeyedDecodingContainer {
    /// Tekstveld dat ook als getal, bool, null, [] of {} kan binnenkomen (dan nil of omgezet naar tekst).
    func flexString(_ key: Key) -> String? { (try? decode(Flex.self, forKey: key))?.string }
}

/// Veld dat soms een string en soms een lijst met strings is (bijv. Xtream backdrop_path).
struct StringOrArray: Decodable, Hashable {
    let values: [String]
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let a = try? c.decode([String].self) { values = a }
        else if let s = try? c.decode(String.self) { values = s.isEmpty ? [] : [s] }
        else { values = [] }
    }
    var first: String? { values.first { !$0.isEmpty } }
}
