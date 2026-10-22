// A seller answering a buyer's question gets their ready answers from the chat as one tap each, so a question takes
// a tap and a check instead of typing on a phone keyboard.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vitrina/api.dart';
import 'package:vitrina/demo.dart';
import 'package:vitrina/i18n.dart';
import 'package:vitrina/quick_replies.dart';
import 'package:vitrina/session.dart';
import 'package:vitrina/theme.dart';
import 'package:vitrina/widgets/questions.dart';

import 'support/a11y.dart';
import 'support/press.dart';
import 'support/screens.dart';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

/// What the server has and what reached it.
class _Server {
  bool payments = false;
  bool refuse = false; // the server refuses the answer's words
  String? found; // and says what it found, with its full message
  String? answered; // the text sent as the answer
  bool answeredBefore = false; // the question already has an answer
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    quickReplies.value = null; // the defaults
    appLanguage.value = 'kk';
  });

  Future<void> open(WidgetTester tester, _Server server,
      {bool seller = true, double text = 1, double keyboard = 0, Brightness brightness = Brightness.light}) async {
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await loadFonts(tester);
    final demo = (await tester.runAsync(() => DemoClient.load()))!;
    final client = MockClient.streaming((req, body) async {
      final path = req.url.path.replaceFirst('/api/v1', '');
      http.Response? mine;
      if (path == '/app-config') {
        mine = _json({'payments': server.payments});
      } else if (req.method == 'POST' && path == '/questions/7/answer' && server.refuse) {
        mine = _json({
          'code': 'contacts_not_allowed',
          'message_kk': server.found == null
              ? 'Жауапқа телефон не сілтеме жазуға болмайды.'
              : 'Телефон, сілтеме, почта, @атау не мессенджер (WhatsApp, Telegram, Instagram) жазуға болмайды. '
                  'Байланыс тек VITRINA чатында.',
          'message_ru': 'В ответе нельзя писать телефон или ссылку.',
          if (server.found != null) 'detail': server.found,
        }, 422);
      } else if (req.method == 'GET' && path == '/listings/1/questions') {
        mine = _json({
          'items': [
            {
              'id': 7,
              'text': 'Қорабы бар ма?',
              'answer': server.answered ?? (server.answeredBefore ? 'Иә' : null),
              'asked_at': '2026-10-21T10:00:00Z',
              'answered_at': null,
              'mine': !seller,
            }
          ],
          'unanswered': seller ? 1 : null,
        });
      } else if (req.method == 'POST' && path == '/questions/7/answer') {
        server.answered = (jsonDecode(await body.bytesToString()) as Map)['text'] as String;
        mine = _json({
          'id': 7,
          'text': 'Қорабы бар ма?',
          'answer': server.answered,
          'asked_at': '2026-10-21T10:00:00Z',
          'answered_at': '2026-10-21T11:00:00Z',
          'mine': false,
        });
      }
      if (mine != null) {
        return http.StreamedResponse(Stream.value(mine.bodyBytes), mine.statusCode, headers: mine.headers);
      }
      return demo.send(req);
    });
    final session = Session(Api(base: 'http://demo/api/v1', client: client))..api.token = demoToken;
    session.update((await tester.runAsync(() => session.api.me()))!);
    await tester.pumpWidget(SessionScope(
        session: session,
        child: MediaQuery(
          data: MediaQueryData(
              size: const Size(360, 720),
              textScaler: TextScaler.linear(text),
              viewInsets: EdgeInsets.only(bottom: keyboard)),
          child: MaterialApp(theme: buildTheme(brightness), home: QuestionsScreen(listingId: 1, seller: seller)),
        )));
    await settle(tester);
  }

  final ready = find.byKey(const Key('ready-answers'));
  final field = find.byKey(const Key('question-text'));
  final sendButton = find.byKey(const Key('question-send'));
  Finder chip(String text) => find.descendant(of: ready, matching: find.text(text));

  Future<void> answer(WidgetTester tester, [String key = 'answer-7']) async {
    await tester.tap(find.byKey(Key(key)));
    await settle(tester);
  }

  testWidgets('the answer sheet offers the ready answers; a tap puts one in the field to check, then it is sent',
      (tester) async {
    final server = _Server();
    await open(tester, server);
    await answer(tester);
    expect(chip('Сәлеметсіз бе! Иә, бар.'), findsOneWidget);
    expect(tester.widget<FilledButton>(sendButton).onPressed, isNull, reason: 'nothing written yet');
    await tester.tap(chip('Сәлеметсіз бе! Иә, бар.'));
    await tester.pump();
    expect(tester.widget<TextField>(field).controller!.text, 'Сәлеметсіз бе! Иә, бар.');
    expect(server.answered, isNull, reason: 'not sent by the tap alone');
    // The seller can still change it before it is public.
    await tester.enterText(field, 'Сәлеметсіз бе! Иә, қорабымен.');
    await tester.tap(sendButton);
    await settle(tester);
    expect(server.answered, 'Сәлеметсіз бе! Иә, қорабымен.');
  });

  testWidgets('a second ready answer replaces the first, not added after it', (tester) async {
    await open(tester, _Server());
    await answer(tester);
    await tester.tap(chip('Сәлеметсіз бе! Иә, бар.'));
    await tester.pump();
    final second = find.descendant(of: ready, matching: find.textContaining('Өлшемі сай келеді'));
    await tester.ensureVisible(second);
    await tester.pumpAndSettle();
    await tester.tap(second);
    await tester.pump();
    expect(tester.widget<TextField>(field).controller!.text,
        'Өлшемі сай келеді. Табанының ұзындығын тауар бетінен қараңыз.');
  });

  Finder chips() => find.descendant(of: ready, matching: find.byType(ActionChip));

  testWidgets('the answers about money held in the app are never offered for a public answer', (tester) async {
    // On or off: the answer stays on the listing whatever happens to payment later.
    await open(tester, _Server()..payments = true);
    await answer(tester);
    expect(chips(), findsNWidgets(2));
    expect(find.descendant(of: ready, matching: find.textContaining('VITRINA')), findsNothing);
    expect(find.descendant(of: ready, matching: find.textContaining('Төлем')), findsNothing);
  });

  testWidgets('saved in the chat in Russian, the money answers are still left out', (tester) async {
    appLanguage.value = 'ru';
    await saveQuickReplies([
      'Здравствуйте! Да, есть в наличии.',
      tr('Төлем түскен күні жіберемін.'),
      tr('Ақшаңыз VITRINA-да сақталады: сіз тауарды алғаныңызды растағанда не тексеру мерзімі өткенде ғана маған өтеді.'),
    ]);
    await open(tester, _Server()..payments = true);
    await answer(tester, 'answer-7');
    expect(chips(), findsOneWidget);
    expect(chip('Здравствуйте! Да, есть в наличии.'), findsOneWidget);
  });

  testWidgets('a ready answer with a phone, link or messenger is not offered: the server refuses it there',
      (tester) async {
    await saveQuickReplies([
      'Иә, бар.',
      'Ватсапқа жазыңыз',
      'ватсап: 8 701 123 45 67',
      'WhatsApp-қа жазыңыз',
      'Сайт: www.qadam.kz',
      'Ватсап арқылы жазыңыз',
      'Өлшемі 42',
    ]);
    await open(tester, _Server());
    await answer(tester);
    expect(chips(), findsNWidgets(2));
    for (final ok in ['Иә, бар.', 'Өлшемі 42']) {
      expect(chip(ok), findsOneWidget, reason: ok);
    }
  });

  test('the contact rule reads the cases shared with the server alike', () {
    final cases = jsonDecode(File('../contracts/contact_cases.json').readAsStringSync()) as Map;
    expect((cases['contact'] as List).length, greaterThan(10));
    for (final t in cases['contact'] as List) {
      expect(looksLikeContact(t as String), isTrue, reason: t);
    }
    for (final t in cases['not_contact'] as List) {
      expect(looksLikeContact(t as String), isFalse, reason: t);
    }
  });

  testWidgets('a ready answer listing sizes is offered: it is no phone number', (tester) async {
    await saveQuickReplies(['Иә, 39 40 41 42 43 өлшемдері бар', 'Ватсапқа жазыңыз']);
    await open(tester, _Server());
    await answer(tester);
    expect(chips(), findsOneWidget);
    expect(chip('Иә, 39 40 41 42 43 өлшемдері бар'), findsOneWidget);
  });

  testWidgets('a refusal shows in the sheet, under the words, not behind it', (tester) async {
    final server = _Server()..refuse = true;
    await open(tester, server);
    await answer(tester);
    await tester.enterText(field, 'Иә, бар');
    await tester.pump();
    await tester.tap(sendButton);
    await settle(tester);
    expect(find.text('Жауапқа телефон не сілтеме жазуға болмайды.'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(field, findsOneWidget, reason: 'the sheet stays, the words with it');
    await tester.enterText(field, 'Иә, бар екен');
    await tester.pump();
    expect(find.text('Жауапқа телефон не сілтеме жазуға болмайды.'), findsNothing, reason: 'gone once changed');
  });

  for (final text in [1.0, 1.3, 2.0]) {
    testWidgets('at text ×$text the refusal says in full which part to take out', (tester) async {
      final server = _Server()
        ..refuse = true
        ..found = 'WhatsApp: +7 701 555 12 34';
      await open(tester, server, text: text);
      await answer(tester);
      await tester.enterText(field, 'Иә, бар. WhatsApp: +7 701 555 12 34');
      await tester.pump();
      await tester.tap(sendButton);
      await settle(tester);
      final error = find.textContaining('Мынаны алып тастаңыз: «WhatsApp: +7 701 555 12 34»');
      expect(error, findsOneWidget);
      final paragraph =
          tester.renderObject<RenderParagraph>(find.descendant(of: error, matching: find.byType(RichText)));
      expect(paragraph.didExceedMaxLines, isFalse, reason: 'no line of the refusal is cut off');
      expect(find.textContaining(RegExp(r'^\d+/\d+$')), findsNothing, reason: 'no counter narrows it, far from the limit');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('words the seller wrote are kept: a ready answer is added after them', (tester) async {
    await open(tester, _Server());
    await answer(tester);
    await tester.enterText(field, 'Иә.');
    await tester.tap(chip('Сәлеметсіз бе! Иә, бар.'));
    await tester.pump();
    expect(tester.widget<TextField>(field).controller!.text, 'Иә. Сәлеметсіз бе! Иә, бар.');
  });

  testWidgets('with ready answers the sheet opens on them, the keyboard waits for a tap on the field', (tester) async {
    await open(tester, _Server());
    await answer(tester);
    expect(tester.testTextInput.isVisible, isFalse);
    await tester.tap(field);
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue);
  });

  testWidgets('the seller\'s own ready answers from the chat are the ones offered', (tester) async {
    await saveQuickReplies(['Иә, түпнұсқа.', 'Ертең жіберемін.']);
    await open(tester, _Server());
    await answer(tester);
    expect(find.descendant(of: ready, matching: find.byType(ActionChip)), findsNWidgets(2));
    expect(chip('Иә, түпнұсқа.'), findsOneWidget);
    await saveQuickReplies([]);
    await tester.pump();
    expect(ready, findsNothing, reason: 'none left: no empty row');
  });

  testWidgets('changing an answer offers them too, and a buyer asking gets none', (tester) async {
    await open(tester, _Server()..answeredBefore = true);
    await tester.tap(find.text('Жауапты өзгерту'));
    await settle(tester);
    expect(ready, findsOneWidget);
    expect(tester.widget<TextField>(field).controller!.text, 'Иә', reason: 'the old answer stays until a tap');
    await tester.tap(chip('Сәлеметсіз бе! Иә, бар.'));
    await tester.pump();
    expect(tester.widget<TextField>(field).controller!.text, 'Сәлеметсіз бе! Иә, бар.', reason: 'it takes its place');

    await tester.pumpWidget(const SizedBox());
    await open(tester, _Server(), seller: false);
    await tester.tap(find.text('Сұрақ қою'));
    await settle(tester);
    expect(field, findsOneWidget);
    expect(ready, findsNothing);
    expect(tester.testTextInput.isVisible, isTrue, reason: 'a buyer has only the field: the keyboard comes at once');
  });

  for (final brightness in Brightness.values) {
    testWidgets(
        'at 360 wide with text ×2 and the keyboard up, the sheet fits, reads well and its button is in view, '
        '${brightness.name}', (tester) async {
      final server = _Server();
      await open(tester, server, text: 2, keyboard: 300, brightness: brightness);
      await answer(tester);
      expect(tester.takeException(), isNull);
      expect(ready, findsOneWidget);
      final errors = <String>[];
      await look(tester, errors);
      expect(errors, isEmpty);
      await tester.tap(chips().first);
      await tester.pump();
      // In view above the keyboard, with no scrolling to find it.
      expect(tester.getRect(sendButton).bottom, lessThanOrEqualTo(720 - 300));
      await tester.tap(sendButton);
      await settle(tester);
      expect(server.answered, 'Сәлеметсіз бе! Иә, бар.');
    });
  }

  testWidgets('a buyer asking at text ×2 with the keyboard up sees the button too', (tester) async {
    await open(tester, _Server(), seller: false, text: 2, keyboard: 300);
    await tester.tap(find.text('Сұрақ қою'));
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(tester.getRect(sendButton).bottom, lessThanOrEqualTo(720 - 300));
  });
}
