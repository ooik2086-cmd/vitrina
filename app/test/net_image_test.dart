// Photos are kept on the phone once fetched, and fetched again only when the kept copy is missing or broken.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vitrina/net_image.dart';
import 'package:vitrina/net_image_io.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late List<Uri> fetched;
  late Uint8List png;

  setUpAll(() async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 2, 2), Paint()..color = const Color(0xff336699));
    final image = await recorder.endRecording().toImage(2, 2);
    png = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
  });

  setUp(() {
    dir = Directory.systemTemp.createTempSync('kept');
    fetched = [];
    KeptImage.folder = () async => dir;
    KeptImage.fetch = (uri, progress) async {
      fetched.add(uri);
      progress(png.length, png.length);
      return png;
    };
    PaintingBinding.instance.imageCache.clear();
  });

  tearDown(() async {
    await KeptImage.reset();
    dir.deleteSync(recursive: true);
  });

  // Listens until the photo is there and then lets go, as a screen that closes does: the image cache then holds it
  // only as long as it is not cleared.
  Future<ui.Image> show(ImageProvider provider) {
    final done = Completer<ui.Image>();
    final stream = provider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener((info, _) {
      stream.removeListener(listener);
      done.complete(info.image);
    }, onError: (e, s) {
      stream.removeListener(listener);
      done.completeError(e, s);
    });
    stream.addListener(listener);
    return done.future;
  }

  Future<void> written(String url) async {
    final file = File('${dir.path}/${KeptImage.nameOf(url)}');
    for (var i = 0; i < 100 && !file.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(file.existsSync(), isTrue);
  }

  test('a photo is fetched once, then shown from the phone after the app is opened again', () async {
    const url = 'https://media.vitrina.kz/media/listings/1/a.jpg';
    expect((await show(netImage(url))).width, 2);
    await written(url);
    expect(fetched, [Uri.parse(url)]);
    PaintingBinding.instance.imageCache.clear(); // as after a restart
    await KeptImage.reset();
    expect((await show(netImage(url))).width, 2);
    expect(fetched, hasLength(1));
  });

  test('a broken kept copy is thrown away and the photo fetched again', () async {
    const url = 'https://media.vitrina.kz/media/listings/1/b.jpg';
    File('${dir.path}/${KeptImage.nameOf(url)}').writeAsBytesSync([1, 2, 3]);
    expect((await show(netImage(url))).width, 2);
    expect(fetched, hasLength(1));
    await written(url);
    expect(File('${dir.path}/${KeptImage.nameOf(url)}').readAsBytesSync(), png);
  });

  test('a photo that does not decode is not kept', () async {
    const url = 'https://media.vitrina.kz/media/listings/1/c.jpg';
    KeptImage.fetch = (uri, progress) async => Uint8List.fromList([9, 9, 9]);
    await expectLater(show(netImage(url)), throwsA(anything));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(dir.listSync(), isEmpty);
  });

  test('signed private links are never kept', () {
    expect(netImage('https://cdn/private-media/2/r.jpg?exp=1&sig=x'), isNot(isA<KeptImage>()));
    expect(netImage('https://media.vitrina.kz/media/a.jpg'), isA<KeptImage>());
    expect(cacheable('data:image/png;base64,AA'), isFalse);
    expect(cacheable('https://media.vitrina.kz/media/a.jpg#x'), isFalse);
    expect(cacheable('/media/a.jpg'), isFalse);
    // Chat photos, evidence and proofs are someone's own: never kept, whatever their address.
    expect(netImage('https://media.vitrina.kz/media/a.jpg', keep: false), isNot(isA<KeptImage>()));
  });

  test('a photo that failed to arrive is fetched again the next time it is shown', () async {
    const url = 'https://media.vitrina.kz/media/listings/1/e.jpg';
    var calls = 0;
    KeptImage.fetch = (uri, progress) async {
      if (++calls == 1) throw NetworkImageLoadException(statusCode: 503, uri: uri);
      return png;
    };
    await expectLater(show(netImage(url)), throwsA(isA<NetworkImageLoadException>()));
    await Future<void>.delayed(Duration.zero); // the failed photo leaves the image cache
    expect((await show(netImage(url))).width, 2);
    expect(calls, 2);
  });

  test('download progress reaches the screen, as a spinner needs it', () async {
    const url = 'https://media.vitrina.kz/media/listings/1/f.jpg';
    final events = <ImageChunkEvent>[];
    final done = Completer<void>();
    netImage(url).resolve(ImageConfiguration.empty).addListener(ImageStreamListener((_, __) => done.complete(),
        onChunk: events.add, onError: (e, s) => done.completeError(e, s)));
    await done.future;
    expect(events.single.cumulativeBytesLoaded, png.length);
  });

  test('showing a kept photo marks it recently shown, so trimming keeps it', () async {
    const url = 'https://media.vitrina.kz/media/listings/1/g.jpg';
    final file = File('${dir.path}/${KeptImage.nameOf(url)}')
      ..writeAsBytesSync(png)
      ..setLastModifiedSync(DateTime.now().subtract(const Duration(days: 3)));
    expect((await show(netImage(url))).width, 2);
    expect(fetched, isEmpty);
    for (var i = 0; i < 100 && DateTime.now().difference(file.lastModifiedSync()).inDays > 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(DateTime.now().difference(file.lastModifiedSync()).inHours, 0);
  });

  test('without a cache folder photos still show, fetched each time', () async {
    KeptImage.folder = () async => null;
    const url = 'https://media.vitrina.kz/media/listings/1/d.jpg';
    expect((await show(netImage(url))).width, 2);
    PaintingBinding.instance.imageCache.clear();
    expect((await show(netImage(url))).width, 2);
    expect(fetched, hasLength(2));
    expect(dir.listSync(), isEmpty);
  });

  test('past the limit the photos shown longest ago go first', () async {
    final now = DateTime.now();
    for (var i = 0; i < 4; i++) {
      File('${dir.path}/f$i')
        ..writeAsBytesSync(List.filled(100, 0))
        ..setLastModifiedSync(now.subtract(Duration(days: 4 - i)));
    }
    // A write cut off by a killed app is cleared once it is old, whatever the total.
    File('${dir.path}/f9.1_0.part')
      ..writeAsBytesSync([1])
      ..setLastModifiedSync(now.subtract(const Duration(hours: 1)));
    File('${dir.path}/f8.1_1.part').writeAsBytesSync([1]); // still being written
    await KeptImage.trim(dir, max: 350);
    expect(dir.listSync().map((f) => f.path.split('/').last).toSet(), {'f2', 'f3', 'f8.1_1.part'});
    await KeptImage.trim(dir, max: 350);
    expect(dir.listSync(), hasLength(3));
  });

  test('different addresses get different files, the same address the same one', () {
    expect(KeptImage.nameOf('https://a/1.jpg'), KeptImage.nameOf('https://a/1.jpg'));
    expect(KeptImage.nameOf('https://a/1.jpg'), isNot(KeptImage.nameOf('https://a/2.jpg')));
    expect(KeptImage.nameOf('https://a/1.jpg'), hasLength(32));
  });
}
