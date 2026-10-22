package kz.vitrina.vitrina;

import android.graphics.Bitmap;
import android.net.http.SslError;
import android.os.Build;
import android.os.Message;
import android.view.KeyEvent;
import android.webkit.ClientCertRequest;
import android.webkit.HttpAuthHandler;
import android.webkit.RenderProcessGoneDetail;
import android.webkit.SslErrorHandler;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import androidx.annotation.RequiresApi;

/**
 * Wraps the 3D stage WebView's own client (webview_flutter's), passing every call on, and answers the one it leaves
 * out: when Android stops the page's process (low memory), the app is told and shows the photos instead. Left
 * unanswered, Android closes the whole app.
 */
@RequiresApi(Build.VERSION_CODES.O)
final class RendererGuard extends WebViewClient {
  private final WebViewClient inner;
  private final Runnable onGone;

  RendererGuard(WebViewClient inner, Runnable onGone) {
    this.inner = inner;
    this.onGone = onGone;
  }

  @Override
  public boolean onRenderProcessGone(WebView view, RenderProcessGoneDetail detail) {
    onGone.run();
    return true; // the app stops using this WebView: the stage drops it and shows the photos
  }

  @Override
  public void onPageStarted(WebView view, String url, Bitmap favicon) {
    inner.onPageStarted(view, url, favicon);
  }

  @Override
  public void onPageFinished(WebView view, String url) {
    inner.onPageFinished(view, url);
  }

  @Override
  public void onReceivedHttpError(WebView view, WebResourceRequest request, WebResourceResponse response) {
    inner.onReceivedHttpError(view, request, response);
  }

  @Override
  public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
    inner.onReceivedError(view, request, error);
  }

  @Override
  public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
    return inner.shouldOverrideUrlLoading(view, request);
  }

  @Override
  public void doUpdateVisitedHistory(WebView view, String url, boolean isReload) {
    inner.doUpdateVisitedHistory(view, url, isReload);
  }

  @Override
  public void onReceivedHttpAuthRequest(WebView view, HttpAuthHandler handler, String host, String realm) {
    inner.onReceivedHttpAuthRequest(view, handler, host, realm);
  }

  @Override
  public void onFormResubmission(WebView view, Message dontResend, Message resend) {
    inner.onFormResubmission(view, dontResend, resend);
  }

  @Override
  public void onLoadResource(WebView view, String url) {
    inner.onLoadResource(view, url);
  }

  @Override
  public void onPageCommitVisible(WebView view, String url) {
    inner.onPageCommitVisible(view, url);
  }

  @Override
  public void onReceivedClientCertRequest(WebView view, ClientCertRequest request) {
    inner.onReceivedClientCertRequest(view, request);
  }

  @Override
  public void onReceivedLoginRequest(WebView view, String realm, String account, String args) {
    inner.onReceivedLoginRequest(view, realm, account, args);
  }

  @Override
  public void onReceivedSslError(WebView view, SslErrorHandler handler, SslError error) {
    inner.onReceivedSslError(view, handler, error);
  }

  @Override
  public void onScaleChanged(WebView view, float oldScale, float newScale) {
    inner.onScaleChanged(view, oldScale, newScale);
  }

  @Override
  public void onUnhandledKeyEvent(WebView view, KeyEvent event) {
    inner.onUnhandledKeyEvent(view, event);
  }
}
