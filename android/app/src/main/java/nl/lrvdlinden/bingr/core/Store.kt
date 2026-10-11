package nl.lrvdlinden.bingr

import android.content.Context
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import java.io.File

/**
 * Alle gebruikersgegevens (Android-tegenhanger van CloudStore op iOS).
 * Compose-state: schermen die dit lezen verversen vanzelf.
 * Opslag: JSON-bestanden in de app-map. Tussen apparaten delen kan via [exportJSON]/[importJSON].
 *
 * ## Kijkprofielen ("Wie kijkt er?")
 * Eén hoofdaccount met de server(s) ([playlists], [mainSource]), Trakt en OpenSubtitles; daaronder kijkprofielen
 * ([profiles], [ViewerProfile]). Per profiel apart (bestanden in `store/profile-<id>/`):
 * [favorites], [myList], [progress] (Verder kijken), [localWatched], [recentChannels], [history],
 * plus kijkvoorkeuren, avatar/foto ([photo] met het profiel-id), pincode en leeftijdsgrens.
 * Gedeeld: server(s), [customizations], [parental], [reminders], NAS, Trakt, OpenSubtitles.
 *
 * De bestaande API's ([toggleFavorite], [setProgress], [addHistory], …) werken altijd op het **actieve** profiel
 * ([activeProfile]); wissel met [selectProfile] (of beter `AppState.open(profile)`).
 */
object Store {
    private lateinit var dir: File
    private lateinit var secrets: SharedPreferences

    var playlists by mutableStateOf(listOf<PlaylistSource>()); private set
    /** "<playlistID>|<itemID>" — van het actieve profiel */
    var favorites by mutableStateOf(setOf<String>()); private set
    /** "<playlistID>|<itemID>" — van het actieve profiel */
    var myList by mutableStateOf(setOf<String>()); private set
    /** key: item-id — van het actieve profiel */
    var progress by mutableStateOf(mapOf<String, ProgressEntry>()); private set
    /** item-id's en [episodeKey]'s — van het actieve profiel */
    var localWatched by mutableStateOf(setOf<String>()); private set
    /** "<playlistID>|<channelID>" — van het actieve profiel */
    var recentChannels by mutableStateOf(listOf<String>()); private set
    var customizations by mutableStateOf(mapOf<String, Customization>()); private set
    var parental by mutableStateOf(ParentalSettings()); private set
    var reminders by mutableStateOf(listOf<ProgramReminder>()); private set
    /** Kijkgeschiedenis van het actieve profiel */
    var history by mutableStateOf(listOf<HistoryEntry>()); private set
    var nasServers by mutableStateOf(listOf<NASServer>()); private set
    /** verandert als een profielfoto wijzigt (zodat afbeeldingen opnieuw laden) */
    var photoVersion by mutableStateOf(0); private set
    /** De server (bron) die nu open is (gezet door Playlists.select) */
    var activePlaylistID: String? = null

    // MARK: profielen -------------------------------------------------------------

    /** Alle kijkprofielen (volgorde = volgorde in "Wie kijkt er?") */
    var profiles by mutableStateOf(listOf<ViewerProfile>()); private set
    /** De server die alle profielen gebruiken */
    var mainSourceID by mutableStateOf<String?>(null); private set
    /** Gekozen profiel op dít apparaat (Prefs "activeProfileID") */
    var activeProfileID by mutableStateOf<String?>(null); private set
    private var mainProfileIDStored by mutableStateOf<String?>(null)

