# Bingr Android — interne afspraken (API-contract)

Native Android-versie van Bingr (zelfde functies als de iOS/tvOS-app in `../Shared`), voor telefoon/tablet **en** Android TV / Google TV / Fire TV in één APK.

## Regels voor alle code

- Kotlin, Jetpack Compose (Material3), minSdk 24, compileSdk 35. **Alle Kotlin-bestanden in package `nl.lrvdlinden.bingr`** (mappen zijn alleen ordening), dus geen imports tussen eigen bestanden nodig.
- Alleen de dependencies uit `app/build.gradle.kts` (Compose, Media3 1.5.1, libvlc-all 3.5.1, OkHttp 4.12, kotlinx-serialization-json 1.7.3, coroutines 1.9, Coil 2.7 (`coil.compose.AsyncImage`), Cast framework 21.5, mediarouter 1.7). Geen andere toevoegen.
- Teksten altijd via `L("English text")` / `L("Format %d", n)` — sleutels zijn **exact dezelfde Engelse teksten als in de Swift-code** (`L("...")` daar), zodat `Shared/Resources/Translations.json` werkt. iOS `%@` wordt automatisch `%s`. Gebruik zo veel mogelijk bestaande sleutels; nieuwe Engelse teksten worden later vertaald (lijst ze in je eindrapport).
- State voor de UI: Compose-state in singletons (`var x by mutableStateOf(...)`), zoals `Store` en `AppState`. Netwerk/IO in `suspend`-functies (OkHttp via `Http`, op Dispatchers.IO). Nooit blokkeren op de main thread. Langlopend app-werk: `AppScope.launch { }`.
- Tijden = epoch-ms (`Long`), URL's = `String`.
- TV: `AppState.isTV`. Alles moet met de afstandsbediening (D-pad) bedienbaar zijn: gebruik `Modifier.focusLift { }` voor alles wat klikbaar is (geeft focus-vergroting zonder grijze vlakken). Op TV iets grotere maten via `tvs(n)` (Dp) en `tsp(n)` (sp). Terugknop = systeem-back (`BackHandler`).
- Netflix-look: zwart (`Theme.bg`), rood `Theme.red`, `Theme.secondary`, `Theme.card`, `Theme.elevated`, `Theme.imdb`.

## Al aanwezig (core/ en ui/) — gebruiken, niet opnieuw maken

- `Models.kt`: `PlaylistKind`, `PlaylistAvatar`, `PlaylistSource`, `MediaType`, `Channel`, `Movie`, `Series`, `Episode`, `EPGProgram`, `Library`, `PlayableItem`, `DetailTarget` (`MovieT`/`SeriesT`), `TitleMetadata`, `ProgressEntry`, `Customization`, `ParentalSettings`, `ProgramReminder`, `HistoryEntry`, `NASServer`.
- `Store` (gebruikersgegevens, zie Store.kt): playlists, favorites, myList, progress, localWatched, recentChannels, customizations, parental, reminders, history, nasServers, foto's, `secret()/setSecret()`, `exportJSON()/importJSON()`, `activePlaylistID`.
- `Prefs` (instellingen), `Localizer`/`L()`, `Http` (`request/get/bytes/json/decode/enc`, `HttpException`), `Secrets` (API-sleutels; `traktReady`, `openSubtitlesReady`, `isSet`).
- `AppState`: `stage` (SPLASH/PICKER/MAIN), `playing`, `liveZapList`, `showMultiview`, `multiviewStart`, `pendingItemID`, `inPiP`, `isTV`, `open(p)`, `switchPlaylist()`, `play(item, zap)`, `openMultiview(...)`, `splashFinished()`. `AppScope`.
- `MainActivity` (`MainActivity.current?.enterPiP()`, `keepScreenOn(on)`), `BingrApplication`.
- UI-bouwstenen (ui/Theme.kt, ui/Cards.kt): `BingrTheme`, `Theme`, `tvs`, `tsp`, `Modifier.focusLift(scale, dimWhenIdle, onLongClick, onClick)`, `NetflixButton(title, icon, kind, modifier, onClick)`, `RemoteImage(url, modifier, placeholder, fit)`, `AvatarCircle(playlist, size, ring, editing)`, `BingrLogo(size)`, `ProgressBar(value)`, `PosterCard(title, poster, modifier, width, watched, progress, badge, rating)`, `Top10Card(rank, title, poster, watched, badge)`, `MediaRow(title, onSeeAll) { items(...) }`, `ChannelCard(channel, now, favorite)`, `SectionHeader(text)`.

