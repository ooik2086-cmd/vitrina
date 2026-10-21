// On weak mobile data a chat photo can reach the other side while its answer is lost. Sent again, it must arrive
// once, and a photo that may not have gone is kept, shown small, to send again or put aside.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:vitrina/api.dart';
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
  setUp(() => ImagePickerPlatform.instance = _FakePicker());

  /// Opens the chat over another page. Photo sends go into the list with their caption and key; [lost] says, by send,
  /// that the photo was posted but its answer never came back; [down] that it never left the phone.
  Future<List<(String, String?, String?)>> open(WidgetTester tester,
      {bool Function(int send)? lost,
      bool Function(int send)? down,
      int? status,
      Duration slow = Duration.zero,
      Duration pollEvery = const Duration(hours: 1)}) async {
    final sent = <(String, String?, String?)>[]; // caption, key, file name: every try, also those that never left
    final posted = <Map<String, Object?>>[];
    final byKey = <String, Map<String, Object?>>{};
    var sends = 0;
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          if (req.method == 'GET') {
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
          if (status != null) return _json({'code': 'file_too_large', 'message_kk': 'Файл тым үлкен.'}, status);
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
}