    /** Het hoofdaccount: alleen dat profiel beheert server, Trakt, OpenSubtitles, kinderslot, categorieën en profielen. */
    val mainProfileID: String?
        get() {
            val m = mainProfileIDStored
            if (m != null && profiles.any { it.id == m }) return m
            return profiles.firstOrNull()?.id
        }
    val mainProfile: ViewerProfile? get() = mainProfileID?.let { id -> profiles.firstOrNull { it.id == id } }
    val activeProfile: ViewerProfile? get() = activeProfileID?.let { id -> profiles.firstOrNull { it.id == id } }
    fun isMain(p: ViewerProfile): Boolean = p.id == mainProfileID
    fun isMain(profileID: String?): Boolean = profileID != null && profileID == mainProfileID
    /** Is het actieve profiel het hoofdaccount? */
    val isMainActive: Boolean get() = activeProfileID != null && activeProfileID == mainProfileID
    /** Mag het actieve profiel beheren (hoofdaccount, of nog geen profiel gekozen/aanwezig)? */
    val canManage: Boolean get() = isMainActive || activeProfileID == null || profiles.isEmpty()
    /** De server van het hoofdaccount (of de eerste) */
    val mainSource: PlaylistSource? get() = playlists.firstOrNull { it.id == mainSourceID } ?: playlists.firstOrNull()

    @Serializable
    private data class ProfileMeta(val mainSourceID: String? = null, val mainProfileID: String? = null)

    @Serializable
    data class ProfileData(
        val favorites: Set<String> = emptySet(),
        val myList: Set<String> = emptySet(),
        val progress: Map<String, ProgressEntry> = emptyMap(),
        val watched: Set<String> = emptySet(),
        val recent: List<String> = emptyList(),
        val history: List<HistoryEntry> = emptyList(),
    )

    /** Per-profiel-bestanden (vroeger in store/, nu in store/profile-<id>/) */
    private val profileFiles = listOf("favorites", "mylist", "progress", "watched", "recent", "history")

    fun init(ctx: Context) {
        dir = File(ctx.filesDir, "store").apply { mkdirs() }
        secrets = ctx.getSharedPreferences("bingr.secrets", Context.MODE_PRIVATE)
        load()
    }

    // MARK: opslaan/laden

    private fun profileDir(id: String?): File =
        if (id == null) dir else File(dir, "profile-$id").apply { mkdirs() }
    /** Map van het actieve profiel (zonder profiel: de oude map, wordt bij het eerste profiel overgenomen) */
    private val pdir: File get() = profileDir(activeProfileID)

    private inline fun <reified T> readIn(d: File, name: String, def: T): T =
        runCatching { Http.json.decodeFromString<T>(File(d, "$name.json").readText()) }.getOrDefault(def)

    private inline fun <reified T> writeIn(d: File, name: String, value: T) {
        runCatching { File(d, "$name.json").writeText(Http.json.encodeToString(value)) }
    }

    private inline fun <reified T> read(name: String, def: T): T = readIn(dir, name, def)
    private inline fun <reified T> write(name: String, value: T) = writeIn(dir, name, value)
    /** Schrijven in de map van het actieve profiel */
    private inline fun <reified T> pwrite(name: String, value: T) = writeIn(pdir, name, value)

    fun load() {
        playlists = read("playlists", emptyList())
        customizations = read("custom", emptyMap())
        parental = read("parental", ParentalSettings())
        reminders = read<List<ProgramReminder>>("reminders", emptyList()).filter { it.start > System.currentTimeMillis() - 3_600_000 }
        nasServers = read("nas", emptyList())

        profiles = read("profiles", emptyList())
        val meta = read("profilemeta", ProfileMeta())
        mainSourceID = meta.mainSourceID
        mainProfileIDStored = meta.mainProfileID
        activeProfileID = Prefs.string("activeProfileID")
        migrateToProfiles()
        ensureMainProfile()
        if (activeProfileID != null && profiles.none { it.id == activeProfileID }) {
            activeProfileID = mainProfileID
            Prefs.put("activeProfileID", activeProfileID)
        }
        loadProfileData()
    }

    private fun loadProfileData() {
        val d = pdir
        favorites = readIn(d, "favorites", emptySet())
        myList = readIn(d, "mylist", emptySet())
        progress = readIn(d, "progress", emptyMap())
        localWatched = readIn(d, "watched", emptySet())
        recentChannels = readIn(d, "recent", emptyList())
        history = readIn(d, "history", emptyList())
    }

    private fun saveMeta() = write("profilemeta", ProfileMeta(mainSourceID, mainProfileIDStored))

