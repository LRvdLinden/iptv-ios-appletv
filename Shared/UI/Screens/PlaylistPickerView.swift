import SwiftUI
import PhotosUI

/// "Wie kijkt er?" — kijkprofielen van het hoofdaccount. Alle profielen gebruiken dezelfde server.
struct PlaylistPickerView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: CloudStore
    @State private var managing = false
    @State private var editing: ViewerProfile?
    @State private var addingProfile = false
    @State private var addingServer = false
    @State private var appeared = false
    @State private var pinFor: ViewerProfile?
    @FocusState private var focus: FocusTarget?

    enum FocusTarget: Hashable { case profile(UUID), add, manage, server }

    private var columns: [GridItem] {
        #if os(tvOS)
        [GridItem(.adaptive(minimum: 220, maximum: 260), spacing: 60)]
        #else
        [GridItem(.adaptive(minimum: 110, maximum: 140), spacing: 22)]
        #endif
    }

    private var noServer: Bool { store.playlists.isEmpty }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: tvScaled(26)) {
                HStack {
                    BingrLogo(size: tvScaled(26))
                    Spacer()
                    // profielen beheren gebeurt in het hoofdaccount (Mijn Bingr → Profielen)
                }
                .padding(.horizontal, Theme.edge).padding(.top, tvScaled(8))
                #if os(tvOS)
                .focusSection()
                #endif

                Spacer(minLength: 0)

                if noServer {
                    welcome
                } else {
                    Text(L("Who's watching?"))
                        .font(.system(size: tvScaled(26), weight: .medium))
                        .foregroundStyle(.white)

                    LazyVGrid(columns: columns, spacing: tvScaled(26)) {
                        ForEach(Array(store.profiles.enumerated()), id: \.element.id) { i, p in
                            Button {
                                // profiel met pincode: eerst de pincode vragen
                                if ParentalControl.shared.hasPIN(profile: p.id) { pinFor = p } else { app.open(profile: p) }
                            } label: {
                                AvatarTile(name: p.name, avatar: p.avatar, photo: store.photos[p.id],
                                           badge: store.isMain(p) && store.profiles.count > 1 ? "person.fill" : nil,
                                           locked: ParentalControl.shared.hasPIN(profile: p.id))
                            }
                            .profileButton()
                            .focused($focus, equals: .profile(p.id))
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 24)
                            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(Double(i) * 0.06), value: appeared)
                        }
                    }
                    .padding(.horizontal, Theme.edge)
                    .frame(maxWidth: tvScaled(store.profiles.count > 3 ? 900 : 620))
                    #if os(tvOS)
                    .focusSection()
                    #endif
                }

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    Image(systemName: "icloud")
                    Text(store.lastSync.map { L("iCloud synced · %@", $0.formatted(date: .omitted, time: .shortened)) } ?? L("iCloud sync"))
                }
                .font(.system(size: tvScaled(11))).foregroundStyle(Theme.secondary.opacity(0.7))
                .padding(.bottom, tvScaled(10))
            }
        }
        .onAppear {
            appeared = true   // gegevens zijn al geladen; iCloud-wijzigingen komen vanzelf binnen
            // Apple TV: meteen op het (laatst gebruikte) profiel staan, niet op Beheren
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                if let id = store.activeProfileID ?? store.profiles.first?.id, store.profiles.contains(where: { $0.id == id }) {
                    focus = .profile(id)
                } else if noServer { focus = .server } else { focus = .add }
            }
        }
        .sheet(isPresented: $addingServer) { AddPlaylistView(existing: nil) }
        .sheet(isPresented: $addingProfile) { ProfileEditView(existing: nil) }
        .sheet(item: $editing) { p in ProfileEditView(existing: p) }
        .sheet(item: $pinFor) { p in
            PINPad(title: L("PIN for %@", p.name)) { pin in
                guard ParentalControl.shared.verify(pin, profile: p.id) else { return false }
                Task { @MainActor in try? await Task.sleep(nanoseconds: 300_000_000); app.open(profile: p) }
                return true
            }
        }
    }

    /// Nog geen server: eerst het hoofdaccount instellen.
    private var welcome: some View {
        VStack(spacing: tvScaled(18)) {
            Text(L("Welcome to Bingr")).font(.system(size: tvScaled(26), weight: .medium)).foregroundStyle(.white)
            Text(L("Set up your server once (M3U, Xtream Codes, a MAC portal, Plex, Jellyfin, Emby or Stremio). After that, everyone gets their own profile on that server."))
                .font(.system(size: tvScaled(14))).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                .padding(.horizontal, Theme.edge)
            NetflixButton(title: L("Set up server"), icon: "server.rack", kind: .accent) { addingServer = true }
                .focused($focus, equals: .server)
        }
    }
}

