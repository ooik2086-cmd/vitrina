import 'dart:typed_data';

import 'chat_photos_web.dart' if (dart.library.io) 'chat_photos_io.dart' as impl;

/// Chat photos that may not have gone, kept on the phone while [ChatDrafts] keeps their caption and key: leaving the
/// chat or a closed app no longer loses a photo picked on a weak connection. One file a send, named by its owner,
/// chat and key. In the browser nothing is kept: the photo stays only while the chat is open, as before.
class ChatPhotos {
  /// Where they are kept (files in the app's own folder, which the phone does not clear on its own), or null where
  /// nothing can be; tests replace it.
  static PhotoFiles? files = impl.files();

  static String _name(int owner, int chat, String key) =>
      '${owner}_${chat}_${key.replaceAll(RegExp('[^A-Za-z0-9]'), '')}.photo';

  /// Keeps [bytes] for [owner]'s send with [key] in [chat]; the file's name, or null when it could not be kept.
  static Future<String?> keep(int owner, int chat, String key, Uint8List bytes) async {
    final name = _name(owner, chat, key);
    try {
      return await files?.write(name, bytes) == true ? name : null;
    } catch (_) {
      return null;
    }
  }

  /// The kept photo called [name]. [missing] when it is not there (the phone cleared it, or a backup brought back
  /// its entry without it); neither, when it could not be read this time.
  static Future<({Uint8List? bytes, bool missing})> read(String name) async {
    if (name.contains('/') || name.contains(r'\')) return (bytes: null, missing: true); // only a name given here
    try {
      final bytes = await files?.read(name);
      return (bytes: bytes, missing: bytes == null);
    } catch (_) {
      return (bytes: null, missing: false);
    }
  }

  /// Lets the files go that are called [names], or begin with [prefix] (one person's, when their account goes), or,
  /// with [except], every file not in it that has been there [olderThan]: a file is written just before its entry
  /// names it, so a newer one may be on its way into an entry.
  static Future<void> drop(
      {Iterable<String> names = const [],
      String? prefix,
      Set<String>? except,
      Duration olderThan = Duration.zero}) async {
    try {
      await files?.drop(names.toSet(), prefix: prefix, except: except, olderThan: olderThan);
    } catch (_) {}
  }

  /// The file names of [owner]'s photos start with this.
  static String prefixOf(int owner) => '${owner}_';
}

/// A place to keep the photos, by name.
abstract class PhotoFiles {
  /// False when it could not be kept.
  Future<bool> write(String name, Uint8List bytes);

  /// Null when there is no such photo; an error when it could not be read.
  Future<Uint8List?> read(String name);

  /// See [ChatPhotos.drop].
  Future<void> drop(Set<String> names, {String? prefix, Set<String>? except, Duration olderThan = Duration.zero});
}