    /** Gegevens van vóór de profielen (store/*.json) naar de map van dit profiel verplaatsen (alleen het hoofdaccount). */
    private fun adoptLegacyData(profileID: String) {
        val target = profileDir(profileID)
        for (name in profileFiles) {
            val src = File(dir, "$name.json")
            if (!src.exists()) continue
            val dst = File(target, "$name.json")
            if (dst.exists()) { src.delete(); continue }
            if (!src.renameTo(dst)) runCatching { src.copyTo(dst, overwrite = true); src.delete() }
        }
    }

    /** Bestaande afspeellijsten (vroeger = profielen) eenmalig omzetten naar kijkprofielen (zoals iOS). */
    private fun migrateToProfiles() {
        if (File(dir, "profiles.json").exists() || profiles.isNotEmpty() || playlists.isEmpty()) return
        val list = playlists.map { p ->
            val prof = ViewerProfile(name = p.name, avatar = p.avatar, ageLimit = p.ageLimit)
            val photo = photoFile(p.id)
            if (photo.exists()) runCatching { photo.copyTo(photoFile(prof.id), overwrite = true) }
            prof
        }
        profiles = list
        write("profiles", list)
        mainProfileIDStored = list.first().id
        val last = Prefs.string("lastPlaylistID")
        mainSourceID = playlists.firstOrNull { it.id == last }?.id ?: playlists.first().id
        saveMeta()
        adoptLegacyData(list.first().id)
        if (activeProfileID == null) {
            activeProfileID = list.first().id
            Prefs.put("activeProfileID", activeProfileID)
        }
    }

    /** Er is een server maar (nog) geen profiel (bijv. na importeren): hoofdprofiel aanmaken. */
    private fun ensureMainProfile() {
        if (mainSourceID == null || playlists.none { it.id == mainSourceID }) {
            val s = playlists.firstOrNull()
            if (s?.id != mainSourceID) { mainSourceID = s?.id; saveMeta() }
        }
        if (profiles.isNotEmpty() || playlists.isEmpty()) return
        val src = mainSource ?: return
        val main = ViewerProfile(name = src.name, avatar = src.avatar)
        val photo = photoFile(src.id)
        if (photo.exists()) runCatching { photo.copyTo(photoFile(main.id), overwrite = true) }
        profiles = listOf(main)
        write("profiles", profiles)
        mainProfileIDStored = main.id
        saveMeta()
        adoptLegacyData(main.id)
        if (activeProfileID == null) {
            activeProfileID = main.id
            Prefs.put("activeProfileID", activeProfileID)
        }
    }

    /** Dit profiel actief maken: eigen lijsten, voortgang, geschiedenis en kijkvoorkeuren laden. */
    fun selectProfile(p: ViewerProfile) {
        activeProfileID = p.id
        Prefs.put("activeProfileID", p.id)
        applyPreferences(p)
        loadProfileData()
    }

    /** Kijkvoorkeuren van dit profiel actief maken (automatische ondertitels, talen). */
    private fun applyPreferences(p: ViewerProfile) {
        // nieuw/ander profiel zonder eigen keuze → standaardwaarden, niet die van een ander profiel
        val fresh = !isMain(p)
        val auto = p.autoSubtitles
        if (auto != null) Prefs.put("autoSubtitles", auto) else if (fresh) Prefs.put("autoSubtitles", false)
        val audio = p.audioLanguage
        if (audio != null) TrackPreferences.audio = audio else if (fresh) TrackPreferences.audio = ""
        val sub = p.streamSubtitleLanguage
        if (sub != null) TrackPreferences.subtitle = sub else if (fresh) TrackPreferences.subtitle = ""
        val os = p.subtitleLanguage
        if (os != null) OpenSubtitles.defaultLanguage = os
        else if (fresh) OpenSubtitles.defaultLanguage = Localizer.language.take(2)
    }

    /** Kijkvoorkeur van het actieve profiel opslaan, bijv. `Store.updateActivePreferences { it.copy(autoSubtitles = true) }`. */
    fun updateActivePreferences(change: (ViewerProfile) -> ViewerProfile) {
        val p = activeProfile ?: return
        val n = change(p)
        if (n != p) upsertProfile(n)
    }

