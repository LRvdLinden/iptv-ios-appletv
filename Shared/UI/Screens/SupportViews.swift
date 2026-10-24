import SwiftUI

// Build 146: Support in de app (Instellingen → Support, ook vanuit het profielmenu, een pushmelding of
// `bingr://support/ticket?n=`): tickets in drie groepen, een ticket met het gesprek, reageren, sluiten en een nieuw
// ticket met de diagnose als bijlage. Niet ingelogd: uitleg en een knop naar support.bingr.online.

/// Rood bolletje met een aantal (ongelezen antwoorden)
struct CountBadge: View {
    let count: Int
    var body: some View {
        if count > 0 {
            Text(verbatim: count > 99 ? "99+" : "\(count)")
                .font(.system(size: tvScaled(12), weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, tvScaled(6))
                .frame(minWidth: tvScaled(20), minHeight: tvScaled(20))
                .background(Capsule().fill(Color.red))
                .accessibilityLabel(L("%d unread", count))
        }
    }
}

struct SupportView: View {
    @ObservedObject private var center = SupportCenter.shared
    @ObservedObject private var account = AccountService.shared
    @State private var newTicket = false
    @State private var showSite = false
    /// deeplink/pushmelding: dit ticket meteen openen
    @State private var deepNumber: Int?

    private var signedIn: Bool { Secrets.accountsConfigured && account.isSignedIn }

