import Foundation

/// XMLTV (EPG) parser. Ondersteunt ook .xml.gz.
final class XMLTVParser: NSObject, XMLParserDelegate {
    private var programs: [String: [EPGProgram]] = [:]
    private var current: (channel: String, start: Date, end: Date)?
    private var title = "", desc = "", text = "", element = ""
    private let window: ClosedRange<Date>

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMddHHmmss Z"
        return f
    }()
    private static let fmtNoTZ: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMddHHmmss"
        return f
    }()

    init(window: ClosedRange<Date>) { self.window = window }

    static func parse(_ data: Data, daysBack: Int = 1, daysAhead: Int = 3) -> [String: [EPGProgram]] {
        let now = Date()
        let p = XMLTVParser(window: now.addingTimeInterval(Double(-daysBack) * 86400)...now.addingTimeInterval(Double(daysAhead) * 86400))
        let xml = XMLParser(data: gunzipIfNeeded(data))
        xml.delegate = p
        xml.parse()
        return p.programs.mapValues { $0.sorted { $0.start < $1.start } }
    }

    private static func date(_ s: String?) -> Date? {
        guard let s = s?.trimmingCharacters(in: .whitespaces) else { return nil }
        return fmt.date(from: s) ?? fmtNoTZ.date(from: String(s.prefix(14)))
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes a: [String: String] = [:]) {
        element = name; text = ""
        if name == "programme", let ch = a["channel"], let s = Self.date(a["start"]), let e = Self.date(a["stop"]) {
            current = (ch, s, e); title = ""; desc = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "title": if current != nil && title.isEmpty { title = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        case "desc": if current != nil && desc.isEmpty { desc = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        case "programme":
            if let c = current, c.end >= window.lowerBound, c.start <= window.upperBound {
                programs[c.channel, default: []].append(
                    EPGProgram(channelID: c.channel, title: title, description: desc.isEmpty ? nil : desc, start: c.start, end: c.end))
            }
            current = nil
        default: break
        }
    }

    /// Haalt de gzip-header eraf en pakt de raw-deflate data uit.
    static func gunzipIfNeeded(_ data: Data) -> Data {
        guard data.count > 18, data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b else { return data }
        let bytes = [UInt8](data)
        let flags = bytes[3]
        var i = 10
        if flags & 0x04 != 0 { i += 2 + Int(bytes[i]) + Int(bytes[i + 1]) << 8 }   // FEXTRA
        if flags & 0x08 != 0 { while i < bytes.count && bytes[i] != 0 { i += 1 }; i += 1 } // FNAME
        if flags & 0x10 != 0 { while i < bytes.count && bytes[i] != 0 { i += 1 }; i += 1 } // FCOMMENT
        if flags & 0x02 != 0 { i += 2 }                                                     // FHCRC
        guard i < bytes.count - 8 else { return data }
        let deflate = Data(bytes[i..<(bytes.count - 8)])
        return (try? (deflate as NSData).decompressed(using: .zlib) as Data) ?? data
    }
}
