import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:vitrina/api.dart';
import 'package:vitrina/screens/listing_editor_screen.dart';
import 'package:vitrina/session.dart';
import 'package:vitrina/theme.dart';

import 'support/screens.dart' show loadFonts;

/// Every pick hands back the same small photo, as if taken with the camera.
class _FakePicker extends ImagePickerPlatform {
  @override
  Future<XFile?> getImageFromSource(
          {required ImageSource source, ImagePickerOptions options = const ImagePickerOptions()}) async =>
      XFile.fromData(utf8.encode('jpeg bytes'), name: 'p.jpg', path: '/picked/p.jpg');

  @override
  Future<List<XFile>> getMultiImageWithOptions(
          {MultiImagePickerOptions options = const MultiImagePickerOptions()}) async =>
      [for (var i = 0; i < 24; i++) XFile.fromData(utf8.encode('frame $i'), name: 'f$i.jpg', path: '/picked/f$i.jpg')];
}

http.Response jsonResponse(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

Map<String, dynamic> listingJson({String status = 'draft'}) => {
      'id': 7,
      'status': status,
      'title': 'Nike Air Force 1',
      'category': 'sneakers',
      'audience': 'unisex',
      'brand': 'Nike',
      'model_name': 'Air Force 1',
      'color': 'ақ',
      'price_tiyn': 4500000,
      'delivery_price_tiyn': 150000,
      'condition': 'new_with_box',
      'authenticity': 'unverified',
      'showcase_style': 'clean',
      'sizes': [
        {'id': 1, 'label': '42', 'insole_cm': '27,0', 'available': true, 'quantity': 2},
        {'id': 2, 'label': '43', 'insole_cm': '27,5', 'available': false, 'quantity': 0},
      ],
      'media': [],
      'seller': {'id': 3, 'shop_name': 'Qadam Store', 'city': 'Алматы'},
    };

/// The most photo uploads that were on their way at once, in the last editor opened.
var maxInFlight = 0;

/// The file names of photo uploads, in the order they reached the server.
final uploadOrder = <String>[];

void main() {
  setUp(() => ImagePickerPlatform.instance = _FakePicker());

  /// Opens the editor from a screen underneath, as the app does, and records what reaches the server.
  Future<List<String>> open(WidgetTester tester,
      {Listing? template,
      List<Map<String, dynamic>>? sent,
      bool Function(int upload)? fails,
      int failStatus = 500,
      Future<void>? failLater,
      Future<void>? hold,
      List<Duration> waits = const [],
      double width = 500}) async {
    final calls = <String>[];
    var uploads = 0, inFlight = 0;
    maxInFlight = 0;
    uploadOrder.clear();
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          calls.add('${req.method} ${req.url.path}');
          if (req.url.path.endsWith('/media')) {
            final n = ++uploads;
            uploadOrder.add(RegExp(r'filename="([^"]+)"').firstMatch(latin1.decode(req.bodyBytes))!.group(1)!);
            maxInFlight = max(maxInFlight, ++inFlight);
            await hold;
            if (fails?.call(n) ?? false) await failLater;
            inFlight--;
            return fails?.call(n) ?? false
                ? jsonResponse({}, failStatus)
                : jsonResponse({'url': 'https://cdn/$n.jpg'}, 201);
          }
          if (req.url.path.endsWith('/suggest')) return jsonResponse({});
          if (req.url.path.endsWith('/publish')) return jsonResponse(listingJson(status: 'moderation'));
          sent?.add(jsonDecode(req.body) as Map<String, dynamic>);
          return jsonResponse(listingJson(), 201);
        }))
      ..uploadWaits = waits;
    tester.view.physicalSize = Size(width, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(SessionScope(
        session: Session(api),
        child: MaterialApp(
            theme: buildTheme(Brightness.light),
            home: Scaffold(
                body: Builder(
                    builder: (context) => TextButton(
                        onPressed: () => Navigator.of(context)
                            .push(MaterialPageRoute(builder: (_) => ListingEditorScreen(template: template))),
                        child: const Text('open')))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return calls;
  }

  Future<void> pick(WidgetTester tester, Finder slot) async {
    await tester.tap(slot);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Камерамен түсіру'));
    await tester.pumpAndSettle();
  }

  Future<void> pickSides(WidgetTester tester) async {
    for (final label in requiredAngles.values) {
      await pick(tester, find.text('$label *'));
    }
  }

  Future<void> next(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('next')));
    await tester.pumpAndSettle();
  }

  String step(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('step-title'))).data!;

  Future<void> choose(WidgetTester tester, Finder field, String option) async {
    await tester.tap(field);
    await tester.pumpAndSettle();
    await tester.tap(find.text(option).last);
    await tester.pumpAndSettle();
  }

  testWidgets('a new pair is listed in three short steps, each checked before the next', (tester) async {
    final sent = <Map<String, dynamic>>[];
    final calls = await open(tester, sent: sent);
    expect(step(tester), 'Фото');
    expect(find.text('1-қадам, барлығы 3'), findsOneWidget);
    // A screen reader hears each step as it opens.
    expect(tester.getSemantics(find.byKey(const Key('step-title'))), isSemantics(isHeader: true, isLiveRegion: true));
    expect(find.widgetWithText(TextFormField, 'Атауы'), findsNothing); // one thing at a time

    // Photos first: the four sides are needed before anything else is asked.
    await next(tester);
    expect(find.textContaining('Фото жетіспейді'), findsOneWidget);
    expect(step(tester), 'Фото');
    for (final label in ['Сырт бүйірі', 'Ішкі бүйірі', 'Өкшесі']) {
      await pick(tester, find.text('$label *'));
    }
    await next(tester);
    expect(find.text('Фото жетіспейді: Алдынан.'), findsOneWidget); // names the one side still missing
    expect(step(tester), 'Фото');
    await pick(tester, find.text('Алдынан *'));
    await next(tester);
    expect(step(tester), 'Тауар туралы');
    expect(find.text('2-қадам, барлығы 3'), findsOneWidget);

    // The pair: nothing is assumed, and the page says what is missing.
    await next(tester);
    expect(step(tester), 'Тауар туралы');
    expect(find.text('Толтырыңыз'), findsOneWidget);
    expect(find.text('Түсін таңдаңыз'), findsOneWidget); // the colour is picked, not left out
    expect(find.text('Кімге арналғанын таңдаңыз'), findsOneWidget); // asked, never assumed
    expect(find.text('Түрін таңдаңыз'), findsOneWidget); // boots are never filed as sneakers by default
    await tester.enterText(find.widgetWithText(TextFormField, 'Атауы'), 'AF');
    await next(tester);
    expect(find.text('Атауы кемінде 3 таңбадан тұрсын'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, 'Атауы'), 'Qadam етік');
    await choose(tester, find.byKey(const Key('audience')), 'Әйелдерге');
    await choose(tester, find.byKey(const ValueKey('category-null')), 'Етік, бәтеңке');
    await tester.tap(find.byKey(const Key('color-ақ')));
    await tester.pump();
    // A pair with a defect says what is wrong with it and shows it up close.
    await choose(tester, find.text('Жаңа, қорабымен'), 'Ақауы бар');
    await next(tester);
    expect(find.text('Толтырыңыз'), findsOneWidget); // the defects field
    await tester.enterText(find.widgetWithText(TextFormField, 'Ақаулары'), 'Өкшесі сәл тозған');
    await next(tester);
    expect(find.text('Әр ақаудың жақын фотосын қосыңыз.'), findsOneWidget);
    expect(step(tester), 'Тауар туралы');
    await pick(tester, find.text('Ақау фотосы'));
    await next(tester);
    expect(step(tester), 'Бағасы мен өлшемі');

    // Back walks to the step before, with everything still filled in, and does not leave.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(step(tester), 'Тауар туралы');
    expect(find.text('Qadam етік'), findsOneWidget);
    expect(find.text('Әйелдерге'), findsOneWidget);
    await next(tester);

    // Price and sizes, checked on the spot.
    await tester.tap(find.text('Жариялау'));
    await tester.pumpAndSettle();
    expect(find.text('Бағаны енгізіңіз'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, 'Ұлтарақ, см'), '5');
    await tester.tap(find.text('Жариялау'));
    await tester.pumpAndSettle();
    expect(find.text('8–35 см аралығында болуы керек'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, 'Ұлтарақ, см'), 'жиырма');
    await tester.tap(find.text('Жариялау'));
    await tester.pumpAndSettle();
    expect(find.text('Санмен жазыңыз, мысалы 27,5'), findsOneWidget);
    expect(calls.where((c) => c == 'POST /api/v1/listings'), isEmpty); // nothing was sent while anything was wrong

    await tester.enterText(find.widgetWithText(TextFormField, 'Бағасы'), '34900');
    await tester.enterText(find.widgetWithText(TextFormField, 'Өлшем'), '38');
    await tester.enterText(find.widgetWithText(TextFormField, 'Ұлтарақ, см'), '24,5');
    await tester.tap(find.text('Жариялау'));
    await tester.pumpAndSettle();
    expect(sent.single, containsPair('title', 'Qadam етік'));
    expect(sent.single, containsPair('category', 'boots'));
    expect(sent.single, containsPair('audience', 'women'));
    expect(sent.single, containsPair('color', 'ақ'));
    expect(sent.single, containsPair('condition', 'defective'));
    expect(sent.single, containsPair('defects', 'Өкшесі сәл тозған'));
    expect(sent.single, containsPair('price_tiyn', 3490000));
    expect(sent.single['sizes'], [
      {'label': '38', 'insole_cm': '24,5', 'quantity': 1}
    ]);
    expect({for (final p in sent.single['photos'] as List) p['angle']}, {'front', 'outer', 'inner', 'back', 'defect'});
    expect(calls.last, 'POST /api/v1/listings/7/publish');
    expect(find.byType(ListingEditorScreen), findsNothing);
    expect(find.text('Тексеруге жіберілді'), findsOneWidget);
  });

  testWidgets('leaving the listing editor with unsaved work asks first', (tester) async {
    await open(tester);
    // Nothing done yet: back simply leaves.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(ListingEditorScreen), findsNothing);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await pick(tester, find.text('Алдынан *'));
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Сақтамай шығу керек пе?'), findsOneWidget);
    await tester.tap(find.text('Қалу'));
    await tester.pumpAndSettle();
    expect(find.byType(ListingEditorScreen), findsOneWidget);
    expect(find.byType(Image), findsOneWidget); // the photo taken is still there
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('discard')));
    await tester.pumpAndSettle();
    expect(find.byType(ListingEditorScreen), findsNothing);
  });

  testWidgets('a photo that did not upload is caught on the photo step and sent again with a tap, not retaken',
      (tester) async {
    final calls = await open(tester, fails: (n) => n <= 4);
    await pickSides(tester);
    await next(tester);
    expect(find.text('Кейбір фото жүктелмеді. Белгісі бар фотоны басып, қайта жіберіңіз.'), findsOneWidget);
    expect(step(tester), 'Фото');
    for (final label in requiredAngles.values) {
      await tester.tap(find.text('$label *'));
      await tester.pumpAndSettle();
    }
    expect(find.text('Камерамен түсіру'), findsNothing); // no camera: the photo already taken goes again
    expect(calls.where((c) => c.endsWith('/media')), hasLength(8));
    await next(tester);
    expect(step(tester), 'Тауар туралы');
  });

  testWidgets('weak mobile data: a photo that fails on the way is sent again by itself, a refusal is not',
      (tester) async {
    final calls = await open(tester, fails: (n) => n == 1, waits: const [Duration(seconds: 2)]);
    await pick(tester, find.text('Алдынан *'));
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget); // failed once, went again by itself, no tap needed
    expect(calls.where((c) => c.endsWith('/media')), hasLength(2));

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('discard')));
    await tester.pumpAndSettle();
    final refused = await open(tester, fails: (n) => true, failStatus: 413, waits: const [Duration(seconds: 2)]);
    await pick(tester, find.text('Алдынан *'));
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(refused.where((c) => c.endsWith('/media')), hasLength(1)); // too large stays too large
  });

  testWidgets('a 360° set goes three frames at a time, so weak mobile data is not choked', (tester) async {
    final gate = Completer<void>();
    final calls = await open(tester, hold: gate.future);
    await tester.tap(find.text('Галереядан'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(maxInFlight, 3);
    gate.complete();
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.endsWith('/media')), hasLength(24));
    expect(maxInFlight, 3);
    expect(find.text('24/24'), findsOneWidget);
  });

  testWidgets('a side photo taken while a 360° set is uploading goes ahead of the frames still waiting',
      (tester) async {
    final gate = Completer<void>();
    await open(tester, hold: gate.future);
    await tester.tap(find.text('Галереядан'));
    await tester.pump();
    await tester.tap(find.text('Алдынан *'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200)); // the sheet slides up; the frames keep spinning
    }
    await tester.tap(find.text('Камерамен түсіру'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    gate.complete();
    await tester.pumpAndSettle();
    expect(uploadOrder, hasLength(25));
    expect(uploadOrder.indexOf('p.jpg'), 3); // right after the three frames already on their way
  });

  testWidgets('a new 360° set replaces one still on its way: the old frames waiting their turn are not sent',
      (tester) async {
    final gate = Completer<void>();
    final calls = await open(tester, hold: gate.future);
    await tester.tap(find.text('Галереядан'));
    await tester.pump();
    await tester.tap(find.text('Галереядан'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    gate.complete();
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.endsWith('/media')), hasLength(27)); // 3 already on their way + the new 24
    expect(maxInFlight, 3);
    expect(find.text('24/24'), findsOneWidget);

    maxInFlight = 0; // a third set, after the others finished, still goes three at a time
    await tester.tap(find.text('Галереядан'));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.endsWith('/media')), hasLength(51));
    expect(maxInFlight, 3);
  });

  testWidgets('a side photo the server refused is taken again with a tap, the camera opens', (tester) async {
    final calls = await open(tester, fails: (n) => n == 1, failStatus: 413);
    await pickSides(tester);
    await next(tester);
    expect(find.text('Фото қабылданбады. Белгісі бар фотоны басып, басқасын түсіріңіз.'), findsNothing);
    expect(step(tester), 'Фото');
    expect(find.bySemanticsLabel(RegExp('^Алдынан фотосы жүктелмеді')), findsOneWidget);
    await tester.tap(find.text('Алдынан *'));
    await tester.pumpAndSettle();
    expect(find.text('Камерамен түсіру'), findsOneWidget); // refused stays refused: another photo is needed
    await tester.tap(find.text('Камерамен түсіру'));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.endsWith('/media')), hasLength(5));
    await next(tester);
    expect(step(tester), 'Тауар туралы');
  });

  /// Fills the pair step with a worn pair, as a seller would.
  Future<void> fillDetails(WidgetTester tester, {String condition = 'Киілген, жақсы'}) async {
    await tester.enterText(find.widgetWithText(TextFormField, 'Атауы'), 'Qadam етік');
    await choose(tester, find.byKey(const Key('audience')), 'Әйелдерге');
    await choose(tester, find.byKey(const ValueKey('category-null')), 'Етік, бәтеңке');
    await tester.tap(find.byKey(const Key('color-ақ')));
    await tester.pump();
    await choose(tester, find.text('Жаңа, қорабымен'), condition);
    await tester.enterText(find.widgetWithText(TextFormField, 'Ақаулары'), 'Өкшесі сәл тозған');
  }

  testWidgets('a worn pair needs its defects written, a photo only when it is defective; a draft is not published',
      (tester) async {
    final sent = <Map<String, dynamic>>[];
    final calls = await open(tester, sent: sent);
    await pickSides(tester);
    await next(tester);
    await fillDetails(tester);
    await next(tester);
    expect(step(tester), 'Бағасы мен өлшемі'); // same rule as the server: the text is enough for a worn pair
    await tester.enterText(find.widgetWithText(TextFormField, 'Бағасы'), '20000');
    await tester.enterText(find.widgetWithText(TextFormField, 'Өлшем'), '38');
    await tester.enterText(find.widgetWithText(TextFormField, 'Ұлтарақ, см'), '24,5');
    await tester.tap(find.text('Жоба ретінде сақтау'));
    await tester.pumpAndSettle();
    expect(sent.single, containsPair('condition', 'used_good'));
    expect(calls.where((c) => c.endsWith('/publish')), isEmpty);
    expect(find.text('Жоба ретінде сақталды'), findsOneWidget);
  });

  testWidgets('a defect photo that did not upload is sent again with a tap on it', (tester) async {
    await open(tester, fails: (n) => n == 5);
    await pickSides(tester);
    await next(tester);
    await fillDetails(tester, condition: 'Ақауы бар');
    await pick(tester, find.text('Ақау фотосы'));
    await next(tester);
    expect(find.text('Кейбір фото жүктелмеді. Белгісі бар фотоны басып, қайта жіберіңіз.'), findsOneWidget);
    expect(step(tester), 'Тауар туралы');
    await tester.tap(find.text('Ақау'));
    await tester.pumpAndSettle();
    await next(tester);
    expect(step(tester), 'Бағасы мен өлшемі');
  });

  testWidgets('a defect photo the server refused goes, and another is asked for', (tester) async {
    final calls = await open(tester, fails: (n) => n == 5, failStatus: 413);
    await pickSides(tester);
    await next(tester);
    await fillDetails(tester, condition: 'Ақауы бар');
    await pick(tester, find.text('Ақау фотосы'));
    await tester.tap(find.text('Ақау'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Камерамен түсіру'));
    await tester.pumpAndSettle();
    expect(find.text('Ақау'), findsOneWidget); // the refused one is gone, the new one took its place
    expect(calls.where((c) => c.endsWith('/media')), hasLength(6));
    await next(tester);
    expect(step(tester), 'Бағасы мен өлшемі');
  });

  testWidgets('360° frames that did not upload are caught on the photo step and sent again, not shot again',
      (tester) async {
    final calls = await open(tester, fails: (n) => n > 4 && n <= 16); // half the frames fail
    await pickSides(tester);
    await tester.tap(find.text('Галереядан'));
    await tester.pumpAndSettle();
    await next(tester);
    expect(find.text('Кейбір кадрлар жүктелмеді. Қайта түсірудің керегі жоқ, тек қайта жіберіңіз.'),
        findsWidgets); // on the card, and as the reason
    expect(step(tester), 'Фото');
    await tester.tap(find.byKey(const Key('resend-frames')));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.endsWith('/media')), hasLength(40)); // only the 12 that failed go again
    expect(find.text('24/24'), findsOneWidget);
    await next(tester);
    expect(step(tester), 'Тауар туралы');
  });

  testWidgets('a photo that fails after Next takes the seller back to the photos to send it again', (tester) async {
    final upload = Completer<void>();
    final sent = <Map<String, dynamic>>[];
    await open(tester, sent: sent, fails: (n) => n == 4, failLater: upload.future);
    for (final label in ['Алдынан', 'Сырт бүйірі', 'Ішкі бүйірі']) {
      await pick(tester, find.text('$label *'));
    }
    await tester.tap(find.text('Өкшесі *'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Камерамен түсіру'));
    await tester.pump(const Duration(milliseconds: 500)); // the last photo is still on its way
    await next(tester);
    await fillDetails(tester);
    await next(tester);
    upload.complete(); // and then it fails
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Бағасы'), '20000');
    await tester.enterText(find.widgetWithText(TextFormField, 'Өлшем'), '38');
    await tester.enterText(find.widgetWithText(TextFormField, 'Ұлтарақ, см'), '24,5');
    await tester.tap(find.text('Жариялау'));
    await tester.pumpAndSettle();
    expect(step(tester), 'Фото');
    expect(sent, isEmpty);
  });

  testWidgets('on a usual phone the size rows keep their words whole', (tester) async {
    await loadFonts(tester); // the app's own font: the test font is far wider
    await open(tester, width: 360);
    await pickSides(tester);
    await next(tester);
    await fillDetails(tester);
    await next(tester);
    expect(step(tester), 'Бағасы мен өлшемі');
    await tester.tap(find.text('Өлшем қосу'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('remove-size-1')), findsOneWidget); // a second size can be taken away again
    final cut = [
      for (final e in find.byType(RichText).evaluate())
        if ((e.renderObject! as RenderParagraph).didExceedMaxLines) (e.widget as RichText).text.toPlainText(),
    ];
    expect(cut, isEmpty);
  });

  testWidgets('a similar listing starts from the details of another, without its photos', (tester) async {
    await open(tester, template: Listing.fromJson(listingJson()));
    expect(find.text('Ұқсас тауар'), findsOneWidget);
    expect(find.byKey(const Key('template-note')), findsOneWidget);
    expect(find.byType(Image), findsNothing); // photos are of another pair
    await pickSides(tester);
    await next(tester);
    expect(find.widgetWithText(TextFormField, 'Nike Air Force 1'), findsOneWidget);
    expect(find.text('Ерлерге де, әйелдерге де'), findsOneWidget);
    await next(tester);
    expect(find.widgetWithText(TextFormField, '45000'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, '43'), findsOneWidget); // every size row came along
  });

  test('insole centimetres are read as sellers type them', () {
    expect(insoleCheck('27,5'), isNull);
    expect(insoleCheck('27.5'), isNull);
    expect(insoleCheck('8'), isNull); // a baby's first shoes
    expect(insoleCheck('36'), isNotNull);
  });
}
