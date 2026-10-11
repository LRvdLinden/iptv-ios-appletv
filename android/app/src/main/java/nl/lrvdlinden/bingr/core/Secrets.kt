package nl.lrvdlinden.bingr

/**
 * App-sleutels (zelfde als iOS): ingebouwd via GitHub Secrets → BuildConfig,
 * of zelf ingevuld in de app (Mijn Bingr → Koppelingen instellen) en dan in [Store.secret].
 */
object Secrets {
    enum class Key(val builtIn: () -> String) {
        TRAKT_CLIENT_ID({ BuildConfig.TRAKT_CLIENT_ID }),
        TRAKT_CLIENT_SECRET({ BuildConfig.TRAKT_CLIENT_SECRET }),
        OPENSUBTITLES_API_KEY({ BuildConfig.OPENSUBTITLES_API_KEY }),
        OMDB_API_KEY({ BuildConfig.OMDB_API_KEY }),
        TMDB_API_KEY({ BuildConfig.TMDB_API_KEY }),
    }

    fun value(k: Key): String = Store.secret("apikey.${k.name}")?.takeIf { it.isNotBlank() } ?: k.builtIn()
    fun set(k: Key, v: String) = Store.setSecret("apikey.${k.name}", v.trim().ifEmpty { null })

    val traktClientID get() = value(Key.TRAKT_CLIENT_ID)
    val traktClientSecret get() = value(Key.TRAKT_CLIENT_SECRET)
    val openSubtitlesAPIKey get() = value(Key.OPENSUBTITLES_API_KEY)
    val omdbAPIKey get() = value(Key.OMDB_API_KEY)
    val tmdbAPIKey get() = value(Key.TMDB_API_KEY)

    /** Nieuwe Trakt-apps hebben alleen een Client ID (PKCE). */
    val traktReady get() = isSet(traktClientID)
    val openSubtitlesReady get() = isSet(openSubtitlesAPIKey)

    fun isSet(v: String) = v.isNotBlank() && !v.startsWith("VUL_")
}
