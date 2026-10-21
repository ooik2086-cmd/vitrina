import 'dart:io';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:path_provider/path_provider.dart';

import 'chat_photos.dart';

PhotoFiles? files() => FolderPhotoFiles(() async => '${(await getApplicationSupportDirectory()).path}/chat_photos');

/// The photos as files in a folder.
class FolderPhotoFiles implements PhotoFiles {
  FolderPhotoFiles(this.folder);
  final Future<String> Function() folder;

  /// Written to a part file first and then renamed: a phone that dies mid-write leaves no half photo under the name.
  @override
  Future<bool> write(String name, Uint8List bytes) async {
    final dir = await folder();
    await Directory(dir).create(recursive: true);
    final part = File('$dir/$name.part');
    await part.writeAsBytes(bytes, flush: true);
    await part.rename('$dir/$name');
    return true;
  }

  @override
  Future<Uint8List?> read(String name) async {
    final file = File('${await folder()}/$name');
    return await file.exists() ? await file.readAsBytes() : null;
  }

  @override
  Future<void> drop(Set<String> names,
      {String? prefix, Set<String>? except, Duration olderThan = Duration.zero}) async {
    final dir = Directory(await folder());
    if (!await dir.exists()) return;
    final now = clock.now();
    await for (final f in dir.list()) {
      if (f is! File) continue;
      final name = f.uri.pathSegments.last;
      try {
        var gone = names.contains(name) || (prefix != null && name.startsWith(prefix));
        if (!gone && except != null && !except.contains(name)) {
          gone = now.difference(await f.lastModified()) >= olderThan;
        }
        if (gone) await f.delete();
      } on FileSystemException catch (_) {
        // Gone meanwhile (another drop, or a part file renamed): the rest of the folder is still looked at.
      }
    }
  }
}
