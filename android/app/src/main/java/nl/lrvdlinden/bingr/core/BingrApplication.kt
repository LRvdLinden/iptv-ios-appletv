package nl.lrvdlinden.bingr

import android.app.Application
import android.app.UiModeManager
import android.content.Context
import android.content.res.Configuration
import android.content.pm.PackageManager

class BingrApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        AppState.appContext = applicationContext
        Prefs.init(this)
        Store.init(this)
        Localizer.init(this)
        val ui = getSystemService(Context.UI_MODE_SERVICE) as UiModeManager
        AppState.isTV = ui.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK) ||
            !packageManager.hasSystemFeature(PackageManager.FEATURE_TOUCHSCREEN)
        Reminders.createChannel(this)
    }
}
