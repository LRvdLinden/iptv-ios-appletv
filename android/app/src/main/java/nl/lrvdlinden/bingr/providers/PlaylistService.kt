package nl.lrvdlinden.bingr

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.JsonObject
import java.io.File

/**
 * Laadt, cachet en presenteert de inhoud van de gekozen afspeellijst (= PlaylistService.swift).
 * [library] is de inhoud na jouw aanpassingen (hernoemd, verborgen, volgorde, samengevoegd),
 * zonder groepen op kinderslot en gefilterd op de leeftijdsgrens van het profiel.
 *
 * ## Voor het toevoeg-scherm (AddPlaylistScreen)
 *
 * ```
 * // Plex koppelen met een code (plex.tv/link):
 * val pin: PlexPin = PlexAuth.startPin()            // toon pin.code + "Go to plex.tv/link and enter this code:"
 * val token: String = PlexAuth.waitForToken(pin)    // wacht max ±5 min (gooit ServiceException bij verlopen)
 * //   of zelf pollen: PlexAuth.poll(pin): String?  (null = nog niet bevestigd)
 *
 * // Stremio-account (optioneel): wordt in validate() gedaan met p.username (= e-mail) + password,
 * // maar kan ook los: StremioAuth.login(email, password): String  (authKey)
 *
 * // Opslaan ("Save"): eerst testen en geheimen bewaren, dan pas Store.upsert:
 * val err: String? = Playlists.test(p, password)    // null = gelukt
 * //   of: val saved: PlaylistSource = Playlists.validate(p, password)  (gooit; Plex vult serverURL in)
 * Store.upsert(saved)
 * ```
 * Wat `password` betekent per soort:
 * - XTREAM: wachtwoord → bewaard in Store.secret(p.passwordKey)
 * - JELLYFIN/EMBY: wachtwoord → alleen gebruikt om in te loggen; de sessie (token) komt in
 *   Store.secret(Playlists.sessionKey(p)), Store.secret(p.passwordKey) wordt gewist
 * - PLEX: het Plex-token uit [PlexAuth] (leeg = bestaand token houden bij bewerken)
 * - STREMIO: Stremio-wachtwoord (p.username = e-mail); leeg = geen account/bestaande authKey houden
 * - M3U/STALKER: niet gebruikt
 * Bij succes wordt de cache van die afspeellijst gewist (zoals op iOS).
 *
 * Verwijderen: `Playlists.forget(p)` (Store.delete + cache + sessie wissen).
 * Bewerken: wachtwoord vooraf invullen met `Store.secret(p.passwordKey)` (niet voor Plex/Stremio).
 */
@OptIn(FlowPreview::class)
object Playlists {
    var source by mutableStateOf<PlaylistSource?>(null); private set
    var library by mutableStateOf(Library()); private set
    var rawLibrary by mutableStateOf(Library()); private set
    var isLoading by mutableStateOf(false); private set
    var loadingText by mutableStateOf(""); private set
    var error by mutableStateOf<String?>(null)
    var refreshingAll by mutableStateOf(false); private set
    var episodeCache by mutableStateOf(mapOf<String, List<Episode>>()); private set
    /**
     * Bezig met filteren op de achtergrond (grote lijsten). Bij een profiel met leeftijdsgrens is [library]
     * dan leeg (niets ongefilterds tonen): laat geen "lege lijst"-melding zien zolang dit true is.
     */
    var isFiltering by mutableStateOf(false); private set
    private var filterGeneration = 0
    private var filterJob: Job? = null

    private var stalker: StalkerClient? = null
    private var stremioAddons: List<StremioClient.Addon> = emptyList()

