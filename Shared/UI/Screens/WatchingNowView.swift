import SwiftUI

/// Tegelijk kijken (build 51), zie docs/ACCOUNT.md: "Too many people are watching" in de speler,
/// en voor het hoofdprofiel in Mijn Bingr → Account "Watching now" en "Watch history (7 days)".

// MARK: - Weergave

enum StreamText {
    /// SF Symbol per platform (zelfde als bij Apparaten).
    static func icon(platform: String, name: String) -> String {
        DeviceText.icon(AccountService.Device(id: "", name: name, platform: platform, createdAt: nil, lastSeenAt: nil, current: false))
    }

    /// "Watching for %@": "12 min" of "1 h 5 min".
    static func watchingFor(_ start: Date?, now: Date = Date()) -> String? {
        guard let start else { return nil }
        let mins = max(0, Int(now.timeIntervalSince(start) / 60))
        let value = mins < 60 ? L("%d min", mins) : "\(mins / 60) h " + L("%d min", mins % 60)
        return L("Watching for %@", value)
    }

    static func signedInSince(_ d: Date?) -> String? {
        guard let d else { return nil }
        return L("Signed in since %@", d.formatted(date: .abbreviated, time: .omitted))
    }

    /// Kop per dag: "Today", "Yesterday" of de dag en datum ("maandag 12 oktober").
    static func dayTitle(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return L("Today") }
        if cal.isDateInYesterday(d) { return L("Yesterday") }
        return d.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Localizer.shared.locale))
    }
}

// MARK: - Profielfoto bij Nu kijken en kijkgeschiedenis (build 57)

/// Klein rond profielplaatje van een profiel van het account: zoekt op `profile_id`, anders op naam;
/// onbekend profiel → beginletter in een gekleurde cirkel. Zelfde weergave als de profielkiezer
/// (eigen foto uit de bucket `avatars`, getekend figuurtje of symbool op kleurverloop).
struct AccountProfileAvatar: View {
    let profileID: String?
    let profileName: String
    var size: CGFloat = tvScaled(30)
    @ObservedObject private var store = CloudStore.shared

