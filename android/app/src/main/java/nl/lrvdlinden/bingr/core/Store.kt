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
 */
object Store {
    private lateinit var dir: File
    private lateinit var secrets: SharedPreferences

    var playlists by mutableStateOf(listOf<PlaylistSource>()); private set
    /** "<playlistID>|<itemID>" */
    var favorites by mutableStateOf(setOf<String>()); private set
    var myList by mutableStateOf(setOf<String>()); private set
    /** key: item-id */
    var progress by mutableStateOf(mapOf<String, ProgressEntry>()); private set
    var localWatched by mutableStateOf(setOf<String>()); private set
    var recentChannels by mutableStateOf(listOf<String>()); private set
    var customizations by mutableStateOf(mapOf<String, Customization>()); private set
    var parental by mutableStateOf(ParentalSettings()); private set
    var reminders by mutableStateOf(listOf<ProgramReminder>()); private set
    var history by mutableStateOf(listOf<HistoryEntry>()); private set
    var nasServers by mutableStateOf(listOf<NASServer>()); private set
    /** verandert als een profielfoto wijzigt (zodat afbeeldingen opnieuw laden) */
    var photoVersion by mutableStateOf(0); private set
    /** Het profiel dat nu open is */
    var activePlaylistID: String? = null

    fun init(ctx: Context) {
        dir = File(ctx.filesDir, "store").apply { mkdirs() }
        secrets = ctx.getSharedPreferences("bingr.secrets", Context.MODE_PRIVATE)
        load()
    }

    // MARK: opslaan/laden

    private inline fun <reified T> read(name: String, def: T): T =
        runCatching { Http.json.decodeFromString<T>(File(dir, "$name.json").readText()) }.getOrDefault(def)

    private inline fun <reified T> write(name: String, value: T) {
        runCatching { File(dir, "$name.json").writeText(Http.json.encodeToString(value)) }
    }

    fun load() {
        playlists = read("playlists", emptyList())
        favorites = read("favorites", emptySet())
        myList = read("mylist", emptySet())
        progress = read("progress", emptyMap())
        localWatched = read("watched", emptySet())
        recentChannels = read("recent", emptyList())
        customizations = read("custom", emptyMap())
        parental = read("parental", ParentalSettings())
        reminders = read<List<ProgramReminder>>("reminders", emptyList()).filter { it.start > System.currentTimeMillis() - 3_600_000 }
        history = read("history", emptyList())
        nasServers = read("nas", emptyList())
    }

    // MARK: geheimen (wachtwoorden, tokens, eigen API-sleutels)

    fun secret(key: String): String? = secrets.getString(key, null)
    fun setSecret(key: String, value: String?) {
        secrets.edit().apply { if (value == null) remove(key) else putString(key, value) }.apply()
    }

    // MARK: playlists / profielen

    fun upsert(p: PlaylistSource) {
        val n = p.copy(updatedAt = System.currentTimeMillis())
        playlists = if (playlists.any { it.id == n.id }) playlists.map { if (it.id == n.id) n else it } else playlists + n
        write("playlists", playlists)
    }

    fun delete(p: PlaylistSource) {
        playlists = playlists.filterNot { it.id == p.id }
        write("playlists", playlists)
        setSecret(p.passwordKey, null)
        photoFile(p.id).delete()
        customizations = customizations - p.id; write("custom", customizations)
    }

    fun photoFile(playlistID: String) = File(dir, "photo-$playlistID.jpg")
    fun photo(playlistID: String): Bitmap? = photoFile(playlistID).takeIf { it.exists() }?.let { BitmapFactory.decodeFile(it.path) }
    fun setPhoto(playlistID: String, jpeg: ByteArray?) {
        if (jpeg == null) photoFile(playlistID).delete() else photoFile(playlistID).writeBytes(jpeg)
        photoVersion++
    }

    fun key(playlist: String, item: String) = "$playlist|$item"

    fun toggleFavorite(playlist: String, item: String) {
        val k = key(playlist, item)
        favorites = if (k in favorites) favorites - k else favorites + k
        write("favorites", favorites)
    }
    fun isFavorite(playlist: String, item: String) = key(playlist, item) in favorites

