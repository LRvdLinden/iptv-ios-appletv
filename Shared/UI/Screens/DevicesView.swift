import SwiftUI

/// Gekoppelde apparaten (limiet komt van de server, build 51: 15), zie "Gekoppelde apparaten" in docs/ACCOUNT.md.

// MARK: - Weergave

enum DeviceText {
    /// SF Symbol per platform.
    static func icon(_ d: AccountService.Device) -> String {
        // Apple TV altijd met het symbool "appletv" (ook bij een andere schrijfwijze van het platform)
        if isAppleTV(d.platform, name: d.name) { return "appletv" }
        if isTizen(d.platform) || isWebOS(d.platform) { return "tv" }
        if isWindows(d.platform) { return "pc" }
        if isBrowser(d.platform) { return "globe" }
        switch d.platform {
        case "iPhone": return "iphone"
        case "iPad": return "ipad"
        case "Apple TV": return "appletv"
        case "Mac": return d.name.localizedCaseInsensitiveContains("macbook") ? "macbook" : "desktopcomputer"
        case "Android": return "candybarphone"
        case "Android tablet": return "ipad.landscape"
        case "Android TV", "Google TV", "Fire TV": return "tv"
        default: return "display"
        }
    }

    /// Apple TV-app: platform "Apple TV" (ook "appletv", "tvOS"); zonder platform herkend aan de naam.
    static func isAppleTV(_ platform: String, name: String) -> Bool {
        let p = platform.lowercased().replacingOccurrences(of: " ", with: "")
        if p == "appletv" || p == "tvos" { return true }
        return p.isEmpty && name.localizedCaseInsensitiveContains("Apple TV")
    }

    /// Samsung TV-app (Tizen, vanaf build 55) meldt zich met platform `tizen`.
    static func isTizen(_ platform: String) -> Bool {
        platform.caseInsensitiveCompare("tizen") == .orderedSame || platform.caseInsensitiveCompare("Samsung TV") == .orderedSame
    }

    /// Build 147: de LG TV-app (webOS) meldt zich met platform `webos`.
    static func isWebOS(_ platform: String) -> Bool {
        let p = platform.lowercased().replacingOccurrences(of: " ", with: "")
        return p == "webos" || p == "lgtv" || p == "lgwebos"
    }

    /// Build 146: de Windows-app (webspeler in een eigen venster) meldt zich met platform `windows`.
    static func isWindows(_ platform: String) -> Bool {
        platform.caseInsensitiveCompare("windows") == .orderedSame
    }

    /// Webspeler op bingr.online/web (build 62) meldt zich met platform `browser` (naam bv. "Chrome op Mac").
    static func isBrowser(_ platform: String) -> Bool {
        platform.caseInsensitiveCompare("browser") == .orderedSame
    }

    /// Platformnaam zoals getoond onder de apparaatnaam (`tizen` wordt "Samsung TV", `webos` wordt "LG TV", `browser` wordt "Browser").
    static func platformLabel(_ platform: String) -> String {
        if isTizen(platform) { return L("Samsung TV") }
        if isWebOS(platform) { return "LG TV" }
        if isWindows(platform) { return "Windows" }
        if isBrowser(platform) { return L("Browser") }
        return platform
    }

    /// "Linked %@" met een datum (medium, bv. 12 okt 2026).
    static func linked(_ d: AccountService.Device) -> String? {
        guard let date = d.createdAt else { return nil }
        return L("Linked %@", dateFormatter.string(from: date))
    }

    /// "Last used %@": "Now" (dit apparaat), "just now", "5 min ago", vandaag de tijd, "yesterday", anders de datum.
    static func lastUsed(_ d: AccountService.Device, now: Date = Date()) -> String? {
        if d.current { return L("Last used %@", L("Now")) }
        guard let date = d.lastSeenAt else { return nil }
        let secs = max(0, now.timeIntervalSince(date))
        let value: String
        if secs < 60 {
            value = L("just now")
        } else if secs < 3600 {
            value = L("%d min ago", Int(secs / 60))
        } else if Calendar.current.isDateInToday(date) {
            value = timeFormatter.string(from: date)
        } else if Calendar.current.isDateInYesterday(date) {
            value = L("yesterday")
        } else {
            value = dateFormatter.string(from: date)
        }
        return L("Last used %@", value)
    }

    private static var dateFormatter: DateFormatter {
        let f = DateFormatter()
        f.locale = Localizer.shared.locale
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }

    private static var timeFormatter: DateFormatter {
        let f = DateFormatter()
        f.locale = Localizer.shared.locale
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }
}

/// Eén apparaat: icoon, naam, platform, gekoppeld, laatst gebruikt, "This device" en knoppen "Rename" en "Remove".
struct DeviceRow: View {
    let device: AccountService.Device
    let busy: Bool
    /// nil = geen knop "Rename" (bv. op "Too many devices").
    var onRename: (() -> Void)? = nil
    let onRemove: () -> Void