/// Kijkprofiel toevoegen/bewerken: naam, icoon of foto, leeftijdsgrens.
struct ProfileEditView: View {
    let existing: ViewerProfile?
    @EnvironmentObject var store: CloudStore
    @EnvironmentObject var parental: ParentalControl
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var avatar = PlaylistAvatar.random()
    @State private var photo: Data?
    @State private var ageLimit = 0
    @State private var confirmDelete = false
    @State private var askPIN = false
    #if os(iOS)
    @State private var photoItem: PhotosPickerItem?
    #endif

    private var locked: Bool { store.parental.enabled && !parental.isUnlocked }
    /// Leeftijdsgrens en verwijderen: alleen vanuit het hoofdaccount
    private var canAdmin: Bool { store.isMainActive || store.activeProfileID == nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack { Spacer(); AvatarTile(name: "", avatar: avatar, photo: photo).frame(width: tvScaled(110)); Spacer() }
                        .listRowBackground(Color.clear)
                    TextField(L("Name"), text: $name)
                }
                Section(L("Identify with an icon")) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: tvScaled(10)) {
                            ForEach(PlaylistAvatar.symbols, id: \.self) { s in
                                Button { avatar.symbol = s; photo = nil } label: {
                                    Image(systemName: s).font(.system(size: tvScaled(20), weight: .semibold))
                                        .frame(width: tvScaled(44), height: tvScaled(44)).foregroundStyle(.white)
                                        .background(avatar.symbol == s ? AnyShapeStyle(avatar.gradient) : AnyShapeStyle(Theme.elevated), in: Circle())
                                }
                                .plainTVButton()
                            }
                        }.padding(.vertical, 4)
                    }
                    HStack(spacing: tvScaled(12)) {
                        ForEach(0..<PlaylistAvatar.palettes.count, id: \.self) { i in
                            Button { avatar.colorIndex = i } label: {
                                Circle().fill(PlaylistAvatar(symbol: "", colorIndex: i).gradient)
                                    .frame(width: tvScaled(28), height: tvScaled(28))
                                    .overlay(Circle().stroke(.white, lineWidth: avatar.colorIndex == i ? 3 : 0))
                            }
                            .plainTVButton()
                        }
                    }
                }
                #if os(iOS)
                Section(L("Profile photo")) {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label(photo == nil ? L("Choose from Photos") : L("Change photo"), systemImage: "photo.on.rectangle")
                    }
                    if photo != nil { Button(L("Remove photo"), role: .destructive) { photo = nil } }
                }
                .onChange(of: photoItem) { _, item in
                    guard let item else { return }
                    Task { if let d = try? await item.loadTransferable(type: Data.self) { photo = AddPlaylistView.thumbnail(d) } }
                }
                #endif
                if canAdmin { Section {
                    Picker(L("Age limit for this profile"), selection: $ageLimit) {
                        Text(L("None")).tag(0)
                        ForEach(ParentalControl.ageChoices, id: \.self) { Text(L("Up to %d years", $0)).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .disabled(locked)
                    if locked { Button(L("Unlock with PIN")) { askPIN = true } }
                } footer: {
                    Text(store.parental.enabled
                         ? L("Titles above this age (IMDb rating) and adult groups are hidden on this profile. With the PIN you can still watch them.")
                         : L("Set a PIN on the main account and turn on “Lock adult content with this PIN” (My Bingr → PIN code) to protect the age limit."))
                } }
                if canAdmin, let existing, !store.isMain(existing) {
                    Section { Button(L("Delete profile"), role: .destructive) { confirmDelete = true } }
                    .confirmationDialog(L("Delete profile"), isPresented: $confirmDelete) {
                        Button(L("Delete"), role: .destructive) { store.deleteProfile(existing); dismiss() }
                    }
                }
            }
            .navigationTitle(existing == nil ? L("Add profile") : L("Edit profile"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Save")) { save() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let e = existing { name = e.name; avatar = e.avatar; ageLimit = e.ageLimit ?? 0; photo = store.photos[e.id] }
            }
            .sheet(isPresented: $askPIN) {
                PINPad(title: L("Enter PIN")) { pin in store.mainProfileID.map { parental.verify(pin, profile: $0) } ?? parental.verify(pin) }
            }
        }
    }

    private func save() {
        var p = existing ?? ViewerProfile(name: name, avatar: avatar)
        p.name = name.trimmingCharacters(in: .whitespaces)
        p.avatar = avatar
        p.ageLimit = ageLimit == 0 ? nil : ageLimit
        store.upsertProfile(p)
        if photo != store.photos[p.id] { store.setPhoto(photo, for: p.id) }
        dismiss()
    }
}