    private var profile: ViewerProfile? {
        if let id = profileID.flatMap(UUID.init(uuidString:)), let p = store.profiles.first(where: { $0.id == id }) { return p }
        let n = profileName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return nil }
        return store.profiles.first { $0.name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(n) == .orderedSame }
    }

    var body: some View {
        Group {
            if let p = profile {
                ZStack {
                    Circle().fill(p.avatar.gradient)
                    if let img = AvatarImageCache.image(for: p.id, data: store.photos[p.id]) {
                        Color.clear.overlay(Image(uiImage: img).resizable().scaledToFill()).clipShape(Circle())
                    } else {
                        AvatarGlyph(avatar: p.avatar, size: size * 0.45).clipShape(Circle())
                    }
                }
            } else {
                // geen bekend profiel: beginletter op een vaste kleur per naam
                ZStack {
                    Circle().fill(Self.fallbackGradient(profileName))
                    Text(Self.initial(profileName))
                        .font(.system(size: size * 0.48, weight: .bold)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(profileName)
    }

    static func initial(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
    }

    /// Vaste kleur per naam (niet `hashValue`: die verschilt per app-start).
    static func fallbackGradient(_ name: String) -> LinearGradient {
        let sum = name.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return PlaylistAvatar(symbol: "person", colorIndex: sum % PlaylistAvatar.palettes.count).gradient
    }
}

/// Gedecodeerde profielfoto's, zodat lijsten niet bij elke weergave opnieuw een JPEG decoderen.
@MainActor
enum AvatarImageCache {
    private static var cache: [UUID: (size: Int, image: UIImage)] = [:]

    static func image(for id: UUID, data: Data?) -> UIImage? {
        guard let data else { cache[id] = nil; return nil }
        if let c = cache[id], c.size == data.count { return c.image }
        guard let img = UIImage(data: data) else { return nil }
        cache[id] = (data.count, img)
        return img
    }
}

/// Eén stream: apparaat-icoon en naam, profiel, titel en (optioneel) hoe lang al en ingelogd sinds.
struct ActiveStreamRow: View {
    let stream: AccountService.ActiveStream
    var details = true

    var body: some View {
        HStack(alignment: .top, spacing: tvScaled(14)) {
            // profielfoto vóór de tekst (build 57)
            AccountProfileAvatar(profileID: stream.profileID, profileName: stream.profileName, size: tvScaled(30))
            Image(systemName: StreamText.icon(platform: stream.platform, name: stream.deviceName))
                .accessibilityLabel(DeviceText.platformLabel(stream.platform))
                .font(.system(size: tvScaled(22)))
                .foregroundStyle(stream.deviceID == AccountService.shared.deviceID ? Theme.red : .white)
                .frame(width: tvScaled(34))
            VStack(alignment: .leading, spacing: tvScaled(3)) {
                HStack(spacing: tvScaled(8)) {
                    Text(stream.deviceName).font(.system(size: tvScaled(16), weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    if !stream.profileName.isEmpty {
                        Text(stream.profileName).font(.system(size: tvScaled(13))).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                }
                if !stream.title.isEmpty {
                    Text(stream.title).font(.system(size: tvScaled(14))).foregroundStyle(.white.opacity(0.9)).lineLimit(2)
                }
                if details {
                    if let w = StreamText.watchingFor(stream.startedAt) {
                        Text(w).font(.system(size: tvScaled(12))).foregroundStyle(Theme.secondary)
                    }
                    if let s = StreamText.signedInSince(stream.signedInAt) {
                        Text(s).font(.system(size: tvScaled(12))).foregroundStyle(Theme.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, tvScaled(4))
    }
}

// MARK: - Speler: "Too many people are watching"

struct StreamLimitView: View {
    let limit: AccountService.StreamLimit
    let onRetry: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: tvScaled(16)) {
                    Image(systemName: "person.3.fill").font(.system(size: tvScaled(34))).foregroundStyle(Theme.red)
                    Text(L("Too many people are watching"))
                        .font(.system(size: tvScaled(26), weight: .bold)).foregroundStyle(.white)
                    Text(L("Your account can be used on up to %d screens at the same time.", limit.limit))
                        .font(.system(size: tvScaled(15))).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 0) {
                        ForEach(limit.streams) { s in
                            ActiveStreamRow(stream: s, details: false).padding(.vertical, tvScaled(4))
                            if s.id != limit.streams.last?.id { Divider().overlay(Color.white.opacity(0.12)) }
                        }
                    }
                    HStack(spacing: tvScaled(14)) {
                        NetflixButton(title: L("Try again"), icon: "arrow.clockwise") { onRetry() }
                        NetflixButton(title: L("Close"), icon: "xmark", kind: .secondary) { onClose() }
                    }
                    .padding(.top, tvScaled(6))
                }
                .padding(tvScaled(28))
                .frame(maxWidth: tvScaled(600), alignment: .leading)
                .background(Color(hex: 0x141414), in: RoundedRectangle(cornerRadius: tvScaled(14)))
                .overlay(RoundedRectangle(cornerRadius: tvScaled(14)).stroke(Color.white.opacity(0.08)))
                .padding(.horizontal, Theme.edge)
                .padding(.vertical, tvScaled(30))
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Mijn Bingr → Account → Watching now

/// Rij in Mijn Bingr → Account: "Watching now" met "%d of %d watching now".
struct WatchingNowRow: View {
    @EnvironmentObject var account: AccountService
    @State private var data: AccountService.StreamLimit?

    var body: some View {
        NavigationLink { WatchingNowView() } label: {
            HStack {
                Label(L("Watching now"), systemImage: "play.tv")
                Spacer()
                if let data {
                    Text(L("%d of %d watching now", data.streams.count, data.limit))
                        .font(.system(size: tvScaled(13))).foregroundStyle(Theme.secondary)
                }
            }
        }
        .task {
            data = try? await account.listStreams()
        }
    }
}

struct WatchingNowView: View {
    @EnvironmentObject var account: AccountService
    @State private var data: AccountService.StreamLimit?
    @State private var error: String?
    @State private var now = Date()

    var body: some View {
        List {
            Section {
                if let data {
                    if data.streams.isEmpty {
                        Text(L("Nobody is watching right now.")).foregroundStyle(Theme.secondary)
                    }
                    ForEach(data.streams) { s in ActiveStreamRow(stream: s) }
                } else if error == nil {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(AuthForm.errorColor)
                }
            } header: {
                if let data { Text(L("%d of %d watching now", data.streams.count, data.limit)) }
            }
        }
        .id(now)   // "Watching for" bijwerken
        .navigationTitle(L("Watching now"))
        .task {
            // elke 30 s verversen zolang het scherm open is
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    @MainActor private func load() async {
        do {
            data = try await account.listStreams()
            error = nil
        } catch is CancellationError {
        } catch {
            if data == nil { self.error = error.localizedDescription }
        }
        now = Date()
    }
}

// MARK: - Mijn Bingr → Account → Watch history (7 days)

struct WatchLogView: View {
    @EnvironmentObject var account: AccountService
    @EnvironmentObject var playlists: PlaylistService
    @State private var entries: [AccountService.WatchLogEntry]?
    @State private var error: String?
    @State private var detail: DetailTarget?

    private var days: [(day: Date, items: [AccountService.WatchLogEntry])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: entries ?? []) { cal.startOfDay(for: $0.startedAt) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!.sorted { $0.startedAt > $1.startedAt }) }
    }

    var body: some View {
        List {
            if let entries, entries.isEmpty {
                Text(L("Nothing watched in the last 7 days.")).foregroundStyle(Theme.secondary)
            } else if entries == nil && error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
            if let error { Text(error).font(.caption).foregroundStyle(AuthForm.errorColor) }
            ForEach(days, id: \.day) { d in
                Section(StreamText.dayTitle(d.day)) {
                    ForEach(d.items) { e in
                        if let target = target(e) {
                            Button { detail = target } label: { row(e, chevron: true) }
                        } else {
                            row(e, chevron: false)
                                #if os(tvOS)
                                .focusable()
                                #endif
                        }
                    }
                }
            }
        }
        .navigationTitle(L("Watch history (7 days)"))
        #if !os(tvOS)
        .sheet(item: $detail) { DetailView(target: $0).presentationDragIndicator(.visible) }
        #else
        .fullScreenCover(item: $detail) { DetailView(target: $0) }
        #endif
        .task { await load() }
        #if !os(tvOS)
        .refreshable { await load() }
        #endif
    }

    private func row(_ e: AccountService.WatchLogEntry, chevron: Bool) -> some View {
        HStack(alignment: .top, spacing: tvScaled(12)) {
            // profielfoto vóór de tekst (build 57)
            AccountProfileAvatar(profileID: e.profileID, profileName: e.profileName, size: tvScaled(30))
            Text(e.startedAt.formatted(date: .omitted, time: .shortened))
                .font(.system(size: tvScaled(13)).monospacedDigit()).foregroundStyle(Theme.secondary)
                .frame(width: tvScaled(52), alignment: .leading)
            VStack(alignment: .leading, spacing: tvScaled(3)) {
                Text(e.title.isEmpty ? "—" : e.title)
                    .font(.system(size: tvScaled(15), weight: .semibold)).foregroundStyle(.white).lineLimit(2)
                HStack(spacing: tvScaled(6)) {
                    Image(systemName: StreamText.icon(platform: e.platform, name: e.deviceName))
                        .accessibilityLabel(DeviceText.platformLabel(e.platform))
                    Text([e.profileName, e.deviceName].filter { !$0.isEmpty }.joined(separator: " · ")).lineLimit(1)
                }
                .font(.system(size: tvScaled(12))).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: tvScaled(6))
            Text(L("%d min", e.minutes)).font(.system(size: tvScaled(13)).monospacedDigit()).foregroundStyle(Theme.secondary)
            if chevron {
                Image(systemName: "chevron.right").font(.system(size: tvScaled(12), weight: .semibold)).foregroundStyle(Theme.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    /// Film of aflevering die in de bibliotheek staat → detailpagina (op titel; het logboek heeft geen id's).
    private func target(_ e: AccountService.WatchLogEntry) -> DetailTarget? {
        let lib = playlists.library
        switch e.kind {
        case "movie":
            let t = e.title
            return lib.movies.first(where: { $0.title.caseInsensitiveCompare(t) == .orderedSame }).map { .movie($0) }
        case "episode":
            let t = e.title.components(separatedBy: " · ").first ?? e.title
            return lib.series.first(where: { $0.title.caseInsensitiveCompare(t) == .orderedSame }).map { .series($0) }
        default:
            return nil
        }
    }

    @MainActor private func load() async {
        do {
            entries = try await account.watchLog(days: 7)
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}