    init {
        // aanpassingen of kinderslot gewijzigd → opnieuw toepassen
        AppScope.launch {
            snapshotFlow { Store.customizations to Store.parental }.drop(1).collect { applyCustomizations() }
        }
        AppScope.launch {
            snapshotFlow { ParentalControl.unlockedUntil }.drop(1).collect { applyCustomizations() }
        }
        // server aangepast (naam, gegevens) → bijwerken
        AppScope.launch {
            snapshotFlow { Store.playlists }.drop(1).collect { list ->
                val s = source ?: return@collect
                val u = list.firstOrNull { it.id == s.id } ?: return@collect
                if (u != s) source = u
            }
        }
        // ander kijkprofiel gekozen of leeftijdsgrens/kinderprofiel gewijzigd → opnieuw filteren
        AppScope.launch {
            snapshotFlow { Store.activeProfile?.let { "${it.effectiveAgeLimit ?: 0}-${it.strictAgeFilter}" } ?: "" }
                .drop(1).collect { applyCustomizations() }
        }
        // nieuwe IMDb-classificaties binnen → leeftijdsfilter opnieuw toepassen
        AppScope.launch {
            snapshotFlow { Metadata.version }.drop(1).debounce(3_000).collect {
                if (Store.activeProfile?.effectiveAgeLimit != null) applyCustomizations()
            }
        }
    }

    // MARK: laden

    suspend fun select(p: PlaylistSource, forceRefresh: Boolean = false) {
        source = p
        Store.activePlaylistID = p.id
        stalker = if (p.kind == PlaylistKind.STALKER) StalkerClient(p) else null
        stremioAddons = emptyList()
        episodeCache = emptyMap()
        error = null

        if (!forceRefresh) {
            // grote lijsten (tienduizenden titels) op de achtergrond inlezen
            isLoading = true
            val cached = try { withContext(Dispatchers.IO) { readCache(p) } } finally { isLoading = false }
            if (source?.id != p.id) return
            if (cached != null) {
                setRaw(cached)
                if (!RefreshPolicy.current.isDue(cacheAge(p))) return
                AppScope.launch { refresh(p, showSpinner = false) }
                return
            }
        }
        setRaw(Library())
        refresh(p, showSpinner = true)
    }