struct AvatarTile: View {
    let name: String
    let avatar: PlaylistAvatar
    var photo: Data? = nil
    var editing = false
    /// klein rond symbooltje rechtsonder (poppetje = hoofdaccount)
    var badge: String? = nil
    /// slotje onder de naam als het profiel een pincode heeft
    var locked = false
    @Environment(\.profileFocused) private var focused
    var body: some View {
        VStack(spacing: tvScaled(10)) {
            Circle().fill(avatar.gradient)
                .overlay {
                    if let photo, let img = UIImage(data: photo) {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else {
                        Image(systemName: avatar.symbol)
                            .font(.system(size: tvScaled(44), weight: .semibold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                    }
                }
                .overlay {
                    if editing {
                        Color.black.opacity(0.55)
                        Image(systemName: "pencil").font(.system(size: tvScaled(30), weight: .bold)).foregroundStyle(.white)
                    }
                }
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.white, lineWidth: focused ? tvScaled(3) : 0))
                .overlay(alignment: .bottomTrailing) {
                    if let badge {
                        Image(systemName: badge).font(.system(size: tvScaled(12), weight: .bold)).foregroundStyle(.white)
                            .frame(width: tvScaled(26), height: tvScaled(26))
                            .background(Theme.red, in: Circle())
                            .overlay(Circle().strokeBorder(.black, lineWidth: tvScaled(2)))
                    }
                }
                .aspectRatio(1, contentMode: .fit)
            if !name.isEmpty {
                HStack(spacing: 4) {
                    Text(name).font(.system(size: tvScaled(14), weight: focused ? .semibold : .regular)).lineLimit(1)
                    if locked { Image(systemName: "lock.fill").font(.system(size: tvScaled(10))) }
                }
                .foregroundStyle(focused ? .white : Theme.secondary)
            }
        }
    }
}

/// Avatar van het actieve kijkprofiel (kopbalk, laadscherm, Mijn Bingr).
struct ProfileAvatar: View {
    let size: CGFloat
    @EnvironmentObject var store: CloudStore
    var body: some View {
        if let p = store.activeProfile {
            ZStack {
                Circle().fill(p.avatar.gradient)
                if let d = store.photos[p.id], let img = UIImage(data: d) {
                    Color.clear.overlay(Image(uiImage: img).resizable().scaledToFill()).clipShape(Circle())
                } else {
                    Image(systemName: p.avatar.symbol).font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(.white)
                }
            }
            .frame(width: size, height: size)
        } else {
            Circle().fill(Theme.elevated).frame(width: size, height: size)
        }
    }
}

/// Klein avatartje (foto of icoon) voor lijsten en kopbalken.
struct MiniAvatar: View {
    let playlist: PlaylistSource
    let size: CGFloat
    @EnvironmentObject var store: CloudStore
    var body: some View {
        ZStack {
            Circle().fill(playlist.avatar.gradient)
            if let d = store.photos[playlist.id], let img = UIImage(data: d) {
                Color.clear.overlay(Image(uiImage: img).resizable().scaledToFill())
                    .clipShape(Circle())
            } else {
                Image(systemName: playlist.avatar.symbol).font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }
}

private struct AddTile: View {
    @Environment(\.profileFocused) private var focused
    var body: some View {
        VStack(spacing: tvScaled(10)) {
            ZStack {
                Circle().fill(focused ? Color.white.opacity(0.12) : .clear)
                Circle().strokeBorder(focused ? .white : Theme.secondary.opacity(0.5), lineWidth: focused ? tvScaled(3) : 2)
                Image(systemName: "plus").font(.system(size: tvScaled(40), weight: .regular))
                    .foregroundStyle(focused ? .white : Theme.secondary)
            }
            .aspectRatio(1, contentMode: .fit)
            Text(L("Add")).font(.system(size: tvScaled(14), weight: focused ? .semibold : .regular))
                .foregroundStyle(focused ? .white : Theme.secondary)
        }
    }
}

// MARK: profielknop (zoals Netflix: alleen de avatar, bij focus iets groter)

private struct ProfileFocusedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var profileFocused: Bool {
        get { self[ProfileFocusedKey.self] }
        set { self[ProfileFocusedKey.self] = newValue }
    }
}

/// Geen grijze kaart erachter: op tvOS wordt de avatar bij selectie iets groter met een witte rand.
struct ProfileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { ProfileButtonBody(configuration: configuration) }

    private struct ProfileButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var focused
        var body: some View {
            configuration.label
                .environment(\.profileFocused, focused)
                .scaleEffect(configuration.isPressed ? 1.04 : (focused ? 1.12 : 1))
                .shadow(color: .black.opacity(focused ? 0.6 : 0), radius: 18, y: 10)
                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: focused)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

extension View {
    @ViewBuilder func profileButton() -> some View {
        #if os(tvOS)
        self.buttonStyle(ProfileButtonStyle())
        #else
        self.buttonStyle(PressableStyle())
        #endif
    }
}
