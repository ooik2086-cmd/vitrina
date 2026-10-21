// On weak mobile data a chat photo can reach the other side while its answer is lost. Sent again, it must arrive
// once, and a photo that may not have gone is kept, shown small, to send again or put aside.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:clock/clock.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vitrina/api.dart';
import 'package:vitrina/chat_drafts.dart';
import 'package:vitrina/chat_photos.dart';
import 'package:vitrina/chat_photos_io.dart';
import 'package:vitrina/screens/chat_screen.dart';
import 'package:vitrina/session.dart';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

// A 1×1 PNG, so the small preview has a real picture to draw.
final _png =
    base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

class _FakePicker extends ImagePickerPlatform {
  var picks = 0;

  @override
  Future<XFile?> getImageFromSource(
      {required ImageSource source, ImagePickerOptions options = const ImagePickerOptions()}) async {
    picks++;
    return XFile.fromData(_png, name: 'p$picks.png', path: '/picked/p$picks.png');
  }
}

/// The phone's kept photos, in memory.
class _MemoryFiles implements PhotoFiles {
  final files = <String, Uint8List>{};

  /// When set, writing or reading waits for it, as a slow phone's storage does.
  Completer<void>? writeGate, readGate;

  @override
  Future<bool> write(String name, Uint8List bytes) async {
    await writeGate?.future;
    return (files[name] = bytes).isNotEmpty;
  }

  @override
  Future<Uint8List?> read(String name) async {
    await readGate?.future;
    return files[name];
  }

  @override
  Future<void> drop(Set<String> names, {String? prefix, Set<String>? except, Duration olderThan = Duration.zero}) async =>
      files.removeWhere((name, _) =>
          names.contains(name) ||
          (prefix != null && name.startsWith(prefix)) ||
          (except != null && !except.contains(name)));
}

const _conv = {
  'id': 9,
  'listing_id': 7,
  'listing_title': 'Кроссовка',
  'listing_cover': null,
  'price_tiyn': 2490000,
  'role': 'buyer',
  'other_name': 'Сатушы',
  'last_message': null,
  'unread': 0,
};