    fun upsertProfile(p: ViewerProfile) {
        profiles = if (profiles.any { it.id == p.id }) profiles.map { if (it.id == p.id) p else it } else profiles + p
        write("profiles", profiles)
        if (mainProfileIDStored == null) { mainProfileIDStored = profiles.first().id; saveMeta() }
    }

    /** Profiel met al zijn gegevens verwijderen. Het hoofdaccount kan niet verwijderd worden. */
    fun deleteProfile(p: ViewerProfile) {
        if (isMain(p)) return
        profiles = profiles.filterNot { it.id == p.id }
        write("profiles", profiles)
        setPhoto(p.id, null)
        setSecret("profile.${p.id}.pin", null)
        runCatching { File(dir, "profile-${p.id}").deleteRecursively() }
        if (activeProfileID == p.id) {
            activeProfileID = null
            Prefs.put("activeProfileID", null)
            loadProfileData()
        }
    }

    fun setMainSource(id: String) {
        mainSourceID = id
        saveMeta()
    }

    /** Hoort een opgeslagen item bij het actieve profiel? Oude items zonder profiel horen bij het hoofdaccount. */
    fun belongsToActive(profileID: String?): Boolean {
        val active = activeProfileID ?: return true
        if (profileID != null) return profileID == active
        return active == mainProfileID
    }

    // MARK: geheimen (wachtwoorden, tokens, eigen API-sleutels)

    fun secret(key: String): String? = secrets.getString(key, null)
    fun setSecret(key: String, value: String?) {
        secrets.edit().apply { if (value == null) remove(key) else putString(key, value) }.apply()
    }

    // MARK: servers (afspeellijsten)

    /**
     * Server toevoegen/bijwerken. De eerste server wordt meteen de hoofdserver, en als er nog geen profiel is
     * wordt het hoofdprofiel aangemaakt (naam/avatar van de server) en gekozen.
     */
    fun upsert(p: PlaylistSource) {
        val n = p.copy(updatedAt = System.currentTimeMillis())
        playlists = if (playlists.any { it.id == n.id }) playlists.map { if (it.id == n.id) n else it } else playlists + n
        write("playlists", playlists)
        if (mainSourceID == null || playlists.none { it.id == mainSourceID }) setMainSource(n.id)
        if (profiles.isEmpty()) {
            val main = ViewerProfile(name = n.name, avatar = n.avatar)
            mainProfileIDStored = main.id
            upsertProfile(main)
            saveMeta()
            adoptLegacyData(main.id)
            if (activeProfileID == null) selectProfile(main)
        }
    }

    fun delete(p: PlaylistSource) {
        playlists = playlists.filterNot { it.id == p.id }
        write("playlists", playlists)
        if (mainSourceID == p.id) { mainSourceID = playlists.firstOrNull()?.id; saveMeta() }
        setSecret(p.passwordKey, null)
        photoFile(p.id).delete()
        customizations = customizations - p.id; write("custom", customizations)
    }

    // MARK: foto's (profiel-id of server-id)

    fun photoFile(id: String) = File(dir, "photo-$id.jpg")
    fun photo(id: String): Bitmap? = photoFile(id).takeIf { it.exists() }?.let { BitmapFactory.decodeFile(it.path) }
    fun setPhoto(id: String, jpeg: ByteArray?) {
        if (jpeg == null) photoFile(id).delete() else photoFile(id).writeBytes(jpeg)
        photoVersion++
    }

    // MARK: favorieten / mijn lijst (per profiel)

    fun key(playlist: String, item: String) = "$playlist|$item"

    fun toggleFavorite(playlist: String, item: String) {
        val k = key(playlist, item)
        favorites = if (k in favorites) favorites - k else favorites + k
        pwrite("favorites", favorites)
    }
    fun isFavorite(playlist: String, item: String) = key(playlist, item) in favorites

    fun toggleMyList(playlist: String, item: String) {
        val k = key(playlist, item)
        myList = if (k in myList) myList - k else myList + k
        pwrite("mylist", myList)
    }
    fun inMyList(playlist: String, item: String) = key(playlist, item) in myList
    fun setMyList(playlist: String, item: String, on: Boolean) {
        if (inMyList(playlist, item) != on) toggleMyList(playlist, item)
    }