    var body: some View {
        List {
            if !signedIn {
                Section {
                    Label(L("Sign in to your Bingr account to see your support tickets and read replies in the app."),
                          systemImage: "person.crop.circle.badge.questionmark")
                    Button { showSite = true } label: { Label(L("Open support.bingr.online"), systemImage: "safari") }
                }
            } else {
                Section {
                    Button { newTicket = true } label: { Label(L("New ticket"), systemImage: "square.and.pencil") }
                    Button { Task { await center.refresh(force: true) } } label: {
                        HStack {
                            Label(L("Refresh"), systemImage: "arrow.clockwise")
                            if center.loading { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(center.loading)
                    if StartDiagnostics.shared.lastProblem != nil {
                        Text(L("The previous start didn't finish properly. You can send the start diagnostics with a new ticket."))
                            .font(.footnote).foregroundStyle(Theme.secondary)
                    }
                    if let e = center.lastError { Text(e).font(.footnote).foregroundStyle(Theme.red) }
                }
                ForEach(SupportLogic.Group.allCases) { g in
                    let items = center.tickets(in: g)
                    Section {
                        if items.isEmpty {
                            Text(center.loaded ? L("No tickets") : L("Loading…")).foregroundStyle(Theme.secondary)
                        } else {
                            ForEach(items) { t in
                                NavigationLink { SupportTicketView(number: t.number) } label: { SupportTicketRow(ticket: t) }
                            }
                        }
                    } header: {
                        Text(verbatim: "\(SupportCenter.groupTitle(g)) (\(items.count))")
                    }
                }
                Section {
                    Button { showSite = true } label: { Label(L("Open support.bingr.online"), systemImage: "safari") }
                } footer: {
                    Text(L("Your tickets from the app are also on support.bingr.online, under My tickets."))
                }
            }
        }
        .navigationTitle(L("Support"))
        .task { await center.refresh(force: true) }
        .onAppear(perform: takeRequest)
        .onChange(of: center.requestedTicket) { _, _ in takeRequest() }
        .onChange(of: account.isSignedIn) { _, _ in Task { await center.refresh(force: true) } }
        .sheet(isPresented: $newTicket) { NewTicketView() }
        .supportPage(isPresented: $showSite)
        .navigationDestination(isPresented: Binding(get: { deepNumber != nil }, set: { if !$0 { deepNumber = nil } })) {
            if let n = deepNumber { SupportTicketView(number: n) }
        }
    }

    /// Ticket uit een pushmelding of deeplink openen (niet ingelogd: de uitleg met de knop naar de site).
    private func takeRequest() {
        guard let n = center.requestedTicket else { return }
        center.requestedTicket = nil
        guard signedIn else { return }
        deepNumber = n
    }
}

struct SupportTicketRow: View {
    let ticket: SupportCenter.Ticket
    var body: some View {
        HStack(spacing: tvScaled(12)) {
            Circle().fill(ticket.unread ? Color.red : Color.clear).frame(width: tvScaled(8), height: tvScaled(8))
            VStack(alignment: .leading, spacing: 3) {
                Text(ticket.subject.isEmpty ? L("Ticket #%@", String(ticket.number)) : ticket.subject)
                    .font(.system(size: tvScaled(15), weight: ticket.unread ? .bold : .regular))
                    .lineLimit(2)
                Text(verbatim: "#\(ticket.number) · \(SupportCenter.statusTitle(ticket.status))"
                     + (ticket.updatedAt.map { " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""))
                    .font(.system(size: tvScaled(12))).foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            CountBadge(count: ticket.unreadCount)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Eén ticket: het gesprek, reageren en sluiten. 404 (ander account, of het ticket bestaat niet meer): terug naar de lijst.
struct SupportTicketView: View {
    let number: Int
    @Environment(\.dismiss) private var dismiss
    @State private var ticket: SupportCenter.Ticket?
    @State private var messages: [SupportCenter.Message] = []
    @State private var loading = true
    @State private var error: String?
    @State private var reply = ""
    @State private var sending = false
    @State private var withDiagnostics = false
    @State private var confirmClose = false
    @State private var newTicket = false

    var body: some View {
        List {
            if let t = ticket {
                Section {
                    Text(t.subject).font(.headline)
                    LabeledContent(L("Number"), value: "#\(t.number)")
                    LabeledContent(L("Status"), value: SupportCenter.statusTitle(t.status))
                    if let c = t.category { LabeledContent(L("Category"), value: SupportCenter.categoryTitle(c)) }
                }
                Section(L("Conversation")) {
                    ForEach(messages) { m in MessageRow(message: m) }
                }
                if t.canReply {
                    Section {
                        replyField
                        if StartDiagnostics.shared.lastProblem != nil {
                            Toggle(L("Send start diagnostics"), isOn: $withDiagnostics)
                        }
                        Button { send() } label: {
                            HStack {
                                Label(L("Send reply"), systemImage: "paperplane")
                                if sending { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(sending || reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if t.status == "pending" {
                            Text(L("Waiting for your reply")).font(.footnote).foregroundStyle(Theme.imdb)
                        }
                    } header: { Text(L("Reply")) }
                    Section {
                        Button(role: .destructive) { confirmClose = true } label: {
                            Label(L("Close ticket"), systemImage: "checkmark.circle")
                        }
                    }
                } else {
                    Section {
                        Text(L("This ticket is closed.")).foregroundStyle(Theme.secondary)
                        Button { newTicket = true } label: { Label(L("New ticket"), systemImage: "square.and.pencil") }
                    }
                }
            } else if loading {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(Theme.red) }
        }
        .navigationTitle(L("Ticket #%@", String(number)))
        .task { await load() }
        .sheet(isPresented: $newTicket) { NewTicketView() }
        .confirmationDialog(L("Close this ticket?"), isPresented: $confirmClose, titleVisibility: .visible) {
            Button(L("Close ticket"), role: .destructive) { close() }
            Button(L("Cancel"), role: .cancel) {}
        }
    }

    @ViewBuilder private var replyField: some View {
        #if os(tvOS)
        TextField(L("Your reply"), text: $reply)
        #else
        TextField(L("Your reply"), text: $reply, axis: .vertical).lineLimit(3...10)
        #endif
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let r = try await SupportCenter.shared.get(number)
            ticket = r.ticket
            messages = r.messages
            error = nil
        } catch let f as SupportCenter.Failure where f.code == "not_found" {
            // niet van dit account of niet meer: de ticketlijst
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func send() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if let code = SupportLogic.validate(subject: nil, message: text, reply: true) {
            error = SupportCenter.message(for: code, status: 400)
            return
        }
        sending = true
        let diag = withDiagnostics ? DiagnosticsBuilder.start(problem: StartDiagnostics.shared.lastProblem).json : nil
        Task { @MainActor in
            defer { sending = false }
            do {
                try await SupportCenter.shared.reply(number, message: text, diagnostics: diag)
                reply = ""
                withDiagnostics = false
                await load()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func close() {
        Task { @MainActor in
            do {
                try await SupportCenter.shared.close(number)
                await load()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private struct MessageRow: View {
    let message: SupportCenter.Message

    var body: some View {
        if message.author == "event" {
            Label(L("Status: %@", SupportCenter.statusTitle(message.body)), systemImage: "arrow.triangle.2.circlepath")
                .font(.footnote).foregroundStyle(Theme.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(message.author == "support" ? L("Bingr Support") : L("You"))
                        .font(.system(size: tvScaled(13), weight: .bold))
                        .foregroundStyle(message.author == "support" ? Theme.red : Color.primary)
                    Spacer()
                    if let d = message.createdAt {
                        Text(d.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: tvScaled(11))).foregroundStyle(Theme.secondary)
                    }
                }
                Text(Self.linked(message.body))
                    .font(.system(size: tvScaled(14)))
                    .fixedSize(horizontal: false, vertical: true)
                if let k = message.diagnostics {
                    Label(k == "start" ? L("Start diagnostics attached") : L("App diagnostics attached"), systemImage: "paperclip")
                        .font(.system(size: tvScaled(11))).foregroundStyle(Theme.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// Platte tekst met aanklikbare links (geen andere opmaak).
    private static func linked(_ s: String) -> AttributedString {
        var a = AttributedString(s)
        guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return a }
        for m in det.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let url = m.url, let r = Range(m.range, in: s), let ar = Range(r, in: a),
                  let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { continue }
            a[ar].link = url
        }
        return a
    }
}

/// Nieuw ticket: onderwerp, categorie, bericht en "Diagnose meesturen" (standaard aan, met "Bekijken").
struct NewTicketView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var playlists: PlaylistService
    @State private var subject = ""
    @State private var category = "apps"
    @State private var message = ""
    @State private var withDiagnostics = true
    @State private var sending = false
    @State private var error: String?
    @State private var sent: Int?

    /// Na een problematische start: de startdiagnose; anders de app-diagnose (app en apparaat, zonder netwerkcheck)
    private var diagnostics: SupportDiagnostics {
        if let p = StartDiagnostics.shared.lastProblem { return DiagnosticsBuilder.start(problem: p, playlists: playlists) }
        var d = DiagnosticsBuilder.base(.app)
        let store = CloudStore.shared
        let lib = playlists.library
        d.milestones = StartDiagnostics.shared.currentMarks.map { (name: $0.name, seconds: $0.t, ok: nil) }
        var state: [String: Any] = [
            "signedIn": true, "profiles": store.profiles.count, "servers": store.playlists.count,
            "serverKinds": Array(Set(store.playlists.map { $0.kind.rawValue })).sorted(),
            "channels": lib.channels.count, "movies": lib.movies.count, "series": lib.series.count,
            "uptimeS": Int(StartDiagnostics.shared.uptime),
            "pushEnabled": PushService.isSupported && PushService.shared.isOn,
        ]
        if let s = store.lastSync { state["lastSync"] = SupportDiagnostics.iso(s) }
        if let plan = EntitlementsService.shared.plan { state["plan"] = plan.rawValue }
        d.state = state
        // build 147: altijd de startdiagnose (deze en de vorige start), ophalen per server, verbinding en opslag
        DiagnosticsBuilder.enrich(&d, problem: nil, playlists: playlists)
        return d
    }

    var body: some View {
        NavigationStack {
            Form {
                if let n = sent {
                    Section {
                        Label(L("Sent as ticket #%@", String(n)), systemImage: "checkmark.circle.fill").foregroundStyle(Theme.green)
                        Text(L("You'll find the reply here and by email.")).foregroundStyle(Theme.secondary)
                        Button(L("Done")) { dismiss() }
                    }
                } else {
                    Section {
                        TextField(L("Subject"), text: $subject)
                        Picker(L("Category"), selection: $category) {
                            ForEach(SupportLogic.categories, id: \.self) { Text(SupportCenter.categoryTitle($0)).tag($0) }
                        }
                        messageField
                    }
                    Section {
                        Toggle(StartDiagnostics.shared.lastProblem != nil ? L("Send start diagnostics") : L("Send diagnostics"),
                               isOn: $withDiagnostics)
                        if withDiagnostics {
                            NavigationLink { DiagnosticsPreview(text: diagnostics.prettyText) } label: {
                                Label(L("View"), systemImage: "doc.text.magnifyingglass")
                            }
                        }
                    } footer: {
                        Text(L("No personal data: no addresses, server names, user names or email addresses."))
                    }
                    Section {
                        Button { send() } label: {
                            HStack {
                                Label(L("Send"), systemImage: "paperplane")
                                if sending { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(sending)
                        if let error { Text(error).font(.footnote).foregroundStyle(Theme.red) }
                    }
                }
            }
            .navigationTitle(L("New ticket"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { dismiss() } }
            }
        }
    }

    @ViewBuilder private var messageField: some View {
        #if os(tvOS)
        TextField(L("Your message"), text: $message)
        #else
        TextField(L("Your message"), text: $message, axis: .vertical).lineLimit(4...12)
        #endif
    }

    private func send() {
        let s = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let m = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if let code = SupportLogic.validate(subject: s, message: m, reply: false) {
            error = SupportCenter.message(for: code, status: 400)
            return
        }
        error = nil
        sending = true
        let diag = withDiagnostics ? diagnostics.json : nil
        Task { @MainActor in
            defer { sending = false }
            do {
                sent = try await SupportCenter.shared.create(subject: s, message: m, category: category, diagnostics: diag)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
