package nl.lrvdlinden.bingr

import android.app.PictureInPictureParams
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.util.Rational
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.core.view.WindowCompat

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        WindowCompat.setDecorFitsSystemWindows(window, false)
        current = this
        setContent { BingrTheme { BingrRoot() } }
        if (Build.VERSION.SDK_INT >= 33) {
            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 1)
        }
    }

    override fun onDestroy() { if (current === this) current = null; super.onDestroy() }

    /** Naar het beginscherm terwijl er iets speelt → beeld-in-beeld (telefoon/tablet). */
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (!AppState.isTV && AppState.playing != null && PlayerController.current?.isPlaying == true) enterPiP()
    }

    fun enterPiP(): Boolean {
        if (Build.VERSION.SDK_INT < 26) return false
        return runCatching {
            enterPictureInPictureMode(PictureInPictureParams.Builder().setAspectRatio(Rational(16, 9)).build())
        }.getOrDefault(false)
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        AppState.inPiP = isInPictureInPictureMode
        // venster dichtgeveegd → stoppen
        if (!isInPictureInPictureMode && lifecycle.currentState == androidx.lifecycle.Lifecycle.State.CREATED) {
            PlayerController.current?.stop(); AppState.playing = null
        }
    }

    /** Scherm aan laten tijdens afspelen */
    fun keepScreenOn(on: Boolean) {
        if (on) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    companion object { var current: MainActivity? = null }
}