## Te bouwen — deel A: diensten (providers/, meta/, trakt/, subs/, parental/)

```kotlin
object Playlists {                       // = PlaylistService (iOS)
  var source: PlaylistSource?            // state
  var library: Library                   // na aanpassingen/kinderslot/leeftijdsfilter
  var rawLibrary: Library
  var isLoading: Boolean; var loadingText: String; var error: String?
  var refreshingAll: Boolean
  suspend fun select(p: PlaylistSource, forceRefresh: Boolean = false)   // laadt cache direct, ververst volgens RefreshPolicy; zet Store.activePlaylistID
  fun applyCustomizations()
  suspend fun resolve(item: PlayableItem): String?                        // Stalker create_link, Stremio, anders item.url
  fun catchupURL(channelID: String, start: Long, end: Long): String?
  suspend fun shortEPG(c: Channel): List<EPGProgram>
  suspend fun episodes(s: Series): List<Episode>                          // Xtream get_series_info / Plex / Jellyfin / Emby / Stremio / M3U (s.episodes)
  suspend fun search(q: String): SearchResults
  suspend fun otherSources(title: String, year: Int?, isShow: Boolean, excludingID: String): List<OtherHit>
  suspend fun stremioStreams(item: PlayableItem): List<StremioStream>
  suspend fun refreshAll(); suspend fun refreshIfDue()
  fun readCache(p: PlaylistSource): Library?
  fun splashPosters(): List<String>      // poster-URL's van films/series voor de splash (opgeslagen bij laden)
  suspend fun test(p: PlaylistSource, password: String): String?          // null = ok, anders foutmelding (voor "Toevoegen")
  // Plex-koppelen met code (plex.tv/link) en Stremio-login, zoals AddPlaylistView.swift
}
enum class RefreshPolicy { MANUAL, LAUNCH, SIX_HOURS, DAILY, WEEKLY; val title: String }   // Prefs "playlist.refresh"
data class SearchResults(val channels: List<Channel> = emptyList(), val movies: List<Movie> = emptyList(), val series: List<Series> = emptyList(), val other: List<OtherHit> = emptyList()) { val isEmpty: Boolean }
data class OtherHit(val playlist: PlaylistSource, val itemID: String, val title: String, val subtitle: String, val artwork: String?)
data class StremioStream(val title: String, val addon: String, val url: String)

object ParentalControl { var unlockedUntil: Long?; val hasPIN: Boolean; val isUnlocked: Boolean; fun setPIN(pin: String?); fun verify(pin: String): Boolean; fun lock()
  fun isLocked(playlist: String, group: String): Boolean; fun toggleLock(playlist: String, group: String)
  fun allowed(rated: String?, group: String, limit: Int?): Boolean; companion-achtig: val ageChoices = listOf(6,9,12,16); fun minimumAge(rated: String?): Int?; fun isAdultGroup(g: String): Boolean }

object Reminders { fun createChannel(ctx: Context); fun add(channel: Channel, program: EPGProgram, playlistID: String); fun remove(id: String) }  // AlarmManager + notificatie
class ReminderReceiver : BroadcastReceiver   // toont notificatie "Begint nu: <titel> op <zender>"; tik opent app

object TitleCleaner { data class Parsed(title, year, season, episode); fun parse(raw: String): Parsed }
object Metadata {        // OMDb (IMDb-gegevens) met cache (= MetadataService)
  var version: Int       // state, verhoogt bij nieuwe cache-items
  fun cached(m: Movie): TitleMetadata?; fun cached(s: Series): TitleMetadata?
  suspend fun metadata(m: Movie, knownIMDb: String? = null): TitleMetadata?; suspend fun metadata(s: Series): TitleMetadata?
}
data class TitleDetails(...)   // zoals DetailsService.swift: title, year, runtime, overview, genres, certification, poster, backdrop, logo, trailerYouTubeID, imdbID, ratings(List<Rating(source,value)>), cast(List<CastMember(name, role, photo)>), director, recommendations(List<Recommendation(title, year, poster, imdbID, isShow)>), episodeInfo(Map<"s-e", EpisodeInfo(title, overview, still, airDate, runtime)>), seasonCount, tmdbID
object Details { suspend fun load(t: DetailTarget): TitleDetails; suspend fun season(tmdbTvID: Int, season: Int): Map<String, TitleDetails.EpisodeInfo> }
object TMDB { suspend fun trending(shows: Boolean): List<ExternalTitle> }
data class ExternalTitle(val titles: List<String>, val year: Int?)
class TitleMatcher(movies, series) { fun movies(list: List<ExternalTitle>, limit: Int = 10): List<Movie>; fun series(...): List<Series> }
object MatcherCache { suspend fun matcher(lib: Library, key: String): TitleMatcher }   // bouwen op Dispatchers.Default
object TrendingStore { suspend fun get(shows: Boolean): List<ExternalTitle>; fun cached(shows: Boolean): List<ExternalTitle> }   // TMDB + Trakt, 6 uur cache

object Trakt {           // = TraktClient + TraktSync; nieuwe apps: alleen Client ID (PKCE), client_secret alleen meesturen als gezet; oauth-host api.trakt.tv met terugval auth.trakt.tv
  var isLoggedIn: Boolean; var username: String?; var displayName: String?; var avatar: String?
  var watchedMovies: Set<String>; var watchedEpisodes: Map<String, Set<String>>; var watchlist: Set<String>
  var lastRefresh: Long?; var lastError: String?
  var scrobbleEnabled: Boolean; var askRating: Boolean       // Prefs "trakt.scrobble"/"trakt.askRating"
  data class DeviceCode(val deviceCode: String, val userCode: String, val verificationUrl: String, val expiresIn: Int, val interval: Int)
  suspend fun startLogin(): DeviceCode; suspend fun finishLogin(c: DeviceCode); fun logout(); suspend fun refresh(force: Boolean = false)
  fun imdb(m: Movie): String?; fun imdb(s: Series): String?
  fun isWatched(movieImdb: String?): Boolean; fun watchedCount(showImdb: String?): Int; fun isWatched(showImdb: String?, season: Int, episode: Int): Boolean
  enum class Scrobble { START, PAUSE, STOP }; suspend fun scrobble(a: Scrobble, item: PlayableItem, progress: Double)
  suspend fun setWatched(item: PlayableItem, watched: Boolean); suspend fun toggleWatchlist(imdb: String, isShow: Boolean)
  suspend fun trending(shows: Boolean): List<ExternalTitle>; suspend fun recommendations(shows: Boolean): List<ExternalTitle>; suspend fun related(imdb: String, shows: Boolean): List<ExternalTitle>
  suspend fun rate(item: PlayableItem, rating: Int); fun playbackProgress(movieImdb: String?): Double?
  suspend fun trailer(imdb: String, isShow: Boolean): String?   // YouTube-id
}

object OpenSubtitles {
  var username: String?; var remainingDownloads: Int?; val isLoggedIn: Boolean
  var defaultLanguage: String            // ISO 639-1, "" = alle talen (Prefs "os.language")
  data class Subtitle(val id: Int, val language: String, val release: String, val downloads: Int, val hearingImpaired: Boolean, val fromTrusted: Boolean)
  suspend fun login(user: String, pass: String); suspend fun logout(); suspend fun refreshUser()
  suspend fun search(imdbID: String?, title: String?, year: Int?, season: Int?, episode: Int?, languages: List<String>): List<Subtitle>
  suspend fun download(s: Subtitle): java.io.File     // .srt in cacheDir
}
```

