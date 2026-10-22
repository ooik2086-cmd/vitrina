/// On the web there is no 3D stage: a listing shows its photos.
class ViewerHost {
  static Future<ViewerHost?> get instance async => null;

  Uri get page => throw UnsupportedError('no 3D stage on the web');

  String modelAt(String url) => throw UnsupportedError('no 3D stage on the web');

  void warm(String url) {}

  bool arriving(String url) => false;
}
