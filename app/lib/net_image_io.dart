import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';

NetworkImage keptImage(String url) => KeptImage(url);

/// A [NetworkImage] whose bytes are also written to the app's cache folder and read from there next time.
/// It is a NetworkImage to everything that looks at it (the image cache, tests asking for the address), at the cost
/// of following that class's members as Flutter changes them.
@immutable
class KeptImage extends ImageProvider<NetworkImage> implements NetworkImage {
  const KeptImage(this.url);

  @override
  final String url;

  @override
  double get scale => 1;

  @override
  Map<String, String>? get headers => null;

  @override
  WebHtmlElementStrategy get webHtmlElementStrategy => WebHtmlElementStrategy.never;

  /// The folder photos are kept in; null where there is none (tests without the plugin), and then nothing is kept.
  @visibleForTesting
  static Future<Directory?> Function() folder = _cacheFolder;

  /// Fetches a photo's bytes, telling [progress] as they arrive; tests replace it.
  @visibleForTesting
  static Future<Uint8List> Function(Uri uri, void Function(int received, int? total) progress) fetch = _fetch;

  /// Kept photos stay under [limit] bytes: past it the ones least recently shown go, down to three quarters.
  static const limit = 256 * 1024 * 1024;

  // The folder itself, not a Future of it: a Future made once and awaited later runs its callbacks in the zone it was
  // made in, which in widget tests is a finished test's fake time.
  static bool _known = false;
  static Directory? _dir;

  /// Bytes written since the folder was last measured; past an eighth of [limit] it is measured and trimmed again,
  /// so a long session cannot grow it without bound.
  static int _written = 0;
  static Future<void>? _trimming;

  /// Forgets the folder so the next photo asks [folder] again; for tests.
  @visibleForTesting
  static Future<void> reset() async {
    await _trimming;
    _known = false;
    _dir = null;
    _written = 0;
  }

  static Future<Directory?> _cacheFolder() async {
    try {
      final dir = Directory('${(await getApplicationCacheDirectory()).path}/photos');
      await dir.create(recursive: true);
      return dir;
    } catch (_) {
      return null;
    }
  }

  static Future<Directory?> _ready() async {
    if (_known) return _dir;
    final dir = await folder();
    if (!_known) {
      _known = true;
      _dir = dir;
      // Once a start, after the first photo: it never holds the photo up.
      if (dir != null) Timer(const Duration(seconds: 5), () => _trim(dir));
    }
    return _dir;
  }

  static void _trim(Directory dir) => _trimming ??= trim(dir).whenComplete(() => _trimming = null);

  static final HttpClient _client = HttpClient()..autoUncompress = false;