    suspend fun refresh(s: PlaylistSource, showSpinner: Boolean) {
        if (showSpinner) isLoading = true
        try {
            val password = Store.secret(s.passwordKey) ?: ""
            var lib: Library
            when (s.kind) {
                PlaylistKind.M3U -> {
                    loadingText = L("Downloading playlist…")
                    val u = Net.urlValue(s.m3uURL) ?: throw Net.badURL()
                    val text = Net.text(u)
                    loadingText = L("Sorting channels and movies…")
                    lib = withContext(Dispatchers.Default) { M3UParser.library(text, s.id) }
                    val epg = Net.urlValue(s.epgURL) ?: M3UParser.epgURL(text)
                    if (epg != null) { loadingText = L("Loading TV guide…"); lib = lib.copy(epg = XMLTVParser.load(epg)) }
                }
                PlaylistKind.XTREAM -> {
                    loadingText = L("Signing in to server…")
                    val x = XtreamClient(s, password)
                    x.authenticate()
                    loadingText = L("Fetching live TV, movies and series…")
                    lib = x.library()
                    val epg = Net.urlValue(s.epgURL) ?: x.xmltvURL
                    if (epg != null) { loadingText = L("Loading TV guide…"); lib = lib.copy(epg = XMLTVParser.load(epg)) }
                }
                PlaylistKind.STALKER -> {
                    loadingText = L("Connecting to portal…")
                    val st = (if (source?.id == s.id) stalker else null) ?: StalkerClient(s)
                    st.connect()
                    loadingText = L("Fetching channels and videos…")
                    lib = st.library()
                    Net.urlValue(s.epgURL)?.let { lib = lib.copy(epg = XMLTVParser.load(it)) }
                }
                PlaylistKind.JELLYFIN, PlaylistKind.EMBY -> {
                    loadingText = L("Fetching your library…")
                    lib = JellyfinClient(s, session(s)).library()
                }
                PlaylistKind.PLEX -> {
                    loadingText = L("Fetching your library…")
                    var sess = session(s) ?: throw JellyfinClient.notLoggedIn
                    // server-adres kan veranderen: bij fout opnieuw zoeken
                    lib = try { PlexClient(sess).library() } catch (e: CancellationException) { throw e } catch (e: Exception) {
                        val userToken = Store.secret(s.passwordKey) ?: throw e
                        sess = PlexClient.discoverServer(userToken)
                        saveSession(s, sess)
                        PlexClient(sess).library()
                    }
                }
                PlaylistKind.STREMIO -> {
                    loadingText = L("Loading Stremio add-ons…")
                    val addons = loadStremioAddons(s)
                    if (source?.id == s.id) stremioAddons = addons
                    loadingText = L("Fetching catalogs…")
                    lib = StremioClient(addons).library()
                }
            }
            writeCache(s, lib)
            if (source?.id == s.id) {
                setRaw(lib)
                saveSplashPosters(lib)
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (source?.id == s.id && rawLibrary.isEmpty) error = Net.message(e)
        } finally {
            isLoading = false; loadingText = ""
        }
    }

    /** Bij terugkeren in de app: verversen als het volgens de instelling tijd is. */
    suspend fun refreshIfDue() {
        val s = source ?: return
        val policy = RefreshPolicy.current
        if (isLoading || policy == RefreshPolicy.MANUAL || !policy.isDue(cacheAge(s))) return
        refresh(s, showSpinner = false)
    }

    /** Alle afspeellijsten op de achtergrond verversen. */
    suspend fun refreshAll() {
        refreshingAll = true
        try { for (p in Store.playlists) refresh(p, showSpinner = false) } finally { refreshingAll = false }
    }

    // MARK: sessies (Plex / Jellyfin / Emby)

    fun sessionKey(p: PlaylistSource) = "playlist.${p.id}.session"
    fun session(p: PlaylistSource): ServerSession? =
        Store.secret(sessionKey(p))?.let { runCatching { Http.json.decodeFromString(ServerSession.serializer(), it) }.getOrNull() }
    private fun saveSession(p: PlaylistSource, s: ServerSession?) =
        Store.setSecret(sessionKey(p), s?.let { Http.json.encodeToString(ServerSession.serializer(), it) })

    suspend fun loadStremioAddons(s: PlaylistSource): List<StremioClient.Addon> {
        var urls = s.m3uURL.split('\n', ',', ' ').map { it.trim() }.filter { it.isNotEmpty() }
        val key = Store.secret(s.passwordKey)
        if (!key.isNullOrEmpty()) {
            runCatching { StremioClient.accountAddons(key) }.getOrNull()?.let { urls = it + urls }
        }
        if (urls.none { it.contains("cinemeta") }) urls = listOf(StremioClient.cinemeta) + urls
        val out = ArrayList<StremioClient.Addon>()
        for (u in urls.distinct()) StremioClient.loadAddon(u)?.let { out.add(it) }
        return out
    }

    // MARK: aanpassingen toepassen

    private fun setRaw(lib: Library) {
        rawLibrary = lib
        applyCustomizations()
    }

    /** Alles wat het filteren nodig heeft, als losse waarden — zodat het op de achtergrond kan (grote lijsten). */
    data class FilterContext(
        val custom: Customization,
        val playlist: String,
        val ageLimit: Int?,
        val strict: Boolean,
        val parentalEnabled: Boolean,
        val lockedGroups: Set<String>,
        val autoLockAdult: Boolean,
        val unlocked: Boolean,
    )

    /** Filtercontext voor deze bron en het actieve profiel (op de main thread aanroepen: leest Compose-state). */
    fun context(p: PlaylistSource): FilterContext {
        val prof = Store.activeProfile
        val pc = Store.parental
        return FilterContext(
            custom = Store.customization(p.id), playlist = p.id,
            ageLimit = prof?.effectiveAgeLimit, strict = prof?.strictAgeFilter ?: false,
            parentalEnabled = pc.enabled, lockedGroups = pc.lockedGroups, autoLockAdult = pc.autoLockAdult,
            unlocked = ParentalControl.isUnlocked,
        )
    }

    /**
     * Past aanpassingen, kinderslot en de leeftijdsgrens van het actieve profiel toe op [rawLibrary] → [library].
     * Grote lijsten worden op Dispatchers.Default gefilterd; bij een profiel met leeftijdsgrens is [library]
     * intussen leeg en [isFiltering] true.
     */
    fun applyCustomizations() {
        val s = source
        if (s == null) { filterJob?.cancel(); isFiltering = false; library = rawLibrary; return }
        val ctx = context(s)
        val raw = rawLibrary
        val gen = ++filterGeneration
        filterJob?.cancel()
        // kleine lijsten: meteen; grote lijsten: op de achtergrond
        if (raw.channels.size + raw.movies.size + raw.series.size < 3000) {
            library = apply(raw, ctx)
            isFiltering = false
            return
        }
        // kinderprofiel/leeftijdsgrens: niets ongefilterds laten zien terwijl er gefilterd wordt
        if (ctx.ageLimit != null) library = Library()
        isFiltering = true
        filterJob = AppScope.launch {
            val lib = withContext(Dispatchers.Default) { apply(raw, ctx) }
            if (gen != filterGeneration) return@launch   // intussen opnieuw gefilterd
            library = lib
            isFiltering = false
        }
    }

    /** Oude aanroep: filteren met de huidige kinderslot-instellingen (op de main thread). */
    fun apply(raw: Library, c: Customization, playlist: String, ageLimit: Int? = null, strict: Boolean = false): Library {
        val pc = Store.parental
        return apply(raw, FilterContext(c, playlist, ageLimit, strict, pc.enabled, pc.lockedGroups, pc.autoLockAdult,
            ParentalControl.isUnlocked))
    }

    /** Pure filterfunctie (veilig op de achtergrond; leest alleen de thread-veilige Metadata-cache). */
    fun apply(raw: Library, ctx: FilterContext): Library {
        val c = ctx.custom
        val playlist = ctx.playlist
        val ageLimit = ctx.ageLimit
        fun isLocked(g: String): Boolean {
            if (!ctx.parentalEnabled || ctx.unlocked) return false
            if ("$playlist|$g" in ctx.lockedGroups) return true
            return ctx.autoLockAdult && ParentalControl.isAdultGroup(g)
        }
        fun allowed(rated: String?, group: String, genre: String? = null): Boolean =
            ctx.unlocked || ParentalControl.allowedFor(rated, group, ageLimit, genre, ctx.strict)
        fun group(g: String): String {
            val merged = c.merged[g] ?: g
            return c.renamed[Customization.groupKey(merged)] ?: merged
        }
        // per groep één keer uitrekenen (tienduizenden titels delen maar een paar honderd groepen)
        val groupOK = HashMap<String, Boolean>()
        fun visible(id: String, g: String): Boolean {
            if (id in c.hidden) return false
            groupOK[g]?.let { return it }
            val m = c.merged[g] ?: g
            val ok = Customization.groupKey(g) !in c.hidden && Customization.groupKey(m) !in c.hidden &&
                !isLocked(g) && !isLocked(m)
            groupOK[g] = ok
            return ok
        }
        fun ageOK(md: TitleMetadata?, g: String): Boolean = ageLimit == null || allowed(md?.rated, g, md?.genre)

        var channels = raw.channels.filter { visible(it.id, it.group) }
            .map { ch -> ch.copy(group = group(ch.group), name = c.renamed[ch.id] ?: ch.name) }
        // kinderprofiel / leeftijdsgrens: geen volwassenen-zenders (streng: alleen kinderzenders)
        if (ageLimit != null) channels = channels.filter { allowed(null, it.group) }
        val movies = raw.movies.filter {
            visible(it.id, it.group) && (ageLimit == null || ageOK(Metadata.cached(it), it.group))
        }.map { m -> m.copy(group = group(m.group), title = c.renamed[m.id] ?: m.title) }
        val series = raw.series.filter {
            visible(it.id, it.group) && (ageLimit == null || ageOK(Metadata.cached(it), it.group))
        }.map { se -> se.copy(group = group(se.group), title = c.renamed[se.id] ?: se.title) }

        // eigen volgorde: groepen, dan kanalen binnen een groep
        if (c.groupOrder.isNotEmpty() || c.channelOrder.isNotEmpty()) {
            val gIndex = HashMap<String, Int>()
            c.groupOrder.forEachIndexed { i, g -> if (g !in gIndex) gIndex[g] = i }
            val natural = HashMap<String, Int>()
            channels.map { it.group }.distinct().forEachIndexed { i, g -> natural[g] = i + 10_000 }
            val cIndex = HashMap<String, Int>()
            for ((_, ids) in c.channelOrder) ids.forEachIndexed { i, id -> cIndex[id] = i }
            val original = HashMap<String, Int>()
            channels.forEachIndexed { i, ch -> if (ch.id !in original) original[ch.id] = i + 100_000 }
            channels = channels.sortedWith(Comparator { a, b ->
                val ga = gIndex[a.group] ?: natural[a.group] ?: 0
                val gb = gIndex[b.group] ?: natural[b.group] ?: 0
                if (ga != gb) ga.compareTo(gb)
                else (cIndex[a.id] ?: original[a.id] ?: 0).compareTo(cIndex[b.id] ?: original[b.id] ?: 0)
            })
        }
        return raw.copy(channels = channels, movies = movies, series = series)
    }

    // MARK: details

    suspend fun episodes(s: Series): List<Episode> {
        if (s.episodes.isNotEmpty()) return s.episodes
        episodeCache[s.id]?.let { return it }
        val src = source ?: return emptyList()
        val eps: List<Episode> = try {
            when (src.kind) {
                PlaylistKind.XTREAM -> XtreamClient(src, Store.secret(src.passwordKey) ?: "").episodes(s)
                PlaylistKind.JELLYFIN, PlaylistKind.EMBY -> JellyfinClient(src, session(src)).episodes(s)
                PlaylistKind.PLEX -> session(src)?.let { PlexClient(it).episodes(s) } ?: emptyList()
                PlaylistKind.STREMIO -> {
                    if (stremioAddons.isEmpty()) stremioAddons = loadStremioAddons(src)
                    StremioClient(stremioAddons).episodes(s)
                }
                else -> emptyList()
            }
        } catch (e: CancellationException) { throw e } catch (e: Exception) { emptyList() }
        episodeCache = episodeCache + (s.id to eps)
        return eps
    }

    /** Ruwe Xtream get_series_info (detailpagina). */
    suspend fun xtreamSeriesInfo(series: Series): JsonObject? {
        val s = source ?: return null
        val id = series.xtreamSeriesID ?: return null
        if (s.kind != PlaylistKind.XTREAM) return null
        return XtreamClient(s, Store.secret(s.passwordKey) ?: "").seriesInfo(id)
    }

    /** Xtream get_vod_info → "info" (detailpagina). */
    suspend fun xtreamVodInfo(m: Movie): JsonObject? {
        val s = source ?: return null
        val id = m.xtreamVodID ?: return null
        if (s.kind != PlaylistKind.XTREAM) return null
        return XtreamClient(s, Store.secret(s.passwordKey) ?: "").vodInfo(id)
    }

    /** Stremio: alle beschikbare streams voor een titel. */
    suspend fun stremioStreams(item: PlayableItem): List<StremioStream> {
        val ref = item.stremio ?: return emptyList()
        val s = source ?: return emptyList()
        if (stremioAddons.isEmpty()) stremioAddons = loadStremioAddons(s)
        val parts = ref.split("|", limit = 2)
        if (parts.size != 2) return emptyList()
        return StremioClient(stremioAddons).streams(parts[0], parts[1])
    }

    /** Geeft de echte afspeel-URL (Stalker maakt per keer een link aan, Stremio zoekt een stream). */
    suspend fun resolve(item: PlayableItem): String? {
        if (item.url != null && item.stalkerCmd == null) return item.url
        val cmd = item.stalkerCmd
        val st = stalker
        if (cmd != null && st != null) {
            val link = try {
                st.createLink(cmd, if (item.type == MediaType.LIVE) MediaType.LIVE else MediaType.MOVIE)
            } catch (e: CancellationException) { throw e } catch (e: Exception) { null }
            return link ?: item.url
        }
        if (item.stremio != null) return stremioStreams(item).firstOrNull()?.url
        return item.url
    }

    fun catchupURL(c: Channel, p: EPGProgram): String? = catchupURL(c.id, p.start, p.end)

    /** Terugkijken / timeshift vanaf een willekeurig moment (Xtream). */
    fun catchupURL(channelID: String, start: Long, end: Long): String? {
        val s = source ?: return null
        if (s.kind != PlaylistKind.XTREAM) return null
        val ch = rawLibrary.channels.firstOrNull { it.id == channelID } ?: return null
        if (ch.catchupDays <= 0) return null
        return XtreamClient(s, Store.secret(s.passwordKey) ?: "").catchupURL(ch, start, end)
    }

    suspend fun shortEPG(c: Channel): List<EPGProgram> {
        val st = stalker
        if (st != null && library.epg[c.epgID ?: c.id] == null) {
            val p = st.shortEPG(c.id)
            if (p.isNotEmpty()) {
                rawLibrary = rawLibrary.copy(epg = rawLibrary.epg + (c.id to p))
                library = library.copy(epg = library.epg + (c.id to p))
            }
            return p
        }
        return library.upcoming(c, count = 10)
    }

    // MARK: zoeken

    suspend fun search(q: String): SearchResults = search(q, allPlaylists = true)

    suspend fun search(q: String, allPlaylists: Boolean): SearchResults {
        val t = Net.fold(q.trim())
        if (t.length < 2) return SearchResults()
        val lib = library
        val currentID = source?.id
        val others = Store.playlists.filter { it.id != currentID }
        // andere afspeellijsten: zelfde verbergen/kinderslot/leeftijdsgrens als het actieve profiel
        val contexts = others.associate { it.id to context(it) }
        return withContext(Dispatchers.Default) {
            fun m(s: String) = Net.fold(s).contains(t)
            // films én series én zenders, uit álle categorieën
            val r = SearchResults(
                channels = lib.channels.asSequence().filter { m(it.name) }.take(60).toList(),
                movies = lib.movies.asSequence().filter { m(it.title) }.take(200).toList(),
                series = lib.series.asSequence().filter { m(it.title) }.take(200).toList(),
            )
            if (!allPlaylists) return@withContext r
            // zoeken in de cache van alle andere afspeellijsten
            val hits = ArrayList<OtherHit>()
            for (p in others) {
                val olib = withContext(Dispatchers.IO) { readCache(p) }?.let { raw ->
                    contexts[p.id]?.let { apply(raw, it) } ?: raw
                } ?: continue
                for (c in olib.channels) {
                    if (!m(c.name)) continue
                    hits.add(OtherHit(p, c.id, c.name, "Live TV", c.logo))
                    if (hits.size > 80) break
                }
                for (mv in olib.movies) if (m(mv.title)) hits.add(OtherHit(p, mv.id, mv.title, mv.year?.toString() ?: "", mv.poster))
                for (se in olib.series) if (m(se.title)) hits.add(OtherHit(p, se.id, se.title, se.year?.toString() ?: "", se.poster))
            }
            r.copy(other = hits.take(120))
        }
    }

    /** Dezelfde titel in andere groepen of andere afspeellijsten ("Andere bronnen"). */
    suspend fun otherSources(title: String, year: Int?, isShow: Boolean, excludingID: String): List<OtherHit> {
        val norm = Net.normTitle(title)
        if (norm.isEmpty()) return emptyList()
        val current = source
        val currentLib = library
        val all = Store.playlists
        val contexts = all.filter { it.id != current?.id }.associate { it.id to context(it) }
        return withContext(Dispatchers.Default) {
            val hits = ArrayList<OtherHit>()
            for (p in all) {
                val lib = if (p.id == current?.id) currentLib else {
                    val raw = withContext(Dispatchers.IO) { readCache(p) } ?: Library()
                    contexts[p.id]?.let { apply(raw, it) } ?: raw
                }
                if (isShow) {
                    for (s in lib.series) if (s.id != excludingID && Net.normTitle(s.title) == norm && (year == null || s.year == null || s.year == year))
                        hits.add(OtherHit(p, s.id, s.title, s.group, s.poster))
                } else {
                    for (m in lib.movies) if (m.id != excludingID && Net.normTitle(m.title) == norm && (year == null || m.year == null || m.year == year))
                        hits.add(OtherHit(p, m.id, m.title, m.group, m.poster))
                }
            }
            hits
        }
    }

    // MARK: toevoegen / testen

    /** Test de verbinding en bewaart geheimen (zie de uitleg bovenaan). null = gelukt, anders foutmelding. */
    suspend fun test(p: PlaylistSource, password: String): String? = try {
        validate(p, password); null
    } catch (e: CancellationException) { throw e } catch (e: Exception) { Net.message(e) }

    /** Als [test], maar geeft de (eventueel aangevulde) bron terug en gooit bij een fout. */
    suspend fun validate(p0: PlaylistSource, password: String): PlaylistSource {
        var p = p0
        when (p.kind) {
            PlaylistKind.M3U -> {
                val u = Net.urlValue(p.m3uURL) ?: throw Net.badURL()
                val r = Http.request(u, headers = mapOf("Range" to "bytes=0-2047"), raw = true)
                if (!r.ok) throw Net.statusError(r.code, "")
                val head = (r.bytes ?: ByteArray(0)).let { it.copyOf(minOf(it.size, 2048)) }.toString(Charsets.UTF_8)
                if (!head.contains("#EXT")) throw ServiceException(L("This doesn't look like a valid M3U playlist."))
                Store.setSecret(p.passwordKey, null)
            }
            PlaylistKind.XTREAM -> {
                XtreamClient(p, password).authenticate()
                Store.setSecret(p.passwordKey, password)
            }
            PlaylistKind.STALKER -> StalkerClient(p).connect()
            PlaylistKind.JELLYFIN, PlaylistKind.EMBY -> {
                val s = JellyfinClient(p, null).login(p.username, password)
                saveSession(p, s)
                Store.setSecret(p.passwordKey, null)     // wachtwoord niet bewaren, token wel
            }
            PlaylistKind.PLEX -> {
                if (password.isNotEmpty()) {
                    Store.setSecret(p.passwordKey, password)
                    val s = PlexClient.discoverServer(password)
                    saveSession(p, s)
                    p = p.copy(serverURL = s.serverURI)
                } else if (Store.secret(p.passwordKey) == null) {
                    throw JellyfinClient.notLoggedIn
                }
            }
            PlaylistKind.STREMIO -> {
                if (p.username.isNotEmpty() && password.isNotEmpty()) {
                    Store.setSecret(p.passwordKey, StremioClient.login(p.username, password))
                }
            }
        }
        clearCache(p)
        return p
    }

    /** Afspeellijst helemaal verwijderen (profiel, wachtwoord, sessie en cache). */
    fun forget(p: PlaylistSource) {
        Store.delete(p)
        clearCache(p)
        Store.setSecret(sessionKey(p), null)
    }

    // MARK: cache

    private fun cacheFile(p: PlaylistSource) = File(AppState.appContext.filesDir, "cache-${p.id}.json")

    /** Gecachete inhoud (blokkeert: aanroepen buiten de main thread). */
    fun readCache(p: PlaylistSource): Library? {
        val f = cacheFile(p)
        if (!f.exists()) return null
        return runCatching { Http.json.decodeFromString(Library.serializer(), f.readText()) }.getOrNull()
    }

    /** Leeftijd van de cache in ms (null = geen cache). */
    fun cacheAge(p: PlaylistSource): Long? {
        val f = cacheFile(p)
        if (!f.exists()) return null
        return System.currentTimeMillis() - f.lastModified()
    }

    private fun writeCache(p: PlaylistSource, lib: Library) {
        val f = cacheFile(p)
        AppScope.launch(Dispatchers.IO) {
            runCatching {
                val tmp = File(f.parentFile, f.name + ".tmp")
                tmp.writeText(Http.json.encodeToString(Library.serializer(), lib))
                if (!tmp.renameTo(f)) { f.delete(); tmp.renameTo(f) }
            }
        }
    }

    fun clearCache(p: PlaylistSource) { runCatching { cacheFile(p).delete() } }

    // MARK: posters voor de intro

    private const val splashKey = "splash.posters"

    /** Poster-URL's van films/series voor de splash (bewaard zodra een afspeellijst geladen is), geschud. */
    fun splashPosters(): List<String> = runCatching {
        Http.json.decodeFromString(ListSerializer(String.serializer()), Prefs.string(splashKey) ?: "[]")
    }.getOrDefault(emptyList()).shuffled()

    private fun saveSplashPosters(lib: Library) {
        val urls = (lib.movies.take(300).mapNotNull { it.poster } + lib.series.take(200).mapNotNull { it.poster }).shuffled()
        val list = urls.take(40)
        if (list.isEmpty()) return
        Prefs.put(splashKey, Http.json.encodeToString(list))
    }
}

/** Hoe vaak afspeellijsten (incl. gids) automatisch ververst worden. Prefs "playlist.refresh". */
enum class RefreshPolicy(val raw: String) {
    MANUAL("manual"), LAUNCH("launch"), SIX_HOURS("sixHours"), DAILY("daily"), WEEKLY("weekly");

