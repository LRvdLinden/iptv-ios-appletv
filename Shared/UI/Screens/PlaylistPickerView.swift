import SwiftUI

/// "Wie kijkt er?" — maar dan voor afspeellijsten. Gesynchroniseerd via iCloud.
struct PlaylistPickerView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: CloudStore
    @State private var managing = false
    @State private var editing: PlaylistSource?
    @State private var adding = false
    @State private var appeared = false

    private var columns: [GridItem] {
        #if os(tvOS)
        [GridItem(.adaptive(minimum: 220, maximum: 260), spacing: 60)]
        #else
        [GridItem(.adaptive(minimum: 110, maximum: 140), spacing: 22)]
        #endif
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: tvScaled(26)) {
                HStack {
                    BingrLogo(size: tvScaled(26))
                    Spacer()
                    if !store.playlists.isEmpty {
                        Button(managing ? L("Done") : L("Manage")) {
                            withAnimation(.spring(response: 0.35)) { managing.toggle() }
                        }
                        .font(.system(size: tvScaled(15), weight: .semibold))
                        .foregroundStyle(.white)
                        .plainTVButton()
                    }
                }
                .padding(.horizontal, Theme.edge).padding(.top, tvScaled(8))

                Spacer(minLength: 0)

                Text(store.playlists.isEmpty ? L("Welcome to Bingr") : (managing ? L("Manage playlists") : L("What do you want to watch?")))
                    .font(.system(size: tvScaled(26), weight: .medium))
                    .foregroundStyle(.white)
                if store.playlists.isEmpty {
                    Text(L("Add your first playlist: M3U, Xtream Codes, a MAC portal, Plex, Jellyfin, Emby or Stremio.\nYour playlists are shared via iCloud with your Apple TV, iPhone, iPad and Mac."))
                        .font(.system(size: tvScaled(14)))
                        .foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                        .padding(.horizontal, Theme.edge)
                }

                LazyVGrid(columns: columns, spacing: tvScaled(26)) {
                    ForEach(Array(store.playlists.enumerated()), id: \.element.id) { i, p in
                        Button {
                            if managing { editing = p } else { app.open(p) }
                        } label: {
                            AvatarTile(name: p.name, avatar: p.avatar, photo: store.photos[p.id], editing: managing)
                        }
                        .profileButton()
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 24)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(Double(i) * 0.06), value: appeared)
                    }
                    Button { adding = true } label: { AddTile() }
                        .profileButton()
                        .opacity(appeared ? 1 : 0)
                        .animation(.easeOut(duration: 0.4).delay(Double(store.playlists.count) * 0.06), value: appeared)
                }
                .padding(.horizontal, Theme.edge)
                .frame(maxWidth: tvScaled(620))

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    Image(systemName: "icloud")
                    Text(store.lastSync.map { L("iCloud synced · %@", $0.formatted(date: .omitted, time: .shortened)) } ?? L("iCloud sync"))
                }
                .font(.system(size: tvScaled(11))).foregroundStyle(Theme.secondary.opacity(0.7))
                .padding(.bottom, tvScaled(10))
            }
        }
        .onAppear { appeared = true; store.load(mergeProgress: true) }
        .sheet(isPresented: $adding) { AddPlaylistView(existing: nil) }
        .sheet(item: $editing) { p in AddPlaylistView(existing: p) }
    }
}

struct AvatarTile: View {
    let name: String
    let avatar: PlaylistAvatar
    var photo: Data? = nil
    var editing = false
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
                .aspectRatio(1, contentMode: .fit)
            if !name.isEmpty {
                Text(name).font(.system(size: tvScaled(14), weight: focused ? .semibold : .regular))
                    .foregroundStyle(focused ? .white : Theme.secondary).lineLimit(1)
            }
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