    fun toggleMyList(playlist: String, item: String) {
        val k = key(playlist, item)
        myList = if (k in myList) myList - k else myList + k
        write("mylist", myList)
    }
    fun inMyList(playlist: String, item: String) = key(playlist, item) in myList

    // MARK: voortgang / bekeken

    fun setProgress(itemKey: String, entry: ProgressEntry) {
        var p = progress + (itemKey to entry)
        if (p.size > 300) p = p.entries.sortedByDescending { it.value.updated }.take(250).associate { it.key to it.value }
        progress = p
        write("progress", progress)
    }
    fun clearProgress(itemKey: String) { progress = progress - itemKey; write("progress", progress) }

    fun setLocalWatched(itemKey: String, watched: Boolean) {
        localWatched = if (watched) localWatched + itemKey else localWatched - itemKey
        write("watched", localWatched)
    }

    fun pushRecentChannel(playlist: String, channelID: String) {
        val k = key(playlist, channelID)
        recentChannels = (listOf(k) + recentChannels.filterNot { it == k }).take(20)
        write("recent", recentChannels)
    }

    // MARK: aanpassingen (hernoemen / verbergen / volgorde / samenvoegen)

    fun customization(playlist: String) = customizations[playlist] ?: Customization()
    fun updateCustomization(playlist: String, change: (Customization) -> Customization) {
        customizations = customizations + (playlist to change(customization(playlist)))
        write("custom", customizations)
    }

    // MARK: kinderslot

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
        history = (listOf(e) + history.filterNot { it.itemID == e.itemID && it.playlistID == e.playlistID }).take(200)
        write("history", history)
    }
    fun removeHistory(e: HistoryEntry) { history = history.filterNot { it.id == e.id }; write("history", history) }
    fun clearHistory(playlist: String?) { history = history.filterNot { it.playlistID == playlist }; write("history", history) }
    fun history(playlist: String?) = history.filter { it.playlistID == playlist }

    // MARK: NAS

    fun saveNAS(list: List<NASServer>) { nasServers = list; write("nas", list) }

    // MARK: delen tussen apparaten (Android heeft geen iCloud)

    @Serializable
    private data class Backup(
        val playlists: List<PlaylistSource>,
        val passwords: Map<String, String>,
        val favorites: Set<String>,
        val myList: Set<String>,
        val progress: Map<String, ProgressEntry>,
        val watched: Set<String>,
        val custom: Map<String, Customization>,
        val parental: ParentalSettings,
        val history: List<HistoryEntry> = emptyList(),
    )

    /** Alles (incl. wachtwoorden) als JSON, om naar een ander apparaat te sturen. */
    fun exportJSON(): String = Http.json.encodeToString(
        Backup(playlists, playlists.mapNotNull { p -> secret(p.passwordKey)?.let { p.passwordKey to it } }.toMap(),
            favorites, myList, progress, localWatched, customizations, parental, history)
    )

    /** Samenvoegen met een export van een ander apparaat. */
    fun importJSON(text: String): Boolean = runCatching {
        val b = Http.json.decodeFromString<Backup>(text)
        b.playlists.forEach { p -> if (playlists.none { it.id == p.id }) upsert(p) }
        b.passwords.forEach { (k, v) -> if (secret(k) == null) setSecret(k, v) }
        favorites = favorites + b.favorites; write("favorites", favorites)
        myList = myList + b.myList; write("mylist", myList)
        val merged = progress.toMutableMap()
        b.progress.forEach { (k, v) -> if ((merged[k]?.updated ?: 0) < v.updated) merged[k] = v }
        progress = merged; write("progress", progress)
        localWatched = localWatched + b.watched; write("watched", localWatched)
        customizations = b.custom + customizations; write("custom", customizations)
        history = (history + b.history).distinctBy { it.id }.sortedByDescending { it.date }.take(200); write("history", history)
        true
    }.getOrDefault(false)
}
