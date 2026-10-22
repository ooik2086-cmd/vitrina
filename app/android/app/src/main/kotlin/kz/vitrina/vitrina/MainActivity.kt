package kz.vitrina.vitrina

import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.webviewflutter.WebViewFlutterAndroidExternalApi

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
