import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'net_image_io.dart' show KeptImage;

/// Serves the 3D stage's page and the shoes' models to the stage's WebView, on this phone only (127.0.0.1), under a
/// random path no other app can guess. A model is fetched once and kept in the app's cache folder, so a shoe seen
/// before opens without mobile data; the WebView reads it from here, never from the network itself.
class ViewerHost {
  ViewerHost._(this._server, this._secret);

  final HttpServer _server;
  final String _secret;

  static Future<ViewerHost?>? _started;

  /// The one host of this app run; null where it cannot start (no network stack, tests without a phone).
  static Future<ViewerHost?> get instance => _started ??= _start();

  static Future<ViewerHost?> _start() async {
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final random = Random.secure();
      final secret = List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      final host = ViewerHost._(server, secret);
      server.listen(host._answer, onError: (Object e) => debugPrint('viewer host: $e'));
      return host;
    } catch (e) {
      debugPrint('viewer host could not start: $e');
      return null;
    }
  }

  /// The stage's page.
  Uri get page => Uri.parse('http://127.0.0.1:${_server.port}/$_secret/index.html');

  /// Where the page reads the model kept for [url]; only https addresses of public models are served.
  String modelAt(String url) {
    final name = KeptImage.nameOf(url);
    _models[name] = url;
    return 'http://127.0.0.1:${_server.port}/$_secret/m/$name.glb';
  }

  final _models = <String, String>{};
  final _fetching = <String, Future<File?>>{};

  /// Starts fetching the model for [url] now, while the stage's page is still opening, so its 3D comes sooner.
  void warm(String url) => unawaited(_kept(url));

  /// The model for [url] is being fetched and its bytes kept coming lately: on weak internet the stage waits on
  /// past its patience for a model still arriving, rather than give up on it.
  bool arriving(String url) {
    final heard = _heard[Uri.tryParse(url).toString()];
    return _fetching.containsKey(KeptImage.nameOf(url)) &&
        heard != null &&
        DateTime.now().difference(heard) < const Duration(seconds: 8);
  }

  /// When each model's fetch last received bytes.
  static final _heard = <String, DateTime>{};

  /// Kept models stay under [limit] bytes, the least recently opened going first (as photos are kept).
  static const limit = 96 * 1024 * 1024;

  static const _assets = {'index.html': 'text/html; charset=utf-8', 'viewer.js': 'text/javascript; charset=utf-8'};

  Future<void> _answer(HttpRequest request) async {
    final response = request.response;
    try {
      final parts = request.uri.pathSegments;
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      if (request.method != 'GET' || parts.length < 2 || parts.first != _secret) {
        response.statusCode = HttpStatus.notFound;
      } else if (parts.length == 2 && _assets.containsKey(parts[1])) {
        // The script is the app's own and only changes with the app (the secret path changes every run): the WebView
        // may keep it, and its compiled code, between the listings opened in this run.
        if (parts[1] == 'viewer.js') response.headers.set(HttpHeaders.cacheControlHeader, 'private, max-age=86400');
        final bytes = await rootBundle.load('assets/viewer/${parts[1]}');
        response.headers.set(HttpHeaders.contentTypeHeader, _assets[parts[1]]!);
        response.add(bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes));
      } else if (parts.length == 3 && parts[1] == 'm' && parts[2].endsWith('.glb')) {
        final url = _models[parts[2].substring(0, parts[2].length - 4)];
        final file = url == null ? null : await _kept(url);
        if (file == null) {
          response.statusCode = url == null ? HttpStatus.notFound : HttpStatus.badGateway;
        } else {
          response.headers.set(HttpHeaders.contentTypeHeader, 'model/gltf-binary');
          response.headers.contentLength = await file.length();
          await response.addStream(file.openRead());
        }
      } else {
        response.statusCode = HttpStatus.notFound;
      }
    } catch (e) {
      debugPrint('viewer host: ${request.uri.path}: $e');
      try {
        response.statusCode = HttpStatus.internalServerError;
      } catch (_) {} // the headers were sent already
    }
    try {
      await response.close();
    } catch (_) {}
  }

  /// The model kept for [url], fetched first when it is not kept yet; one fetch at a time per model.
  Future<File?> _kept(String url) {
    final name = KeptImage.nameOf(url);
    // A block body: remove() returns this very future, which whenComplete would otherwise wait for, forever.
    return _fetching[name] ??= _keep(url, name).whenComplete(() {
      _fetching.remove(name);
    });
  }

  static final HttpClient _client = HttpClient()..connectionTimeout = const Duration(seconds: 20);

  /// Fetches the models; tests replace it.
  @visibleForTesting
  static Future<Uint8List> Function(Uri uri) fetch = _fetch;

  /// A model larger than this is not a shoe made for a phone: it is not fetched (the photos show instead).
  static const largest = 24 * 1024 * 1024;

  /// A fetch that has received nothing for this long has stalled (a dead 3G link): it is dropped, so the stage shows
  /// the photos and the next open of the shoe tries again, instead of waiting on it for the rest of the app run.
  @visibleForTesting
  static Duration stall = const Duration(seconds: 20);

  static Future<Uint8List> _fetch(Uri uri) async {
    final key = uri.toString();
    _heard[key] = DateTime.now();
    try {
      final response = await (await _client.getUrl(uri)).close().timeout(stall);
      if (response.statusCode != HttpStatus.ok || response.contentLength > largest) {
        await response.drain<List<int>>(<int>[]).timeout(stall).catchError((_) => <int>[]);
        throw HttpException('model ${response.statusCode}, ${response.contentLength} bytes', uri: uri);
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(stall)) {
        _heard[key] = DateTime.now();
        bytes.add(chunk);
        if (bytes.length > largest) throw HttpException('model over $largest bytes', uri: uri);
      }
      return bytes.takeBytes();
    } finally {
      _heard.remove(key);
    }
  }

  /// Removes cut-off writes, then the least recently opened models once the folder is past [limit].
  static Future<void> _trim(Directory dir) async {
    try {
      final files = <(File, FileStat)>[];
      await for (final e in dir.list()) {
        if (e is! File) continue;
        final stat = await e.stat();
        if (e.path.endsWith('.part')) {
          if (DateTime.now().difference(stat.modified) > const Duration(minutes: 10)) await e.delete();
        } else {
          files.add((e, stat));
        }
      }
      var total = files.fold<int>(0, (sum, f) => sum + f.$2.size);
      files.sort((x, y) => x.$2.modified.compareTo(y.$2.modified));
      for (final (file, stat) in files) {
        if (total <= limit) break;
        await file.delete();
        total -= stat.size;
      }
    } catch (_) {}
  }

  static Future<File?> _keep(String url, String name) async {
    final uri = Uri.tryParse(url);
    // https only, as the server takes them; plain http only from a debug build's local dev server.
    if (uri == null || !(uri.scheme == 'https' || (kDebugMode && uri.scheme == 'http'))) return null;
    try {
      final dir = Directory('${(await getApplicationCacheDirectory()).path}/models');
      await dir.create(recursive: true);
      final file = File('${dir.path}/$name.glb');
      if (await file.exists() && await file.length() > 0) {
        unawaited(file.setLastModified(DateTime.now()).catchError((_) {}));
        return file;
      }
      final bytes = await fetch(uri);
      // glTF binary starts with "glTF": anything else (an error page) is not kept.
      if (bytes.length < 12 || String.fromCharCodes(bytes.sublist(0, 4)) != 'glTF') return null;
      final part = File('${file.path}.$pid.part');
      try {
        await part.writeAsBytes(bytes, flush: true);
        await part.rename(file.path);
      } catch (e) {
        // Not kept (the phone is full): the half-written file goes, and the next open fetches it again.
        await part.delete().catchError((_) => part);
        rethrow;
      }
      unawaited(_trim(dir));
      return file;
    } catch (e) {
      debugPrint('model $url: $e');
      return null;
    }
  }
}