  static Future<Uint8List> _fetch(Uri uri, void Function(int received, int? total) progress) async {
    final response = await (await _client.getUrl(uri)).close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<List<int>>(<int>[]);
      throw NetworkImageLoadException(statusCode: response.statusCode, uri: uri);
    }
    return consolidateHttpClientResponseBytes(response, onBytesReceived: progress);
  }

  /// The file name for [url]: two different 64-bit FNV-1a hashes of it, so two addresses never share a file. The 3D
  /// models (ViewerHost) are named the same way.
  static String nameOf(String url) {
    var a = 0xcbf29ce484222325, b = 0x84222325cbf29ce4;
    for (final unit in url.codeUnits) {
      a = (a ^ unit) * 0x100000001b3;
      b = (b ^ (unit + 0x9e)) * 0x100000001b3;
    }
    // In halves: a 64-bit int past 2^63 prints with a minus sign.
    String half(int v) => (v & 0xffffffff).toRadixString(16).padLeft(8, '0');
    String hex(int v) => '${half(v >> 32)}${half(v)}';
    return '${hex(a)}${hex(b)}';
  }

  /// Removes writes cut off by a killed app, then the least recently shown photos once the folder is past [max].
  @visibleForTesting
  static Future<void> trim(Directory dir, {int max = limit}) async {
    _written = 0;
    try {
      final now = DateTime.now();
      final files = <(File, FileStat)>[];
      await for (final e in dir.list()) {
        if (e is! File) continue;
        final stat = await e.stat();
        if (e.path.endsWith('.part')) {
          if (now.difference(stat.modified) > const Duration(minutes: 10)) await _delete(e);
          continue;
        }
        files.add((e, stat));
      }
      var total = files.fold<int>(0, (sum, f) => sum + f.$2.size);
      if (total <= max) return;
      files.sort((x, y) => x.$2.modified.compareTo(y.$2.modified));
      for (final (file, stat) in files) {
        if (total <= max * 3 ~/ 4) break;
        await _delete(file);
        total -= stat.size;
      }
    } catch (_) {}
  }

  static Future<void> _delete(File file) async {
    try {
      await file.delete();
    } catch (_) {}
  }

  @override
  Future<NetworkImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture<NetworkImage>(this);

  @override
  ImageStreamCompleter loadImage(NetworkImage key, ImageDecoderCallback decode) => _completer(decode);

  // NetworkImage still declares it; Flutter itself calls loadImage.
  @override
  // ignore: deprecated_member_use
  ImageStreamCompleter loadBuffer(NetworkImage key, DecoderBufferCallback decode) => _completer(decode);

  ImageStreamCompleter _completer(Future<ui.Codec> Function(ui.ImmutableBuffer buffer) decode) {
    // Download progress, as NetworkImage gives it: loadingBuilder shows a spinner from it.
    final chunks = StreamController<ImageChunkEvent>();
    return MultiFrameImageStreamCompleter(
      codec: _load(decode, chunks).whenComplete(() => unawaited(chunks.close())),
      chunkEvents: chunks.stream,
      scale: 1,
      debugLabel: url,
      informationCollector: () => [DiagnosticsProperty<ImageProvider>('Image provider', this)],
    );
  }

  Future<ui.Codec> _load(
      Future<ui.Codec> Function(ui.ImmutableBuffer buffer) decode, StreamController<ImageChunkEvent> chunks) async {
    try {
      final dir = await _ready();
      final file = dir == null ? null : File('${dir.path}/${nameOf(url)}');
      if (file != null) {
        ui.Codec? codec;
        try {
          // Read natively, without a copy in Dart. A photo not kept yet throws here too; deleting it is then a no-op.
          codec = await decode(await ui.ImmutableBuffer.fromFilePath(file.path));
        } catch (_) {
          await _delete(file); // a broken copy: fetched again below
        }
        if (codec != null) {
          _touch(file);
          return codec;
        }
      }
      final bytes = await fetch(Uri.base.resolve(url), (received, total) {
        if (!chunks.isClosed) {
          chunks.add(ImageChunkEvent(cumulativeBytesLoaded: received, expectedTotalBytes: total));
        }
      });
      if (bytes.isEmpty) throw Exception('Empty photo: $url');
      final codec = await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
      // Kept only once it decodes; written beside and renamed, so a cut-off write never looks like a photo.
      if (file != null && dir != null) unawaited(_keep(dir, file, bytes));
      return codec;
    } catch (_) {
      // As NetworkImage does: a failed photo is fetched again next time it is asked for.
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(this));
      rethrow;
    }
  }

  /// Marks a kept photo as recently shown, at most once a day, so trimming keeps it. Never fails the photo.
  static void _touch(File file) {
    unawaited(() async {
      try {
        final now = DateTime.now();
        if (now.difference(await file.lastModified()) > const Duration(days: 1)) await file.setLastModified(now);
      } catch (_) {}
    }());
  }

  static int _parts = 0;

  static Future<void> _keep(Directory dir, File file, Uint8List bytes) async {
    final part = File('${file.path}.${pid}_${_parts++}.part');
    try {
      // The system may have emptied the cache folder while the app was running.
      await dir.create(recursive: true);
      await part.writeAsBytes(bytes, flush: true);
      await part.rename(file.path);
      _written += bytes.length;
      if (_written > limit ~/ 8) _trim(dir);
    } catch (_) {
      await _delete(part);
    }
  }

  @override
  bool operator ==(Object other) => other is KeptImage && other.url == url;

  @override
  int get hashCode => url.hashCode;

  @override
  String toString() => '${objectRuntimeType(this, 'KeptImage')}("$url")';
}