    var body: some View {
        // Knoppen onder de tekst, zodat naam en gegevens de volle breedte hebben (build 61).
        HStack(alignment: .top, spacing: tvScaled(14)) {
            Image(systemName: DeviceText.icon(device))
                .font(.system(size: tvScaled(24)))
                .foregroundStyle(device.current ? Theme.red : .white)
                .frame(width: tvScaled(36))
                .padding(.top, tvScaled(2))
            VStack(alignment: .leading, spacing: tvScaled(3)) {
                HStack(spacing: tvScaled(8)) {
                    Text(device.name)
                        .font(.system(size: tvScaled(16), weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if device.current {
                        Text(L("This device"))
                            .font(.system(size: tvScaled(11), weight: .bold))
                            .foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, tvScaled(7))
                            .padding(.vertical, tvScaled(2))
                            .background(Theme.red, in: Capsule())
                            .fixedSize()
                    }
                }
                if !device.platform.isEmpty {
                    Text(DeviceText.platformLabel(device.platform))
                        .font(.system(size: tvScaled(13)))
                        .foregroundStyle(Theme.secondary)
                }
                if let linked = DeviceText.linked(device) {
                    Text(linked).font(.system(size: tvScaled(12))).foregroundStyle(Theme.secondary)
                }
                if let used = DeviceText.lastUsed(device) {
                    Text(used).font(.system(size: tvScaled(12))).foregroundStyle(Theme.secondary)
                }
                if let since = StreamText.signedInSince(device.signedInAt) {
                    Text(since).font(.system(size: tvScaled(12))).foregroundStyle(Theme.secondary)
                }
                HStack(spacing: tvScaled(10)) {
                    if busy {
                        ProgressView()
                    } else {
                        if let onRename {
                            Button(action: onRename) {
                                Text(L("Rename")).font(.system(size: tvScaled(14), weight: .semibold))
                                    .lineLimit(1).fixedSize()
                            }
                            .buttonStyle(.bordered)
                        }
                        Button(role: .destructive, action: onRemove) {
                            Text(L("Remove")).font(.system(size: tvScaled(14), weight: .semibold))
                                .lineLimit(1).fixedSize()
                        }
                        .buttonStyle(.bordered)
                        .tint(Theme.red)
                    }
                }
                .padding(.top, tvScaled(8))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, tvScaled(4))
    }
}

private extension View {
    /// Bevestiging "Remove %@? It will be signed out."
    func removeConfirmation(_ pending: Binding<AccountService.Device?>,
                            remove: @escaping (AccountService.Device) -> Void) -> some View {
        confirmationDialog(pending.wrappedValue.map { L("Remove %@? It will be signed out.", $0.name) } ?? "",
                           isPresented: Binding(get: { pending.wrappedValue != nil },
                                                set: { if !$0 { pending.wrappedValue = nil } }),
                           titleVisibility: .visible,
                           presenting: pending.wrappedValue) { d in
            Button(L("Remove"), role: .destructive) { remove(d) }
            Button(L("Cancel"), role: .cancel) {}
        }
    }
}

// MARK: - Rename

/// Venster "Rename": tekstveld met de huidige naam (max. 60 tekens), "Save" en "Cancel".
/// Op Apple TV opent het tekstveld het tv-toetsenbord; de focus start op het tekstveld.
struct DeviceRenameSheet: View {
    let current: String
    let onSave: (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focus: Field?
    private enum Field: Hashable { case name, save }

    private var clean: String { String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)) }
    private var canSave: Bool { !clean.isEmpty && !saving }

    var body: some View {
        content
            .onAppear {
                name = current
                focus = .name
            }
            .onChange(of: name) { _, v in if v.count > 60 { name = String(v.prefix(60)) } }
    }

    #if os(tvOS)
    private var content: some View {
        ZStack {
            AuthBackdrop()
            VStack(alignment: .leading, spacing: 28) {
                Text(L("Rename"))
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(.white)
                TextField(L("Device name"), text: $name)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .name)
                    .submitLabel(.done)
                    .onSubmit { focus = .save }
                    .frame(width: 900)
                if let error {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(AuthForm.errorColor)
                }
                HStack(spacing: 30) {
                    Button { save() } label: {
                        HStack(spacing: 12) {
                            Text(L("Save")).bold()
                            if saving { ProgressView() }
                        }
                        .frame(minWidth: 220)
                    }
                    .focused($focus, equals: .save)
                    .disabled(!canSave)
                    Button(L("Cancel")) { dismiss() }
                        .disabled(saving)
                }
            }
            .padding(60)
            .frame(maxWidth: 1100, alignment: .leading)
            .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 24))
        }
        .defaultFocus($focus, .name)
    }
    #else
    private var content: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L("Device name"), text: $name)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .name)
                        .submitLabel(.done)
                        .onSubmit { save() }
                } footer: {
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle.fill").foregroundStyle(AuthForm.errorColor)
                    }
                }
            }
            .navigationTitle(L("Rename"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel")) { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else { Button(L("Save")) { save() }.disabled(!canSave) }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 180)
        #endif
    }
    #endif

    private func save() {
        guard canSave else { return }
        saving = true
        error = nil
        let value = clean
        Task { @MainActor in
            defer { saving = false }
            do {
                try await onSave(value)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Mijn Bingr → Account → Devices

struct DevicesView: View {
    @EnvironmentObject var account: AccountService
    @State private var data: AccountService.DeviceLimit?
    @State private var loading = false
    @State private var error: String?
    @State private var pending: AccountService.Device?
    @State private var removing: String?
    @State private var renaming: AccountService.Device?

    var body: some View {
        List {
            Section {
                if let data {
                    ForEach(data.devices) { d in
                        DeviceRow(device: d, busy: removing == d.id, onRename: { renaming = d }) { pending = d }
                            .disabled(removing != nil)
                    }
                } else if loading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(AuthForm.errorColor)
                }
            } header: {
                if let data {
                    Text(L("%d of %d devices", data.devices.count, data.limit))
                }
            }
        }
        .navigationTitle(L("Devices"))
        .removeConfirmation($pending) { remove($0) }
        .sheet(item: $renaming) { d in
            DeviceRenameSheet(current: d.name) { name in try await rename(d, to: name) }
                .environmentObject(account)
        }
        .onAppear { Task { await load() } }
    }

    /// Opslaan; daarna de lijst opnieuw ophalen. Een fout gaat terug naar het venster.
    @MainActor private func rename(_ d: AccountService.Device, to name: String) async throws {
        try await account.renameDevice(d.id, name: name)
        if let cur = data {
            let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
            data = AccountService.DeviceLimit(limit: cur.limit, devices: cur.devices.map {
                $0.id == d.id ? AccountService.Device(id: $0.id, name: clean, platform: $0.platform, createdAt: $0.createdAt,
                                                      lastSeenAt: $0.lastSeenAt, current: $0.current, signedInAt: $0.signedInAt) : $0
            })
        }
        await load()
    }

    @MainActor private func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            data = try await account.listDevices()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func remove(_ d: AccountService.Device) {
        removing = d.id
        error = nil
        Task { @MainActor in
            defer { removing = nil }
            do {
                // het eigen apparaat verwijderen = uitloggen (de app gaat terug naar het inlogscherm)
                try await account.removeDevice(d.id)
                guard account.isSignedIn else { return }
                if let cur = data {
                    data = AccountService.DeviceLimit(limit: cur.limit, devices: cur.devices.filter { $0.id != d.id })
                }
                await load()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - "Too many devices" (na inloggen of bij het starten)

struct TooManyDevicesView: View {
    @EnvironmentObject var account: AccountService
    /// Het apparaat is alsnog geregistreerd: door naar "Wie kijkt er?".
    var onResolved: () -> Void = {}
    @State private var pending: AccountService.Device?
    @State private var removing: String?
    @State private var error: String?

    var body: some View {
        ZStack {
            AuthBackdrop()
            ScrollView {
                VStack(spacing: tvScaled(24)) {
                    BingrLogo(size: tvScaled(34)).padding(.top, tvScaled(24))
                    card
                }
                .padding(.horizontal, Theme.edge)
                .padding(.bottom, tvScaled(32))
                .frame(maxWidth: .infinity)
            }
        }
        .removeConfirmation($pending) { remove($0) }
    }

    private var card: some View {
        let limit = account.deviceLimit
        return VStack(alignment: .leading, spacing: tvScaled(16)) {
            Text(L("Too many devices"))
                .font(.system(size: tvScaled(28), weight: .bold))
                .foregroundStyle(.white)
            Text(L("Your account can be used on up to %d devices. Remove a device to sign in on this one.", limit?.limit ?? AccountService.fallbackDeviceLimit))
                .font(.system(size: tvScaled(15)))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // build 88: op Gratis de limiet van Lifetime en de vergelijking (build 97: nooit een aankooplink op Apple)
            PlanLimitNote(topic: .devices, plan: limit?.plan)

            VStack(spacing: 0) {
                ForEach(limit?.devices ?? []) { d in
                    DeviceRow(device: d, busy: removing == d.id) { pending = d }
                        .disabled(removing != nil)
                        .padding(.vertical, tvScaled(6))
                    if d.id != limit?.devices.last?.id {
                        Divider().overlay(Color.white.opacity(0.12))
                    }
                }
            }

            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: tvScaled(13), weight: .medium))
                    .foregroundStyle(AuthForm.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Task { await account.signOut() }
            } label: {
                Text(L("Cancel"))
                    .font(.system(size: tvScaled(16), weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, tvScaled(12))
                    .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: tvScaled(6)))
                    .contentShape(Rectangle())
            }
            .cardButton()
            .disabled(removing != nil || account.isBusy)
            .padding(.top, tvScaled(6))
        }
        .padding(tvScaled(30))
        .frame(maxWidth: tvScaled(560))
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: tvScaled(12)))
        .overlay(RoundedRectangle(cornerRadius: tvScaled(12)).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private func remove(_ d: AccountService.Device) {
        removing = d.id
        error = nil
        Task { @MainActor in
            defer { removing = nil }
            do {
                // verwijderen en meteen opnieuw `register_device`; lukt dat, dan verder
                if try await account.removeDeviceAndRetry(d.id) == .ok { onResolved() }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