    // MARK: voortgang / bekeken (per profiel)

    fun setProgress(itemKey: String, entry: ProgressEntry) {
        val e = if (entry.profileID == null && activeProfileID != null) entry.copy(profileID = activeProfileID) else entry
        var p = progress + (itemKey to e)
        if (p.size > 300) p = p.entries.sortedByDescending { it.value.updated }.take(250).associate { it.key to it.value }
        progress = p
        pwrite("progress", progress)
    }
    fun clearProgress(itemKey: String) { progress = progress - itemKey; pwrite("progress", progress) }

    fun setLocalWatched(itemKey: String, watched: Boolean) {
        localWatched = if (watched) localWatched + itemKey else localWatched - itemKey
        pwrite("watched", localWatched)
    }

    /**
     * Sleutel voor "aflevering bekeken" per serie (seizoen-aflevering), zodat het vinkje en "X GEZIEN" ook kloppen
     * als de afleveringen pas later geladen worden. Geldt per profiel, ook zonder Trakt.
     */
    fun episodeKey(series: String, season: Int, episode: Int): String = "ep:$series|$season-$episode"

    fun setEpisodeWatched(e: Episode, watched: Boolean) {
        val k = episodeKey(e.seriesID, e.season, e.number)
        localWatched = if (watched) localWatched + e.id + k else localWatched - e.id - k
        pwrite("watched", localWatched)
    }

    /** Is deze aflevering lokaal (zonder Trakt) als bekeken gemarkeerd? */
    fun isEpisodeWatched(e: Episode): Boolean =
        e.id in localWatched || episodeKey(e.seriesID, e.season, e.number) in localWatched

    /** Aantal lokaal bekeken afleveringen van een serie (actief profiel). */
    fun localWatchedCount(seriesID: String): Int {
        val prefix = "ep:$seriesID|"
        return localWatched.count { it.startsWith(prefix) }
    }

    fun pushRecentChannel(playlist: String, channelID: String) {
        val k = key(playlist, channelID)
        recentChannels = (listOf(k) + recentChannels.filterNot { it == k }).take(20)
        pwrite("recent", recentChannels)
    }

    // MARK: aanpassingen (hernoemen / verbergen / volgorde / samenvoegen) — gedeeld

    fun customization(playlist: String) = customizations[playlist] ?: Customization()
    fun updateCustomization(playlist: String, change: (Customization) -> Customization) {
        customizations = customizations + (playlist to change(customization(playlist)))
        write("custom", customizations)
    }

    // MARK: kinderslot — gedeeld (ingesteld door het hoofdaccount)

    fun updateParental(change: (ParentalSettings) -> ParentalSettings) {
        parental = change(parental); write("parental", parental)
    }

    // MARK: herinneringen

    fun addReminder(r: ProgramReminder) {
        reminders = reminders.filterNot { it.id == r.id } + r; write("reminders", reminders)
    }
    fun removeReminder(id: String) { reminders = reminders.filterNot { it.id == id }; write("reminders", reminders) }
    fun hasReminder(id: String) = reminders.any { it.id == id }

    // MARK: kijkgeschiedenis (per profiel)

    fun addHistory(e: HistoryEntry) {
        val n = if (e.profileID == null && activeProfileID != null) e.copy(profileID = activeProfileID) else e
        history = (listOf(n) + history.filterNot { it.itemID == n.itemID && it.playlistID == n.playlistID }).take(200)
        pwrite("history", history)
    }
    fun removeHistory(e: HistoryEntry) { history = history.filterNot { it.id == e.id }; pwrite("history", history) }
    fun clearHistory(playlist: String?) { history = history.filterNot { it.playlistID == playlist }; pwrite("history", history) }
    /** Kijkgeschiedenis van het actieve profiel op deze server. */
    fun history(playlist: String?) = history.filter { it.playlistID == playlist && belongsToActive(it.profileID) }

    // MARK: NAS

