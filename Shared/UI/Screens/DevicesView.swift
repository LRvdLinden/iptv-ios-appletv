import SwiftUI

/// Gekoppelde apparaten (max. 10), zie "Gekoppelde apparaten" in docs/ACCOUNT.md.

// MARK: - Weergave

enum DeviceText {
    /// SF Symbol per platform.
    static func icon(_ d: AccountService.Device) -> String {
        switch d.platform {
        case "iPhone": return "iphone"
        case "iPad": return "ipad"
        case "Apple TV": return "appletv"
        case "Mac": return d.name.localizedCaseInsensitiveContains("macbook") ? "macbook" : "desktopcomputer"
        case "Android": return "candybarphone"
        case "Android tablet": return "ipad.landscape"
        case "Android TV", "Fire TV": return "tv"
        default: return "display"
        }
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

/// Eén apparaat: icoon, naam, platform, gekoppeld, laatst gebruikt, "This device" en een knop "Remove".
struct DeviceRow: View {
    let device: AccountService.Device
    let busy: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: tvScaled(14)) {
            Image(systemName: DeviceText.icon(device))
                .font(.system(size: tvScaled(24)))
                .foregroundStyle(device.current ? Theme.red : .white)
                .frame(width: tvScaled(36))
            VStack(alignment: .leading, spacing: tvScaled(3)) {
                HStack(spacing: tvScaled(8)) {
                    Text(device.name)
                        .font(.system(size: tvScaled(16), weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if device.current {
                        Text(L("This device"))
                            .font(.system(size: tvScaled(11), weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, tvScaled(7))
                            .padding(.vertical, tvScaled(2))
                            .background(Theme.red, in: Capsule())
                            .fixedSize()
                    }
                }
                if !device.platform.isEmpty {
                    Text(device.platform)
                        .font(.system(size: tvScaled(13)))
                        .foregroundStyle(Theme.secondary)
                }
                if let linked = DeviceText.linked(device) {
                    Text(linked).font(.system(size: tvScaled(12))).foregroundStyle(Theme.secondary)
                }
                if let used = DeviceText.lastUsed(device) {
                    Text(used).font(.system(size: tvScaled(12))).foregroundStyle(Theme.secondary)
                }
            }
            Spacer(minLength: tvScaled(8))
            if busy {
                ProgressView()
            } else {
                Button(role: .destructive, action: onRemove) {
                    Text(L("Remove")).font(.system(size: tvScaled(14), weight: .semibold))
                }
                .buttonStyle(.bordered)
                .tint(Theme.red)
            }
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

// MARK: - Mijn Bingr → Account → Devices

struct DevicesView: View {
    @EnvironmentObject var account: AccountService
    @State private var data: AccountService.DeviceLimit?
    @State private var loading = false
    @State private var error: String?
    @State private var pending: AccountService.Device?
    @State private var removing: String?

    var body: some View {
        List {
            Section {
                if let data {
                    ForEach(data.devices) { d in
                        DeviceRow(device: d, busy: removing == d.id) { pending = d }
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
        .onAppear { Task { await load() } }
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
            Text(L("Your account can be used on up to %d devices. Remove a device to sign in on this one.", limit?.limit ?? 10))
                .font(.system(size: tvScaled(15)))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)

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