## Te bouwen — deel B: speler (player/)

```kotlin
object TrackPreferences { var audio: String; var subtitle: String /* ""=stream, "off" */; val languages; fun name(code): String; fun flag(code): String /* emoji-vlag */; fun label(code) = "$flag $name"; val sortedCodes; fun matches(t: MediaTrack, code: String): Boolean }
data class MediaTrack(val id: String, val name: String, val lang: String? = null)
class PlayerController(item: PlayableItem) {    // Media3 ExoPlayer voor HLS/MP4/TS/DASH, LibVLC voor de rest (smb://, mkv met DTS, rtmp, …), automatisch wisselen bij fouten, herverbinden
  companion object { var current: PlayerController? }
  val isPlaying: Boolean; fun stop()
  ... (vrij in te vullen; tegenhanger van PlayerController.swift + Engines.swift)
}
@Composable fun PlayerScreen(item: PlayableItem, onClose: () -> Unit)   // volledige speler met bediening (tik/D-pad), timeline, ±10 s, zappen ↑↓ bij live, timeshift/catch-up, audio & ondertitels (vlaggen), OpenSubtitles-paneel (taal kiezen, inloggen, downloaden), ondertitel-vertraging, snelheid, beeldverhouding, slaaptimer, Chromecast-knop (telefoon), beeld-in-beeld-knop (telefoon), multiview-knop bij live, Trakt-scrobble, voortgang + kijkgeschiedenis opslaan (Store), standaard audio-/ondertiteltaal toepassen, automatisch OpenSubtitles laden (Prefs "autoSubtitles"), na afloop beoordelen (Trakt) — alles zoals PlayerScreen.swift/PlayerPanels.swift/PlayerController.swift
@Composable fun MultiviewScreen(onClose: () -> Unit)   // 2×2 zenders, geluid van geselecteerde tegel (AppState.multiviewStart / liveZapList)
class CastOptionsProvider : com.google.android.gms.cast.framework.OptionsProvider   // standaard media receiver (CC1AD845)
object Casting { fun isAvailable(ctx): Boolean; fun cast(item: PlayableItem, url: String, positionMs: Long) }
object SRT { fun decode(bytes): String; fun parse(text): List<SubtitleCue> }   // UTF-8/UTF-16/Windows-1252, X1:-posities, {\an8}
```