    fun saveNAS(list: List<NASServer>) { nasServers = list; write("nas", list) }

    // MARK: delen tussen apparaten (Android heeft geen iCloud)

    @Serializable
    private data class Backup(
        val playlists: List<PlaylistSource>,
        val passwords: Map<String, String>,
        /** gegevens van het actieve profiel (ook het formaat van vóór de profielen) */
        val favorites: Set<String>,
        val myList: Set<String>,
        val progress: Map<String, ProgressEntry>,
        val watched: Set<String>,
        val custom: Map<String, Customization>,
        val parental: ParentalSettings,
        val history: List<HistoryEntry> = emptyList(),
        val profiles: List<ViewerProfile> = emptyList(),
        val profileData: Map<String, ProfileData> = emptyMap(),
        val mainSourceID: String? = null,
        val mainProfileID: String? = null,
    )

    private fun readProfileData(id: String): ProfileData {
        if (id == activeProfileID) return ProfileData(favorites, myList, progress, localWatched, recentChannels, history)
        val d = profileDir(id)
        return ProfileData(
            readIn(d, "favorites", emptySet()), readIn(d, "mylist", emptySet()), readIn(d, "progress", emptyMap()),
            readIn(d, "watched", emptySet()), readIn(d, "recent", emptyList()), readIn(d, "history", emptyList()),
        )
    }

    private fun mergeProfileData(id: String, b: ProfileData) {
        val cur = readProfileData(id)
        val prog = cur.progress.toMutableMap()
        b.progress.forEach { (k, v) -> if ((prog[k]?.updated ?: 0) < v.updated) prog[k] = v }
        val merged = ProfileData(
            favorites = cur.favorites + b.favorites,
            myList = cur.myList + b.myList,
            progress = prog,
            watched = cur.watched + b.watched,
            recent = (cur.recent + b.recent).distinct().take(20),
            history = (cur.history + b.history).distinctBy { it.id }.sortedByDescending { it.date }.take(200),
        )
        val d = profileDir(id)
        writeIn(d, "favorites", merged.favorites); writeIn(d, "mylist", merged.myList)
        writeIn(d, "progress", merged.progress); writeIn(d, "watched", merged.watched)
        writeIn(d, "recent", merged.recent); writeIn(d, "history", merged.history)
        if (id == activeProfileID) loadProfileData()
    }

    /** Alles (incl. wachtwoorden, profielen en pincodes) als JSON, om naar een ander apparaat te sturen. */
    fun exportJSON(): String {
        val keys = playlists.map { it.passwordKey } + playlists.map { "playlist.${it.id}.session" } +
            listOf("parental.pin") + profiles.map { "profile.${it.id}.pin" }
        return Http.json.encodeToString(
            Backup(playlists, keys.mapNotNull { k -> secret(k)?.let { k to it } }.toMap(),
                favorites, myList, progress, localWatched, customizations, parental, history,
                profiles = profiles,
                profileData = profiles.associate { it.id to readProfileData(it.id) },
                mainSourceID = mainSourceID, mainProfileID = mainProfileID)
        )
    }

    /** Samenvoegen met een export van een ander apparaat. */
    fun importJSON(text: String): Boolean = runCatching {
        val b = Http.json.decodeFromString<Backup>(text)
        b.playlists.forEach { p -> if (playlists.none { it.id == p.id }) upsert(p) }
        b.passwords.forEach { (k, v) -> if (secret(k) == null) setSecret(k, v) }
        customizations = b.custom + customizations; write("custom", customizations)
        if (b.profiles.isEmpty()) {
            // export van vóór de profielen: bij het actieve profiel (of het hoofdaccount) voegen
            val target = activeProfileID ?: mainProfileID
            if (target != null) mergeProfileData(target,
                ProfileData(b.favorites, b.myList, b.progress, b.watched, emptyList(), b.history))
        } else {
            for (p in b.profiles) if (profiles.none { it.id == p.id }) upsertProfile(p)
            b.profileData.forEach { (id, data) -> if (profiles.any { it.id == id }) mergeProfileData(id, data) }
        }
        true
    }.getOrDefault(false)
}