    val title: String
        get() = when (this) {
            MANUAL -> L("Manually")
            LAUNCH -> L("Every time the app opens")
            SIX_HOURS -> L("Every 6 hours")
            DAILY -> L("Daily")
            WEEKLY -> L("Weekly")
        }

    /** [ageMs] = leeftijd van de cache in ms (null = geen cache). */
    fun isDue(ageMs: Long?): Boolean {
        val age = ageMs ?: return true
        return when (this) {
            MANUAL -> false
            LAUNCH -> age > 60_000
            SIX_HOURS -> age > 6 * 3_600_000L
            DAILY -> age > 24 * 3_600_000L
            WEEKLY -> age > 7 * 24 * 3_600_000L
        }
    }

    companion object {
        var current: RefreshPolicy
            get() = entries.firstOrNull { it.raw == Prefs.string("playlist.refresh") } ?: DAILY
            set(v) = Prefs.put("playlist.refresh", v.raw)
    }
}

data class SearchResults(
    val channels: List<Channel> = emptyList(),
    val movies: List<Movie> = emptyList(),
    val series: List<Series> = emptyList(),
    val other: List<OtherHit> = emptyList(),
) {
    val isEmpty: Boolean get() = channels.isEmpty() && movies.isEmpty() && series.isEmpty() && other.isEmpty()
}

/** Treffer in een andere afspeellijst. */
data class OtherHit(val playlist: PlaylistSource, val itemID: String, val title: String, val subtitle: String, val artwork: String?) {
    val id: String get() = "${playlist.id}-$itemID"
}

data class StremioStream(val title: String, val addon: String, val url: String)
