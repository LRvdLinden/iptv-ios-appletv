import Foundation
import SwiftUI

/// Build 146: support vanuit de app (functie `support`, acties `app_list`, `app_get`, `app_mark_read`, `app_reply`,
/// `app_create`, `app_close`), zie docs/ACCOUNT.md "Build 146" → "Support vanuit de app".
///
/// - Lijst in drie groepen (Open, In behandeling, Gesloten) met de ongelezen antwoorden (`counts.unread`) als badge.
/// - Vernieuwen: bij het openen van de tab, bij terugkeer naar de voorgrond en bij elke heartbeat (elke 5 minuten),
///   zodat ook Apple TV (geen push) een nieuw antwoord ziet.
/// - Niets wordt gelogd (geen onderwerpen, berichten of nummers).
@MainActor
final class SupportCenter: ObservableObject {
    static let shared = SupportCenter()

    struct Ticket: Identifiable, Equatable {
        let number: Int
        var id: Int { number }
        let subject: String
        let status: String
        let group: SupportLogic.Group
        let category: String?
        let createdAt: Date?
        let lastReplyAt: Date?
        let closedAt: Date?
        let canReply: Bool
        let unreadCount: Int
        var unread: Bool { unreadCount > 0 }
        var updatedAt: Date? { lastReplyAt ?? createdAt }
    }

    struct Message: Identifiable, Equatable {
        let id: Int
        /// `customer` (jij), `support` (Bingr Support) of `event` (statuswijziging; `body` = de nieuwe status)
        let author: String
        let body: String
        let createdAt: Date?
        /// soort diagnose-bijlage (`start` of `app`), als die er is
        let diagnostics: String?
    }

    /// Fout van de functie, met een tekst voor in beeld.
    struct Failure: LocalizedError {
        let code: String
        let status: Int
        var errorDescription: String? { SupportCenter.message(for: code, status: status) }
    }

    @Published private(set) var tickets: [Ticket] = []
    @Published private(set) var unread = 0
    @Published private(set) var loading = false
    @Published private(set) var loaded = false
    @Published private(set) var lastError: String?
    /// Deeplink of pushmelding: dit ticket openen zodra de Support-tab er is (nil = alleen de lijst)
    @Published var requestedTicket: Int?

    private var lastRefresh = Date.distantPast
    private var refreshTask: Task<Void, Never>?

    var signedIn: Bool { Secrets.accountsConfigured && AccountService.shared.isSignedIn }

    func tickets(in group: SupportLogic.Group) -> [Ticket] { tickets.filter { $0.group == group } }

    /// `app_list`. `quiet`: zonder laadindicator en zonder foutmelding (heartbeat/voorgrond); hooguit eens per 20 s,
    /// behalve met `force`.
    func refresh(quiet: Bool = false, force: Bool = false) async {
        guard signedIn else { reset(); return }
        if !force, quiet, Date().timeIntervalSince(lastRefresh) < 20 { return }
        if let t = refreshTask { return await t.value }
        let t = Task { @MainActor in
            if !quiet { self.loading = true }
            defer { self.loading = false }
            do {
                let r = try await AccountService.shared.supportCall("app_list", ["status": "all"])
                guard r.status == 200, let items = r.json["items"] as? [[String: Any]] else {
                    if !quiet { self.lastError = Self.message(for: r.json["error"] as? String ?? "", status: r.status) }
                    return
                }
                self.tickets = items.compactMap(Self.ticket)
                let counts = r.json["counts"] as? [String: Any] ?? [:]
                self.unread = (counts["unread"] as? NSNumber)?.intValue ?? self.tickets.reduce(0) { $0 + $1.unreadCount }
                self.loaded = true
                self.lastError = nil
                self.lastRefresh = Date()
            } catch {
                if !quiet { self.lastError = error.localizedDescription }
            }
        }
        refreshTask = t
        await t.value
        refreshTask = nil
    }

    /// `app_get` (zet het ticket op gelezen). 404 = `Failure(code: "not_found")`.
    func get(_ number: Int) async throws -> (ticket: Ticket, messages: [Message]) {
        let r = try await AccountService.shared.supportCall("app_get", ["number": number])
        try Self.check(r)
        guard let t = (r.json["ticket"] as? [String: Any]).flatMap(Self.ticket) else { throw Failure(code: "generic", status: r.status) }
        let list = (r.json["messages"] as? [[String: Any]] ?? []).enumerated().map { i, m in
            Message(id: i, author: (m["author"] as? String ?? "").lowercased(), body: m["body"] as? String ?? "",
                    createdAt: AccountService.parseDate(m["created_at"]),
                    diagnostics: (m["diagnostics"] as? [String: Any])?["kind"] as? String)
        }
        // gelezen: de badge meteen bijwerken (zonder te wachten op de volgende ronde)
        if let i = tickets.firstIndex(where: { $0.number == number }), tickets[i].unreadCount > 0 {
            unread = max(0, unread - tickets[i].unreadCount)
            tickets[i] = Self.withUnread(tickets[i], 0)
        }
        return (t, list)
    }

