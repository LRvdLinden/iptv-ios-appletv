package nl.lrvdlinden.bingr

import android.content.Context
import android.content.SharedPreferences

/** Kleine sleutel-waardeopslag (instellingen, caches). */
object Prefs {
    private lateinit var sp: SharedPreferences
    fun init(ctx: Context) { sp = ctx.getSharedPreferences("bingr", Context.MODE_PRIVATE) }
    fun string(k: String): String? = sp.getString(k, null)
    fun put(k: String, v: String?) { sp.edit().apply { if (v == null) remove(k) else putString(k, v) }.apply() }
    fun bool(k: String, def: Boolean = false) = sp.getBoolean(k, def)
    fun put(k: String, v: Boolean) { sp.edit().putBoolean(k, v).apply() }
    fun int(k: String, def: Int = 0) = sp.getInt(k, def)
    fun put(k: String, v: Int) { sp.edit().putInt(k, v).apply() }
    fun long(k: String, def: Long = 0) = sp.getLong(k, def)
    fun put(k: String, v: Long) { sp.edit().putLong(k, v).apply() }
}
