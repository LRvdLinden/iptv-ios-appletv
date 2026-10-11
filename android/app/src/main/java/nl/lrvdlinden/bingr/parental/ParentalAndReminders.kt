package nl.lrvdlinden.bingr

import android.annotation.SuppressLint
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/** Kinderslot: pincode (in Store.secret), groepen op slot, sessie-ontgrendeling, leeftijdsfilter per profiel. */
object ParentalControl {
    /** Ontgrendeld tot (epoch-ms) */
    var unlockedUntil by mutableStateOf<Long?>(null); private set

    private const val PIN_KEY = "parental.pin"
    private val adultWords = listOf("adult", "xxx", "18+", "+18", "porn", "erotic", "erotiek", "for adults")

    val hasPIN: Boolean get() = Store.secret(PIN_KEY) != null
    val isUnlocked: Boolean get() = (unlockedUntil ?: 0L) > System.currentTimeMillis()

    fun setPIN(pin: String?) = Store.setSecret(PIN_KEY, pin)

    fun verify(pin: String): Boolean {
        val stored = Store.secret(PIN_KEY) ?: return false
        if (stored != pin) return false
        unlockedUntil = System.currentTimeMillis() + 30 * 60_000L   // 30 min ontgrendeld
        return true
    }

    fun lock() { unlockedUntil = null }

    /** Is deze groep op slot (en dus verborgen tot ontgrendeling)? */
    fun isLocked(playlist: String, group: String): Boolean {
        val s = Store.parental
        if (!s.enabled || isUnlocked) return false
        if ("$playlist|$group" in s.lockedGroups) return true
        if (s.autoLockAdult) return isAdultGroup(group)
        return false
    }

    fun toggleLock(playlist: String, group: String) {
        val k = "$playlist|$group"
        Store.updateParental { s ->
            s.copy(lockedGroups = if (k in s.lockedGroups) s.lockedGroups - k else s.lockedGroups + k)
        }
    }

    // MARK: leeftijdsfilter per profiel

    val ageChoices = listOf(6, 9, 12, 16)

    /** Is deze groepsnaam duidelijk voor volwassenen? */
    fun isAdultGroup(g: String): Boolean {
        val l = g.lowercase()
        return adultWords.any { l.contains(it) }
    }

    private val ageTable = mapOf(
        "G" to 0, "TV-Y" to 0, "TV-G" to 0, "AL" to 0, "U" to 0, "ALL" to 0, "APPROVED" to 0, "PASSED" to 0,
        "TV-Y7" to 7, "TV-Y7-FV" to 7, "PG" to 9, "TV-PG" to 10, "UC" to 0,
        "PG-13" to 13, "TV-14" to 14, "12A" to 12, "M" to 15, "MA15+" to 15,
        "R" to 17, "TV-MA" to 17, "NC-17" to 18, "X" to 18, "R18+" to 18, "18" to 18,
    )

    /** Minimumleeftijd uit een classificatie (IMDb/OMDb "Rated": PG-13, TV-MA, 16, …). null = onbekend. */
    fun minimumAge(rated: String?): Int? {
        val r = rated?.uppercase()?.trim() ?: return null
        if (r.isEmpty() || r == "N/A" || r == "NOT RATED" || r == "UNRATED") return null
        ageTable[r]?.let { return it }
        val n = r.filter { it.isDigit() }.toIntOrNull() ?: return null
        return if (n <= 21) n else null
    }

    /** Mag dit profiel dit zien? (Onbekende classificatie = toegestaan, behalve in volwassenengroepen.) */
    fun allowed(rated: String?, group: String, limit: Int?): Boolean {
        if (limit == null || isUnlocked) return true
        if (isAdultGroup(group)) return false
        val age = minimumAge(rated)
        if (age != null && age > limit) return false
        return true
    }
}

/**
 * Herinneringen voor programma's: melding 2 minuten voor de start (AlarmManager + [ReminderReceiver]).
 * Op TV verschijnen meldingen niet altijd: [due] is dan het herinneringsbanner-signaal in de app
 * (start met [startChecking], zoals ReminderCenter op Apple TV).
 */
object Reminders {
    const val CHANNEL_ID = "reminders"
    const val EXTRA_ID = "reminderID"
    const val EXTRA_TITLE = "title"
    const val EXTRA_CHANNEL_NAME = "channelName"
    const val EXTRA_ITEM_ID = "itemID"
    const val EXTRA_PLAYLIST_ID = "playlistID"

    /** Herinnering die nu begint (voor een banner in de app); zet terug op null na tonen. */
    var due by mutableStateOf<ProgramReminder?>(null)
    private var checker: Job? = null