## Te bouwen — deel C: schermen (ui/screens/)

`@Composable fun BingrRoot()` — splash → profielkeuze → hoofdscherm; spelerscherm (`AppState.playing`) en multiview als volledig scherm erboven; terug-knop logisch afhandelen.

Schermen (zelfde gedrag als de Swift-schermen met dezelfde naam): `SplashScreen` (vallende covers + BINGR met rode streep), `PlaylistPickerScreen` ("Wat wil je kijken?", ronde avatars, bij focus groter met witte rand, Toevoegen, Beheren, iCloud-regel vervangen door "Op dit apparaat"), `AddPlaylistScreen` (alle bronsoorten, naam, avatar-emoji+kleur, foto uit galerij via PhotoPicker, testen), `MainScreen` (telefoon: onderbalk Home/Live TV/Films/Series/Zoeken/Mijn Bingr; TV: bovenbalk met dezelfde tabs; startscherm/verbergen uit Prefs "ui.startTab"/"ui.showLive"/…), `HomeScreen(filter)` (billboard, Mijn lijst, Onlangs toegevoegd, Verder kijken (verwijderbaar, geen live), Voor jou, Top 10 series/films (Netflix-stijl), favoriete zenders, categorierijen met "Bekijk allemaal"; vergrootglas rechtsboven op telefoon), `CategoryScreen` (terug, titel in hoofdletters, sorteren, raster met score), `DetailScreen` (UHF-stijl: achtergrond, logo/titel, score, jaar, duur, Afspelen/verder kijken, Mijn lijst, trailer (YouTube-app/web), bekeken, seizoenen + afleveringen met foto/voortgang, cast, aanbevelingen, andere bronnen, leeftijdsfilter-pincode), `LiveTVScreen` (standaard "Alle zenders", favorieten, recent, groepen; lijst + tv-gids-raster; zenders hernoemen/favoriet via lang indrukken; multiview), `GuideSheet`/`ProgramSheet` (kijken, terugkijken, herinnering), `SearchScreen` (alles: films, series, zenders, categorieën, tv-gids, andere playlists), `SettingsScreen` ("Mijn Bingr": profiel, bibliotheek (kijkgeschiedenis, NAS), updaten, Trakt, OpenSubtitles, speler (engine, standaard audio/ondertitel), kinderslot (pincode, leeftijdsgrens), weergave (categorieën aan/uit, startscherm, tabs), taal, delen tussen apparaten (export/import JSON i.p.v. iCloud), koppelingen instellen, over), plus `CategoriesScreen` (aan/uit met landcodes NL/BE/DE…), `ManageScreen`, `HistoryScreen`, `NetworkBrowserScreen` (SMB/UPnP via LibVLC `MediaBrowser`), `ConnectionsSetupScreen`, `TraktLoginScreen` (code + QR), `OpenSubtitlesLoginScreen`, `PinPad`.