    func reply(_ number: Int, message: String, diagnostics: [String: Any]?) async throws {
        var body: [String: Any] = ["number": number, "message": message]
        if let diagnostics { body["diagnostics"] = diagnostics }
        let r = try await AccountService.shared.supportCall("app_reply", body)
        try Self.check(r)
        await refresh(quiet: true, force: true)
    }

    /// Nieuw ticket (geen captcha). Geeft het nummer terug.
    func create(subject: String, message: String, category: String, diagnostics: [String: Any]?) async throws -> Int {
        var body: [String: Any] = ["subject": subject, "message": message, "category": category,
                                   "device_id": AccountService.shared.deviceID,
                                   "platform": AccountService.entitlementsPlatform,
                                   "app_version": AccountService.appVersion,
                                   "lang": Localizer.shared.language == "nl" ? "nl" : "en"]
        if let diagnostics { body["diagnostics"] = diagnostics }
        let r = try await AccountService.shared.supportCall("app_create", body)
        try Self.check(r)
        guard let n = (r.json["number"] as? NSNumber)?.intValue else { throw Failure(code: "generic", status: r.status) }
        await refresh(quiet: true, force: true)
        return n
    }

    func close(_ number: Int) async throws {
        let r = try await AccountService.shared.supportCall("app_close", ["number": number])
        try Self.check(r)
        await refresh(quiet: true, force: true)
    }

    /// Uitgelogd of ander account: niets van het vorige account laten staan.
    func reset() {
        refreshTask?.cancel()
        refreshTask = nil
        tickets = []
        unread = 0
        loaded = false
        lastError = nil
        lastRefresh = .distantPast
    }

    // MARK: - JSON

    private static func check(_ r: (status: Int, json: [String: Any])) throws {
        guard (200..<300).contains(r.status), r.json["error"] == nil else {
            throw Failure(code: (r.json["error"] as? String) ?? "generic", status: r.status)
        }
    }

    private static func ticket(_ j: [String: Any]) -> Ticket? {
        guard let n = (j["number"] as? NSNumber)?.intValue ?? (j["number"] as? String).flatMap({ Int($0) }) else { return nil }
        let status = (j["status"] as? String ?? "new").lowercased()
        return Ticket(number: n, subject: j["subject"] as? String ?? "", status: status,
                      group: SupportLogic.group(status: status, group: j["group"] as? String),
                      category: j["category"] as? String,
                      createdAt: AccountService.parseDate(j["created_at"]),
                      lastReplyAt: AccountService.parseDate(j["last_reply_at"]),
                      closedAt: AccountService.parseDate(j["closed_at"]),
                      canReply: (j["can_reply"] as? Bool) ?? (status != "closed"),
                      unreadCount: (j["unread_count"] as? NSNumber)?.intValue ?? ((j["unread"] as? Bool) == true ? 1 : 0))
    }

    private static func withUnread(_ t: Ticket, _ n: Int) -> Ticket {
        Ticket(number: t.number, subject: t.subject, status: t.status, group: t.group, category: t.category,
               createdAt: t.createdAt, lastReplyAt: t.lastReplyAt, closedAt: t.closedAt, canReply: t.canReply, unreadCount: n)
    }

    // MARK: - Teksten

    static func message(for code: String, status: Int) -> String {
        switch code {
        case "subject_missing", "subject_too_long": return L("Enter a subject of 3 to 120 characters.")
        case "message_too_short", "message_missing": return L("Write at least 10 characters.")
        case "message_too_long": return L("Your message is too long (max. 5000 characters).")
        case "too_many_links": return L("Use no more than 6 links.")
        case "closed": return L("This ticket is closed.")
        case "not_found": return L("This ticket can't be found.")
        case "rate_limited": return L("Too many attempts. Wait a few minutes and try again.")
        case "user_banned": return L("Your account has been blocked. You received an email with the reason and until when. Questions? Go to support.bingr.online.")
        default:
            return status == 0 ? L("No connection. Check your internet connection.") : L("Couldn't send. Try again later.")
        }
    }

    /// Status zoals op support.bingr.online
    static func statusTitle(_ status: String) -> String {
        switch status {
        case "new": return L("New")
        case "open": return L("In progress")
        case "pending": return L("Waiting for your reply")
        case "resolved": return L("Resolved")
        case "closed": return L("Closed")
        default: return status
        }
    }

    static func groupTitle(_ g: SupportLogic.Group) -> String {
        switch g {
        case .open: return L("Open")
        case .inProgress: return L("In progress")
        case .closed: return L("Closed")
        }
    }

    static func categoryTitle(_ c: String) -> String {
        switch c {
        case "account": return L("Account and sign-in")
        case "afspelen": return L("Playback and streams")
        case "apps": return L("Apps and installing")
        case "website": return L("Website and web player")
        default: return L("Other")
        }
    }
}
