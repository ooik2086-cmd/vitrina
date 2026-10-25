package kz.vitrina.vitrina

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.webviewflutter.WebViewFlutterAndroidExternalApi

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // The channels the alerts arrive in (vitrina_api/push.py), named in the phone's language in its settings.
        // Made again on every start: Android keeps the person's own choices for them, only the names follow the
        // phone's language. Messages and orders ring and pop up; news and tips come quietly.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            for (c in listOf(
                Channel("vitrina_alerts", R.string.alerts_channel, R.string.alerts_channel_about,
                        NotificationManager.IMPORTANCE_HIGH),
                Channel("vitrina_news", R.string.news_channel, R.string.news_channel_about,
                        NotificationManager.IMPORTANCE_LOW))) {
                val channel = NotificationChannel(c.id, getString(c.name), c.importance)
                channel.description = getString(c.about)
                manager.createNotificationChannel(channel)
            }
        }
    }

    private data class Channel(val id: String, val name: Int, val about: Int, val importance: Int)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // The phone's own page of this app's notifications: where alerts the phone refused are turned on (push.dart).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vitrina/push").setMethodCallHandler { call, result ->
            if (call.method != "openSettings") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
            } else {
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null))
            }
            startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            result.success(true)
        }
        // The 3D stage asks for its WebView to be guarded (RendererGuard) and hears on the same channel when its page
        // process is gone.
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vitrina/webview")
        channel.setMethodCallHandler { call, result ->
            if (call.method != "guard") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val id = (call.arguments as Number).toLong()
            @Suppress("DEPRECATION")
            val view = WebViewFlutterAndroidExternalApi.getWebView(flutterEngine, id)
            if (view == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                result.success(false)
                return@setMethodCallHandler
            }
            view.webViewClient = RendererGuard(view.webViewClient) { channel.invokeMethod("gone", id) }
            result.success(true)
        }
    }
}