void main() {
  late _MemoryFiles phone;
  Completer<void>? chatGate; // when set, reading the chat waits for it
  setUp(() {
    ImagePickerPlatform.instance = _FakePicker();
    SharedPreferences.setMockInitialValues({});
    ChatPhotos.files = phone = _MemoryFiles();
    chatGate = null;
  });
  tearDown(() => ChatPhotos.files = files());

  /// Opens the chat over another page. Photo sends go into the list with their caption and key; [lost] says, by send,
  /// that the photo was posted but its answer never came back; [down] that it never left the phone.
  Future<List<(String, String?, String?)>> open(WidgetTester tester,
      {bool Function(int send)? lost,
      bool Function(int send)? down,
      int? status,
      Duration slow = Duration.zero,
      Duration answerAfter = Duration.zero,
      List<Map<String, Object?>>? thread,
      Duration pollEvery = const Duration(hours: 1)}) async {
    final sent = <(String, String?, String?)>[]; // caption, key, file name: every try, also those that never left
    final posted = thread ?? <Map<String, Object?>>[]; // the test may add to it, as another phone does
    final byKey = <String, Map<String, Object?>>{};
    var sends = 0;
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          if (req.method == 'GET') {
            await chatGate?.future;
            final after = int.tryParse(req.url.queryParameters['after_id'] ?? '') ?? 0;
            return _json({'conversation': _conv, 'items': posted.where((m) => (m['id'] as int) > after).toList()});
          }
          expect(req.url.path, endsWith('/photos'));
          final n = ++sends;
          final form = utf8.decode(req.bodyBytes, allowMalformed: true);
          final caption = RegExp(r'name="caption"\r\n(?:[^\r\n]+\r\n)*\r\n([^\r]*)').firstMatch(form)?.group(1);
          final key = req.headers['Idempotency-Key'];
          sent.add((caption ?? '', key, RegExp(r'filename="([^"]*)"').firstMatch(form)?.group(1)));
          if (down?.call(n) ?? false) throw http.ClientException('no connection');
          if (status != null) {
            final code = status >= 500 ? 'server' : 'file_too_large';
            return _json({'code': code, 'message_kk': status >= 500 ? 'Сервер қатесі.' : 'Файл тым үлкен.'}, status);
          }
          var m = key == null ? null : byKey[key];
          if (m == null) {
            m = {
              'id': 100 + n,
              'sender_id': 3,
              'body': caption ?? '',
              'photo_url': 'http://x/media/p$n.jpg',
              'contact_warning': false,
              'created_at': '2026-10-21T10:00:00Z',
            };
            posted.add(m);
            if (key != null) byKey[key] = m;
          }
          if (lost?.call(n) ?? false) {
            await Future<void>.delayed(slow);
            throw http.ClientException('answer lost');
          }
          await Future<void>.delayed(answerAfter);
          return _json(m, 201);
        }));
    final session = Session(api)..me = Me.fromJson({'id': 3, 'phone': '+77010000003', 'is_seller': false});
    await tester.pumpWidget(SessionScope(
        session: session,
        child: MaterialApp(
            home: Scaffold(
                body: Builder(
                    builder: (context) => TextButton(
                        onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => ChatScreen(conversationId: 9, pollEvery: pollEvery))),
                        child: const Text('open')))))));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    return sent;
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> sendPhoto(WidgetTester tester, {String caption = ''}) async {
    await tester.enterText(find.byType(TextField), caption);
    await tester.tap(find.byKey(const Key('chat-photo')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Галерея'));
    await settle(tester);
  }

  const notSent = 'Байланыс жоқ. Фото жетпеген болуы мүмкін.';
  final line = find.byKey(const Key('chat-photo-not-sent'));
  final resend = find.byKey(const Key('chat-photo-resend'));
  final drop = find.byKey(const Key('chat-photo-drop'));
  Finder field(String text) => find.widgetWithText(TextField, text);
  bool canPick(WidgetTester tester) => tester.widget<IconButton>(find.byKey(const Key('chat-photo'))).onPressed != null;

  testWidgets('a photo whose answer was lost, sent again, goes with the same key and shows once', (tester) async {
    final sent = await open(tester, lost: (n) => n == 1);
    await sendPhoto(tester, caption: 'Табаны');
    expect(find.text(notSent), findsOneWidget);
    expect(find.descendant(of: line, matching: find.byType(Image)), findsOneWidget); // which photo, shown small
    expect(find.descendant(of: line, matching: find.text('«Табаны»')), findsOneWidget); // its words go with it
    expect(field('Табаны'), findsNothing); // not left to go again as a message of their own
    expect(tester.getRect(line).bottom, lessThanOrEqualTo(tester.getRect(find.byType(TextField)).top));
    await tester.tap(resend);
    await settle(tester);
    expect(sent, hasLength(2));
    expect(sent[1], sent[0]); // the same photo, words and key, so the server posts it once
    expect(sent[0].$2, isNotNull);
    expect(find.text('Табаны'), findsOneWidget); // in the thread once
    expect(line, findsNothing);
  });

  testWidgets('a kept photo goes again before another is picked; a new pick is a new photo', (tester) async {
    final sent = await open(tester, down: (n) => n == 1);
    await sendPhoto(tester);
    expect(line, findsOneWidget);
    expect(canPick(tester), isFalse); // one kept photo at a time, so none is lost unseen
    await tester.tap(resend);
    await settle(tester);
    expect(line, findsNothing);
    expect(canPick(tester), isTrue);
    await sendPhoto(tester);
    expect(sent.map((s) => s.$3), ['p1.png', 'p1.png', 'p2.png']);
    expect(sent[1].$2, sent[0].$2); // the same photo again
    expect(sent[2].$2, isNot(sent[0].$2)); // two picks, two photos
  });

  testWidgets('a photo put aside is not sent, and its words come back to the field', (tester) async {
    final sent = await open(tester, down: (n) => true);
    await sendPhoto(tester, caption: 'Мынау');
    await tester.tap(drop);
    await settle(tester);
    expect(line, findsNothing);
    expect(field('Мынау'), findsOneWidget); // the words are the sender's to keep or send
    expect(sent, hasLength(1)); // only the try that never left
    expect(canPick(tester), isTrue);
  });

  testWidgets('a kept photo cannot be put aside while it is going again, so it does not come back', (tester) async {
    await open(tester, down: (n) => n == 1, lost: (n) => n == 2, slow: const Duration(seconds: 7));
    await sendPhoto(tester);
    await tester.tap(resend);
    await tester.pump();
    expect(tester.widget<IconButton>(drop).onPressed, isNull);
    await tester.pump(const Duration(seconds: 8));
    expect(line, findsOneWidget); // it did not go, and is still kept
  });

  testWidgets('words typed after a photo was kept stay when it goes again', (tester) async {
    await open(tester, lost: (n) => n == 1);
    await sendPhoto(tester, caption: 'Табаны');
    await tester.enterText(find.byType(TextField), 'Басқа сұрақ');
    await tester.tap(resend);
    await settle(tester);
    expect(line, findsNothing);
    expect(field('Басқа сұрақ'), findsOneWidget);
  });

  testWidgets('a photo that went after all, shown by the thread, takes its line away', (tester) async {
    await open(tester, lost: (n) => n == 1, pollEvery: const Duration(seconds: 5));
    await sendPhoto(tester, caption: 'Табаны');
    expect(line, findsOneWidget);
    await tester.pump(const Duration(seconds: 5)); // the thread is read again
    await tester.pump();
    expect(find.text('Табаны'), findsOneWidget);
    expect(line, findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();
  });

  testWidgets('a photo the thread showed while its answer was still on the way is not kept', (tester) async {
    await open(tester, lost: (n) => n == 1, slow: const Duration(seconds: 7), pollEvery: const Duration(seconds: 5));
    await tester.enterText(find.byType(TextField), 'Табаны');
    await tester.tap(find.byKey(const Key('chat-photo')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Галерея'));
    await tester.pump(const Duration(seconds: 5)); // the thread is read while the send waits
    await tester.pump(const Duration(seconds: 3)); // and then the send gives up
    await tester.pump();
    expect(find.text('Табаны'), findsOneWidget); // in the thread, once
    expect(field('Табаны'), findsNothing);
    expect(line, findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();
  });

  testWidgets('a refusal from the server is told in its own words and nothing is kept to resend', (tester) async {
    await open(tester, status: 413);
    await sendPhoto(tester, caption: 'Табаны');
    expect(find.text('Файл тым үлкен.'), findsOneWidget);
    expect(line, findsNothing);
    expect(field('Табаны'), findsOneWidget);
  });

  testWidgets('the photo line is heard by a screen reader and its buttons are big enough', (tester) async {
    final handle = tester.ensureSemantics();
    await open(tester, down: (n) => true);
    await sendPhoto(tester);
    expect(tester.getSemantics(find.text(notSent)), isSemantics(isLiveRegion: true));
    expect(tester.getSize(resend).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(drop).height, greaterThanOrEqualTo(48));
    expect(find.byTooltip('Алып тастау'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('with large text at 360 wide the words keep the width and the buttons go under them', (tester) async {
    tester.view.physicalSize = const Size(360, 760);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await open(tester, down: (n) => true);
    await sendPhoto(tester);
    expect(tester.getSize(find.text(notSent)).width, greaterThan(200));
    expect(tester.getRect(resend).top, greaterThanOrEqualTo(tester.getRect(find.text(notSent)).bottom));
    expect(tester.takeException(), isNull);
  });

  // Leaving the chat, or the phone closing the app, does not lose a photo that may not have gone.
  group('kept on the phone', () {
    Future<void> leave(WidgetTester tester) async {
      await tester.pageBack();
      await tester.pumpAndSettle();
    }

    Future<void> reopen(WidgetTester tester) async {
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    Future<Map<String, dynamic>> kept() async =>
        jsonDecode((await SharedPreferences.getInstance()).getString(ChatDrafts.key) ?? '{}') as Map<String, dynamic>;

    testWidgets('a photo that never left comes back with its words and key, and goes once', (tester) async {
      final sent = await open(tester, down: (n) => n == 1);
      await sendPhoto(tester, caption: 'Табаны');
      expect(phone.files, hasLength(1));
      await leave(tester);
      expect((await kept())['3:9']['photo'], containsPair('caption', 'Табаны'));
      await reopen(tester);
      // Brought back, it does not claim the connection is down now.
      expect(find.text('Фото жетпеген болуы мүмкін.'), findsOneWidget);
      expect(find.text(notSent), findsNothing);
      expect(find.descendant(of: line, matching: find.byType(Image)), findsOneWidget);
      expect(find.descendant(of: line, matching: find.text('«Табаны»')), findsOneWidget);
      expect(canPick(tester), isFalse);
      await tester.tap(resend);
      await settle(tester);
      expect(sent, hasLength(2));
      expect(sent[1], sent[0]); // the same photo, words and key
      expect(line, findsNothing);
      expect(find.text('Табаны'), findsOneWidget);
      expect(phone.files, isEmpty); // gone from the phone once it went
      expect(await kept(), isEmpty);
    });

    testWidgets('a photo that went while its answer was lost is not brought back', (tester) async {
      final sent = await open(tester, lost: (n) => n == 1);
      await sendPhoto(tester, caption: 'Табаны');
      expect(line, findsOneWidget);
      await leave(tester);
      await reopen(tester);
      expect(find.text('Табаны'), findsOneWidget); // the thread shows it
      expect(line, findsNothing);
      expect(field('Табаны'), findsNothing);
      expect(sent, hasLength(1));
      await tester.pump();
      expect(phone.files, isEmpty);
      expect(await kept(), isEmpty);
    });

    testWidgets('a chat left while its photo is on the way keeps it until the answer', (tester) async {
      await open(tester, lost: (n) => n == 1, slow: const Duration(seconds: 7));
      await tester.tap(find.byKey(const Key('chat-photo')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Галерея'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await leave(tester); // before any answer
      expect(phone.files, hasLength(1));
      expect((await kept())['3:9']['photo'], isNotNull);
      await tester.pump(const Duration(seconds: 8)); // the answer is lost: it stays kept
      expect(phone.files, hasLength(1));
      expect((await kept())['3:9']['photo'], isNotNull);
    });

    testWidgets('a chat left while its photo is on the way lets it go when it arrives', (tester) async {
      await open(tester, answerAfter: const Duration(seconds: 5));
      await tester.enterText(find.byType(TextField), 'Табаны');
      await tester.tap(find.byKey(const Key('chat-photo')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Галерея'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await leave(tester); // before the answer
      expect(phone.files, hasLength(1));
      // Its words are kept with it, not again as words for the field.
      expect((await kept())['3:9'], allOf(containsPair('text', ''), contains('photo')));
      await tester.pump(const Duration(seconds: 6)); // the answer comes
      expect(phone.files, isEmpty);
      expect(await kept(), isEmpty); // nothing comes back into the field either
    });

    testWidgets('a photo put aside after coming back goes from the phone, its words to the field', (tester) async {
      await open(tester, down: (n) => true);
      await sendPhoto(tester, caption: 'Мынау');
      await leave(tester);
      await reopen(tester);
      await tester.tap(drop);
      await settle(tester);
      expect(line, findsNothing);
      expect(field('Мынау'), findsOneWidget);
      expect(phone.files, isEmpty);
      expect((await kept())['3:9']?['photo'], isNull);
      await leave(tester);
      await reopen(tester);
      expect(line, findsNothing); // it does not come back
    });

    testWidgets('a photo the server refused is not kept', (tester) async {
      await open(tester, status: 413);
      await sendPhoto(tester, caption: 'Табаны');
      await tester.pump();
      expect(phone.files, isEmpty);
      expect((await kept())['3:9']?['photo'], isNull);
      expect((await kept())['3:9']?['text'], 'Табаны'); // the words stay, as words
    });

    testWidgets('a photo the server failed on is kept, with no claim that the connection is down', (tester) async {
      await open(tester, status: 503);
      await sendPhoto(tester, caption: 'Табаны');
      expect(find.text('Фото жетпеген болуы мүмкін.'), findsOneWidget);
      expect(find.text('Сервер қатесі.'), findsNothing);
      expect(phone.files, hasLength(1));
      expect((await kept())['3:9']['photo'], containsPair('caption', 'Табаны'));
    });

    testWidgets('a photo written to the phone only after it went is let go again', (tester) async {
      await open(tester);
      phone.writeGate = Completer();
      await sendPhoto(tester, caption: 'Табаны');
      expect(find.text('Табаны'), findsOneWidget); // it went
      phone.writeGate!.complete();
      await tester.pump();
      await tester.pump();
      expect(phone.files, isEmpty);
      expect(await kept(), isEmpty);
    });

    testWidgets('an earlier photo with the same words does not count as the kept one', (tester) async {
      await open(tester, down: (n) => n == 2);
      await sendPhoto(tester, caption: 'Табаны'); // goes
      await sendPhoto(tester, caption: 'Табаны'); // does not
      expect(line, findsOneWidget);
      await leave(tester);
      await reopen(tester);
      expect(line, findsOneWidget); // the first one, before it, is not it
      expect(phone.files, hasLength(1));
    });

    testWidgets('a photo without words is not taken for another photo of mine', (tester) async {
      final thread = <Map<String, Object?>>[];
      await open(tester, down: (n) => n == 1, thread: thread);
      await sendPhoto(tester);
      await leave(tester);
      thread.add({
        'id': 50,
        'sender_id': 3,
        'body': '',
        'photo_url': 'http://x/media/other.jpg',
        'contact_warning': false,
        'created_at': '2026-10-21T11:00:00Z',
      }); // sent from another phone meanwhile
      await reopen(tester);
      expect(find.byType(Image), findsNWidgets(2)); // that one in the thread, and the kept one in its line
      expect(line, findsOneWidget);
      expect(phone.files, hasLength(1));
    });

    testWidgets('a photo brought back shows its line only once the chat has loaded', (tester) async {
      await open(tester, down: (n) => n == 1);
      await sendPhoto(tester, caption: 'Табаны');
      await leave(tester);
      chatGate = Completer();
      await reopen(tester);
      expect(line, findsNothing); // it may have gone meanwhile: the chat says
      expect(canPick(tester), isFalse);
      chatGate!.complete();
      await settle(tester);
      expect(find.text('Фото жетпеген болуы мүмкін.'), findsOneWidget);
    });

    testWidgets('words typed while the photo is read back from the phone do not lose it', (tester) async {
      await open(tester, down: (n) => n == 1);
      await sendPhoto(tester, caption: 'Табаны');
      await leave(tester);
      phone.readGate = Completer();
      await reopen(tester);
      expect(canPick(tester), isFalse); // a kept photo may still be coming back
      await tester.enterText(find.byType(TextField), 'Сәлем');
      await tester.pump(const Duration(seconds: 1)); // the words are kept meanwhile
      expect((await kept())['3:9'], allOf(containsPair('text', 'Сәлем'), contains('photo')));
      expect(phone.files, hasLength(1));
      phone.readGate!.complete();
      await settle(tester);
      expect(line, findsOneWidget);
      expect(field('Сәлем'), findsOneWidget);
      expect(canPick(tester), isFalse); // one kept photo at a time
    });

    testWidgets('a kept photo whose file is gone is let go, and the chat opens as usual', (tester) async {
      await open(tester, down: (n) => n == 1);
      await sendPhoto(tester);
      await leave(tester);
      phone.files.clear(); // the phone cleared it
      await reopen(tester);
      expect(line, findsNothing);
      expect(canPick(tester), isTrue);
      await tester.pump();
      expect(await kept(), isEmpty);
    });
  });

  group('the files', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('chat_photos'));
    tearDown(() => dir.deleteSync(recursive: true));
    List<String> names() => dir.listSync().map((f) => f.uri.pathSegments.last).toList()..sort();

    /// The files go a moment after the words, without anything waiting on the disk.
    Future<void> settled(List<String> want) async {
      for (var i = 0; i < 100 && names().join() != want.join(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(names(), want);
    }

    test('are written whole, read back and let go by name or by person', () async {
      final folder = '${dir.path}/chat_photos'; // made on the first photo
      ChatPhotos.files = FolderPhotoFiles(() async => folder);
      final a = await ChatPhotos.keep(3, 9, 'ab-12', Uint8List.fromList([1, 2, 3]));
      final b = await ChatPhotos.keep(31, 9, 'cd', Uint8List.fromList([4]));
      expect((a, b), ('3_9_ab12.photo', '31_9_cd.photo'));
      dir = Directory('${dir.path}/chat_photos');
      expect(names(), [a!, b!]..sort()); // no part file left
      expect((await ChatPhotos.read(a)).bytes, [1, 2, 3]);
      expect((await ChatPhotos.read('../$a')).bytes, isNull);
      expect((await ChatPhotos.read('3_9_none.photo')).missing, isTrue);
      await ChatPhotos.drop(prefix: ChatPhotos.prefixOf(3));
      expect(names(), [b]); // the person 31's stays
      await ChatPhotos.drop(names: [b]);
      expect(names(), isEmpty);
      dir = dir.parent;
    });

    test('one nobody names goes at start once it is ten minutes old; one an entry names stays', () async {
      ChatPhotos.files = FolderPhotoFiles(() async => dir.path);
      final now = DateTime.now();
      await withClock(Clock.fixed(now), () async {
        final named = await ChatPhotos.keep(3, 9, 'a', Uint8List.fromList([1]));
        final loose = await ChatPhotos.keep(3, 8, 'b', Uint8List.fromList([2]));
        await ChatDrafts.put(3, 9, {'text': '', 'photo': {'file': named, 'key': 'a', 'caption': '', 'name': 'p.png'}});
        await ChatDrafts.sweep();
        expect(names(), [loose, named]..sort()); // the loose one may still be on its way into an entry
        await withClock(Clock.fixed(now.add(const Duration(minutes: 11))), ChatDrafts.sweep);
        expect(names(), [named]);
        // Past its seven days the entry goes, and its photo with it (any write lets stale entries go).
        await withClock(Clock.fixed(now.add(const Duration(days: 8))), () => ChatDrafts.put(4, 1, {'text': 'а'}));
        await settled([]);
      });
    });

    test('an account deleted takes its photos, named in an entry or not yet', () async {
      ChatPhotos.files = FolderPhotoFiles(() async => dir.path);
      final named = await ChatPhotos.keep(3, 9, 'a', Uint8List.fromList([1]));
      await ChatPhotos.keep(3, 8, 'b', Uint8List.fromList([2]));
      final theirs = await ChatPhotos.keep(4, 9, 'c', Uint8List.fromList([3]));
      await ChatDrafts.put(3, 9, {'text': '', 'photo': {'file': named, 'key': 'a', 'caption': '', 'name': 'p.png'}});
      await ChatDrafts.forget(3);
      await settled([theirs!]);
    });
  });
}
