import 'demo.dart' show carriedAsset;

/// In a browser the 3D stage's page and the models come from the app's own site: the page is a frame there, and a
/// model carried inside the app is read from its asset address.
class ViewerHost {
  ViewerHost._();

  static final _one = ViewerHost._();

  static Future<ViewerHost?> get instance async => _one;

  /// The stage's page made for a frame (it talks to the app by window messages).
  Uri get page => Uri.base.resolve('assets/assets/viewer/web.html');

  String modelAt(String url) {
    final asset = carriedAsset(url);
    return asset == null ? url : Uri.base.resolve('assets/$asset').toString();
  }

  /// The browser fetches and keeps the model itself.
  void warm(String url) {}

  bool arriving(String url) => false;
}