    private fun ensureChannel(ctx: Context) {
        if (Build.VERSION.SDK_INT >= 26) {
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val ch = NotificationChannel(CHANNEL_ID, L("Reminders"), NotificationManager.IMPORTANCE_HIGH)
            nm.createNotificationChannel(ch)
        }
    }

    /** Bij het starten van de app (BingrApplication): meldingskanaal + alarmen opnieuw plannen. */
    fun createChannel(ctx: Context) {
        ensureChannel(ctx)
        // na een herstart van het toestel zijn alarmen weg: toekomstige herinneringen opnieuw plannen
        runCatching { Store.reminders.filter { it.start > System.currentTimeMillis() }.forEach { schedule(ctx, it) } }
    }

    fun add(channel: Channel, program: EPGProgram, playlistID: String) {
        val r = ProgramReminder(id = "${channel.id}-${program.start / 1000}", playlistID = playlistID,
            channelID = channel.id, channelName = channel.name, title = program.title, start = program.start)
        Store.addReminder(r)
        schedule(AppState.appContext, r)
    }

    fun remove(id: String) {
        Store.removeReminder(id)
        val ctx = AppState.appContext
        val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        am.cancel(pending(ctx, ProgramReminder(id = id, playlistID = "", channelID = "", channelName = "", title = "", start = 0)))
    }

    private fun pending(ctx: Context, r: ProgramReminder): PendingIntent {
        val i = Intent(ctx, ReminderReceiver::class.java).apply {
            action = "nl.lrvdlinden.bingr.REMINDER.${r.id}"
            putExtra(EXTRA_ID, r.id)
            putExtra(EXTRA_TITLE, r.title)
            putExtra(EXTRA_CHANNEL_NAME, r.channelName)
            putExtra(EXTRA_ITEM_ID, r.channelID)
            putExtra(EXTRA_PLAYLIST_ID, r.playlistID)
        }
        return PendingIntent.getBroadcast(ctx, r.id.hashCode(), i,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    private fun schedule(ctx: Context, r: ProgramReminder) {
        val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val fire = maxOf(r.start - 120_000L, System.currentTimeMillis() + 1_000L)
        val pi = pending(ctx, r)
        val exactAllowed = if (Build.VERSION.SDK_INT >= 31) am.canScheduleExactAlarms() else true
        try {
            if (exactAllowed) am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, fire, pi)
            else am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, fire, pi)
        } catch (_: SecurityException) {
            runCatching { am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, fire, pi) }
        }
    }

    /** In-app controle elke 20 s (TV): zet [due] als een herinnering (bijna) begint. */
    fun startChecking() {
        checker?.cancel()
        checker = AppScope.launch {
            while (isActive) {
                val now = System.currentTimeMillis()
                Store.reminders.firstOrNull { it.start <= now + 60_000 && it.start > now - 300_000 }?.let { r ->
                    due = r
                    Store.removeReminder(r.id)
                }
                delay(20_000)
            }
        }
    }

    /** Toont de melding (aangeroepen door [ReminderReceiver]). */
    @SuppressLint("MissingPermission")
    fun showNotification(ctx: Context, intent: Intent) {
        val id = intent.getStringExtra(EXTRA_ID) ?: return
        val title = intent.getStringExtra(EXTRA_TITLE) ?: ""
        val channelName = intent.getStringExtra(EXTRA_CHANNEL_NAME) ?: ""
        ensureChannel(ctx)
        val open = Intent(ctx, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(EXTRA_ITEM_ID, intent.getStringExtra(EXTRA_ITEM_ID))
            putExtra(EXTRA_PLAYLIST_ID, intent.getStringExtra(EXTRA_PLAYLIST_ID))
        }
        val contentIntent = PendingIntent.getActivity(ctx, id.hashCode(), open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val n = NotificationCompat.Builder(ctx, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_popup_reminder)
            .setContentTitle(title)
            .setContentText(L("Starts in 2 minutes on %@", channelName))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setAutoCancel(true)
            .setContentIntent(contentIntent)
            .build()
        val nm = NotificationManagerCompat.from(ctx)
        if (nm.areNotificationsEnabled()) runCatching { nm.notify(id.hashCode(), n) }
        // ook in de app laten zien (TV / app open)
        Store.reminders.firstOrNull { it.id == id }?.let { due = it }
        Store.removeReminder(id)
    }
}

/** Ontvangt het alarm van een herinnering en toont de melding; tikken opent de app op die zender. */
class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Reminders.showNotification(context, intent)
    }
}
