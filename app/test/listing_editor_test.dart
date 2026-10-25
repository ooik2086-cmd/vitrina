import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vitrina/api.dart';
import 'package:vitrina/screens/listing_editor_screen.dart';
import 'package:vitrina/session.dart';
import 'package:vitrina/theme.dart';

import 'support/screens.dart' show loadFonts;

/// What every pick hands back: a few bytes that are not a picture, unless a test gives a real photo; [pickQueue],
/// when not empty, gives the next picks their own photos.
var pickedBytes = utf8.encode('jpeg bytes');
final pickQueue = <List<int>>[];

/// Every pick hands back the same small photo, as if taken with the camera.
class _FakePicker extends ImagePickerPlatform {
  @override
  Future<XFile?> getImageFromSource(
          {required ImageSource source, ImagePickerOptions options = const ImagePickerOptions()}) async =>
      XFile.fromData(Uint8List.fromList(pickQueue.isEmpty ? pickedBytes : pickQueue.removeAt(0)),
          name: 'p.jpg', path: '/picked/p.jpg');

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

/// The listing the server makes of what the editor sent, as the server answers it.
Map<String, dynamic> madeFrom(Map<String, dynamic> body, String status) => {
      ...listingJson(status: status),
      for (final k in ['title', 'price_tiyn', 'delivery_price_tiyn', 'condition']) k: body[k],
      'sizes': [
        for (final (i, s) in (body['sizes'] as List).indexed)
          {'id': i + 1, 'label': s['label'], 'insole_cm': s['insole_cm'], 'available': true, 'quantity': s['quantity']}
      ],
      'media': [
        for (final p in body['photos'] as List) {'original_url': p['url'], 'angle': p['angle']}
      ],
    };

/// The most photo uploads that were on their way at once, in the last editor opened.
var maxInFlight = 0;

/// The file names of photo uploads, in the order they reached the server.
final uploadOrder = <String>[];

void main() {
  setUp(() {
    ImagePickerPlatform.instance = _FakePicker();
    pickedBytes = utf8.encode('jpeg bytes');
    pickQueue.clear();
    SharedPreferences.setMockInitialValues({});
  });

  Future<Map<String, dynamic>?> kept() async {
    final raw = (await SharedPreferences.getInstance()).getString(Session.editorDraftKey);
    return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
  }

  /// Opens the editor from a screen underneath, as the app does, and records what reaches the server.
  Future<List<String>> open(WidgetTester tester,
      {Listing? template,
      List<Map<String, dynamic>>? sent,
      bool Function(int upload)? fails,
      int failStatus = 500,
      Future<void>? failLater,
      Future<void>? hold,
      List<Duration> waits = const [],
      double width = 500,
      bool settle = true,
      int? me,
      List<String>? keys,
      bool Function(int create)? createLost,
      String madeStatus = 'draft'}) async {
    final calls = <String>[];
    var uploads = 0, inFlight = 0, creates = 0;
    final made = <String, Map<String, dynamic>>{}; // what each key made: the server answers it again
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
          keys?.add(req.headers['Idempotency-Key'] ?? '');
          final key = req.headers['Idempotency-Key'];
          final listing = (key == null ? null : made[key]) ?? madeFrom(jsonDecode(req.body), madeStatus);
          if (key != null) made[key] = listing;
          // The listing is made, but its answer is lost on the way back.
          if (createLost?.call(++creates) ?? false) throw http.ClientException('connection reset');
          return jsonResponse(listing, 201);
        }))
      ..uploadWaits = waits;
    tester.view.physicalSize = Size(width, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(SessionScope(
        session: Session(api)
          ..me = me == null ? null : Me.fromJson({'id': me, 'phone': '+77010000000', 'is_seller': true}),
        child: MaterialApp(
            theme: buildTheme(Brightness.light),
            home: Scaffold(
                body: Builder(
                    builder: (context) => TextButton(
                        onPressed: () => Navigator.of(context)
                            .push(MaterialPageRoute(builder: (_) => ListingEditorScreen(template: template))),
                        child: const Text('open')))))));
    await tester.tap(find.text('open'));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump(const Duration(seconds: 1)); // a photo read from the phone keeps its tile spinning
    }
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
    await tester.tap(find.text('Сатылымға шығару'));
    await tester.pumpAndSettle();
    expect(find.text('Бағаны енгізіңіз'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, 'Ішкі табан, см'), '5');
    await tester.tap(find.text('Сатылымға шығару'));
    await tester.pumpAndSettle();
    expect(find.text('8–35 см аралығында болуы керек'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, 'Ішкі табан, см'), 'жиырма');
    await tester.tap(find.text('Сатылымға шығару'));
    await tester.pumpAndSettle();
    expect(find.text('Санмен жазыңыз, мысалы 27,5'), findsOneWidget);
    expect(calls.where((c) => c == 'POST /api/v1/listings'), isEmpty); // nothing was sent while anything was wrong

    await tester.enterText(find.widgetWithText(TextFormField, 'Бағасы'), '34900');
    await tester.enterText(find.widgetWithText(TextFormField, 'Өлшем'), '38');
    await tester.enterText(find.widgetWithText(TextFormField, 'Ішкі табан, см'), '24,5');
    await tester.tap(find.text('Сатылымға шығару'));
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
    // A new pair is kept on this phone: leaving loses nothing, so the question does not say «without saving».
    expect(find.text('Шығу керек пе?'), findsOneWidget);
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

  testWidgets('«continue later» keeps the work at once, and the next «add» offers it back', (tester) async {
    await open(tester);
    await pick(tester, find.text('Алдынан *'));
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('later')));
    await tester.pumpAndSettle();
    expect(find.byType(ListingEditorScreen), findsNothing);
    expect(await kept(), isNotNull, reason: 'kept as the page goes, not a second later');
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('restored-note')), findsOneWidget);
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
    await tester.enterText(find.widgetWithText(TextFormField, 'Ішкі табан, см'), '24,5');
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
    await tester.enterText(find.widgetWithText(TextFormField, 'Ішкі табан, см'), '24,5');
    await tester.tap(find.text('Сатылымға шығару'));
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

  /// Lets the photo's colour be read: decoding a real picture takes real time.
  Future<void> readPhotos(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  testWidgets('the side photo suggests the colour: one tap on Иә, and the listing is that colour', (tester) async {
    pickedBytes = File('demo/media/1/07992a536638a99986f39bb59fc48ba8.jpg').readAsBytesSync(); // a blue pair
    final sent = <Map<String, dynamic>>[];
    await open(tester, sent: sent);
    await pickSides(tester);
    await readPhotos(tester);
    await next(tester);
    expect(step(tester), 'Тауар туралы');
    expect(find.text('Көк пе?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('color-yes')));
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextFormField, 'Атауы'), 'Qadam кроссовка');
    await choose(tester, find.byKey(const Key('audience')), 'Әйелдерге');
    await choose(tester, find.byKey(const ValueKey('category-null')), 'Кроссовкалар');
    await next(tester);
    expect(step(tester), 'Бағасы мен өлшемі');
    await tester.enterText(find.widgetWithText(TextFormField, 'Бағасы'), '30000');
    await tester.enterText(find.widgetWithText(TextFormField, 'Өлшем'), '38');
    await tester.enterText(find.widgetWithText(TextFormField, 'Ішкі табан, см'), '24');
    await tester.tap(find.text('Сатылымға шығару'));
    await tester.pumpAndSettle();
    expect(sent.single['color'], 'көк');
  });

  testWidgets('a similar pair keeps the copied colour until the photo shows another, then asks', (tester) async {
    pickedBytes = File('demo/media/1/07992a536638a99986f39bb59fc48ba8.jpg').readAsBytesSync();
    await open(tester, template: Listing.fromJson(listingJson())); // a white pair
    await pickSides(tester);
    await readPhotos(tester);
    await next(tester);
    expect(find.text('Көк пе?'), findsOneWidget); // another colour of the same shoe is why one copies it
    await next(tester);
    expect(step(tester), 'Тауар туралы'); // unanswered, the copied white is not saved unseen
    await tester.tap(find.byKey(const Key('color-no')));
    await tester.pump();
    expect(tester.widget<ChoiceChip>(find.byKey(const Key('color-ақ'))).selected, isTrue); // the list, white picked

    // Back to the photos and on again: answered once, not asked again.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(step(tester), 'Фото');
    await next(tester);
    expect(find.byKey(const Key('color-guess')), findsNothing);
  });

  testWidgets('the outer side photo decides the colour; a front photo taken after it does not', (tester) async {
    final blue = File('demo/media/1/07992a536638a99986f39bb59fc48ba8.jpg').readAsBytesSync();
    final pink = File('demo/media/1/1b3b2efb9ca638b707837c452fa6cc1f.jpg').readAsBytesSync();
    await open(tester);
    pickQueue.add(pink);
    await pick(tester, find.text('Алдынан *'));
    await readPhotos(tester);
    pickQueue.addAll([blue, blue, blue, pink]);
    await pick(tester, find.text('Сырт бүйірі *'));
    await pick(tester, find.text('Ішкі бүйірі *'));
    await pick(tester, find.text('Өкшесі *'));
    await pick(tester, find.text('Алдынан *')); // taken again
    await readPhotos(tester);
    await next(tester);
    expect(find.text('Көк пе?'), findsOneWidget);
  });

  testWidgets('kept photos from before ask the colour again while none is set', (tester) async {
    final dir = Directory.systemTemp.createTempSync('kept');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/outer.jpg')
      ..writeAsBytesSync(File('demo/media/1/07992a536638a99986f39bb59fc48ba8.jpg').readAsBytesSync());
    SharedPreferences.setMockInitialValues({
      Session.editorDraftKey: jsonEncode({
        'photos': {
          for (final a in requiredAngles.keys) a: {'path': file.path}
        }
      })
    });
    await open(tester, settle: false);
    await readPhotos(tester);
    await next(tester);
    expect(find.text('Көк пе?'), findsOneWidget);
  });

  testWidgets('a photo that is not a picture asks nothing: the colours are listed as before', (tester) async {
    await open(tester);
    await pickSides(tester);
    await readPhotos(tester);
    await next(tester);
    expect(find.byKey(const Key('color-guess')), findsNothing);
    expect(find.byKey(const Key('color-көк')), findsOneWidget);
  });

  testWidgets('what the pair is made of is picked, not typed; a boot asks its height, a sneaker does not',
      (tester) async {
    final sent = <Map<String, dynamic>>[];
    await open(tester, sent: sent);
    await pickSides(tester);
    await next(tester);
    await tester.enterText(find.widgetWithText(TextFormField, 'Атауы'), 'Qadam етік');
    await choose(tester, find.byKey(const Key('audience')), 'Әйелдерге');
    await tester.tap(find.byKey(const Key('color-ақ')));
    await tester.pump();
    expect(find.byKey(const ValueKey('fact-shaft-null')), findsNothing); // no kind yet: the five every pair has
    await choose(tester, find.byKey(const ValueKey('category-null')), 'Етік, бәтеңке');
    await choose(tester, find.byKey(const ValueKey('fact-upper-null')), 'Күдері');
    await choose(tester, find.byKey(const ValueKey('fact-country-null')), 'Түркия');
    await choose(tester, find.byKey(const ValueKey('fact-shaft-null')), 'Тізеге дейін');
    await choose(tester, find.byKey(const ValueKey('fact-country-TR')), 'Бос қалдыру'); // changed their mind
    // Filed as sneakers after all: a boot's height goes, what it is made of stays.
    await choose(tester, find.byKey(const ValueKey('category-boots')), 'Кроссовкалар');
    expect(find.byKey(const ValueKey('fact-shaft-knee')), findsNothing);
    await next(tester);
    await tester.enterText(find.widgetWithText(TextFormField, 'Бағасы'), '30000');
    await tester.enterText(find.widgetWithText(TextFormField, 'Өлшем'), '38');
    await tester.enterText(find.widgetWithText(TextFormField, 'Ішкі табан, см'), '24');
    await tester.tap(find.text('Сатылымға шығару'));
    await tester.pumpAndSettle();
    expect(sent.single['facts'], {'upper': 'suede'});
  });

  testWidgets('a similar pair starts with the facts of the other: the same shoe is made of the same', (tester) async {
    final sent = <Map<String, dynamic>>[];
    await open(tester,
        sent: sent,
        template: Listing.fromJson({
          ...listingJson(),
          'facts': {'upper': 'leather', 'season': 'demi'}
        }));
    await pickSides(tester);
    await next(tester);
    expect(find.byKey(const ValueKey('fact-upper-leather')), findsOneWidget);
    await next(tester);
    await tester.tap(find.text('Сатылымға шығару'));
    await tester.pumpAndSettle();
    expect(sent.single['facts'], {'upper': 'leather', 'season': 'demi'});
  });

  test('insole centimetres are read as sellers type them', () {
    expect(insoleCheck('27,5'), isNull);
    expect(insoleCheck('27.5'), isNull);
    expect(insoleCheck('8'), isNull); // a baby's first shoes
    expect(insoleCheck('36'), isNotNull);
  });

  testWidgets('a new pair not yet saved survives the app closing: it opens where the seller stopped', (tester) async {
    await open(tester);
    await pickSides(tester);
    await next(tester);
    await tester.enterText(find.widgetWithText(TextFormField, 'Атауы'), 'Qadam етік');
    await tester.pump(const Duration(seconds: 2));
    expect((await kept())!['title'], 'Qadam етік');

    await tester.pumpWidget(const SizedBox()); // the app was closed
    final calls = await open(tester); // and opened again
    expect(find.byKey(const Key('restored-note')), findsOneWidget);
    expect(step(tester), 'Тауар туралы');
    expect(find.text('Qadam етік'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(step(tester), 'Фото');
    expect(find.bySemanticsLabel(RegExp('жүктелмеді')), findsNothing);
    expect(calls.where((c) => c.endsWith('/media')), isEmpty); // the photos that went are not sent twice
    await next(tester);
    expect(step(tester), 'Тауар туралы');
    expect(find.byKey(const Key('restored-note')), findsNothing); // said once, then out of the way
  });

  testWidgets('starting over clears the kept work and the page', (tester) async {
    await open(tester);
    await pickSides(tester);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpWidget(const SizedBox());
    await open(tester);
    await tester.tap(find.byKey(const Key('start-over')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Қалу')); // one tap does not throw a pair away: it asks first
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('restored-note')), findsOneWidget);
    expect(await kept(), isNotNull);
    await tester.tap(find.byKey(const Key('start-over')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('start-over-sure')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('restored-note')), findsNothing);
    expect(find.text('Алдынан *'), findsOneWidget);
    await next(tester);
    expect(step(tester), 'Фото'); // the four sides are gone
    expect(await kept(), isNull);
  });

  testWidgets('saved, or thrown away on purpose, the work is not offered again', (tester) async {
    final sent = <Map<String, dynamic>>[];
    await open(tester, sent: sent);
    await pickSides(tester);
    await next(tester);
    await fillDetails(tester);
    await next(tester);
    await tester.enterText(find.widgetWithText(TextFormField, 'Бағасы'), '20000');
    await tester.enterText(find.widgetWithText(TextFormField, 'Өлшем'), '38');
    await tester.enterText(find.widgetWithText(TextFormField, 'Ішкі табан, см'), '24,5');
    await tester.pump(const Duration(seconds: 2));
    expect(await kept(), isNotNull);
    await tester.tap(find.text('Жоба ретінде сақтау'));
    await tester.pumpAndSettle();
    expect(sent, hasLength(1));
    expect(await kept(), isNull);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('restored-note')), findsNothing);
    await pick(tester, find.text('Алдынан *'));
    await tester.pump(const Duration(seconds: 2));
    expect(await kept(), isNotNull);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('discard')));
    await tester.pumpAndSettle();
    expect(await kept(), isNull);
  });

  testWidgets('when the phone sends the app to the background, the work is kept at once', (tester) async {
    await open(tester);
    await pick(tester, find.text('Алдынан *'));
    expect(await kept(), isNull);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect((await kept())!['photos'], {
      'front': {'url': 'https://cdn/1.jpg', 'path': '/picked/p.jpg'}
    });
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('a photo still on its way when the app closed is sent again from the phone', (tester) async {
    final dir = Directory.systemTemp.createTempSync('kept');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/front.jpg')..writeAsBytesSync(utf8.encode('jpeg bytes'));
    final gate = Completer<void>();
    await open(tester, hold: gate.future);
    await pick(tester, find.text('Алдынан *'));
    await tester.pump(const Duration(seconds: 2));
    expect((await kept())!['photos'], {
      'front': {'path': '/picked/p.jpg'}
    }); // not yet sent: kept by its file
    gate.complete();
    await tester.pumpWidget(const SizedBox());

    SharedPreferences.setMockInitialValues({
      Session.editorDraftKey: jsonEncode({
        'photos': {
          'front': {'path': file.path}
        },
        // Kept by a version that still took the photo-frame 360°: left behind, never sent nor waited on.
        'frames': [
          {'path': '/gone/f0.jpg'}
        ],
      })
    });
    final calls = await open(tester, settle: false);
    for (var i = 0; i < 10; i++) {
      // A real file is read in a few real steps (open, size, read, close); fake time lets each one land.
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.endsWith('/media')), hasLength(1));
    expect(find.bySemanticsLabel(RegExp('жүктелмеді')), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    expect((await kept())!['photos'], {
      'front': {'url': 'https://cdn/1.jpg', 'path': file.path}
    });
    expect((await kept())!.containsKey('frames'), isFalse);
  });

  testWidgets('kept work belongs to who made it: a lapsed sign-in keeps it, another person never sees it',
      (tester) async {
    await open(tester, me: 5);
    await pick(tester, find.text('Алдынан *'));
    await tester.pump(const Duration(seconds: 2));
    expect((await kept())!['owner'], 5);
    await Session(Api(base: 'http://x/api/v1')).signOut(); // the sign-in ran out; the same seller comes back
    await tester.pumpWidget(const SizedBox());
    await open(tester, me: 5);
    expect(find.byKey(const Key('restored-note')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await open(tester, me: 9);
    expect(find.byKey(const Key('restored-note')), findsNothing);
    expect(await kept(), isNull);
  });

  testWidgets('a copy of another listing never replaces or wipes a new pair kept from before', (tester) async {
    await open(tester);
    await pick(tester, find.text('Табаны'));
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpWidget(const SizedBox());

    await open(tester, template: Listing.fromJson(listingJson())); // opened and left untouched
    await tester.pageBack();
    await tester.pumpAndSettle();
    await open(tester, template: Listing.fromJson(listingJson())); // changed, then sent to the background
    await pick(tester, find.text('Алдынан *'));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump(const Duration(seconds: 2));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox());
    expect((await kept())!['photos'], {'sole': anything}); // still the new pair's own

    await open(tester);
    expect(find.byKey(const Key('restored-note')), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect((await kept())!['photos'], {'sole': anything});
  });

  testWidgets('everything on the three steps comes back: details, sizes and a defect photo', (tester) async {
    await open(tester);
    await pickSides(tester);
    await next(tester);
    await fillDetails(tester, condition: 'Ақауы бар');
    await pick(tester, find.text('Ақау фотосы'));
    await choose(tester, find.byKey(const ValueKey('fact-upper-null')), 'Күдері');
    await choose(tester, find.byKey(const ValueKey('fact-shaft-null')), 'Тізеге дейін');
    await next(tester);
    await tester.enterText(find.widgetWithText(TextFormField, 'Бағасы'), '20000');
    await tester.enterText(find.widgetWithText(TextFormField, 'Өлшем'), '38');
    await tester.enterText(find.widgetWithText(TextFormField, 'Ішкі табан, см'), '24,5');
    await tester.pump(const Duration(seconds: 2));
    final before = await kept();
    await tester.pumpWidget(const SizedBox());

    final sent = <Map<String, dynamic>>[];
    final calls = await open(tester, sent: sent);
    expect(step(tester), 'Бағасы мен өлшемі');
    expect(find.text('20000'), findsOneWidget);
    expect(find.text('24,5'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect((await kept())!..remove('kept_at'), before!..remove('kept_at')); // the same work, nothing lost
    await tester.tap(find.text('Сатылымға шығару'));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.endsWith('/media')), isEmpty);
    final body = sent.single;
    expect(body, containsPair('condition', 'defective'));
    expect(body, containsPair('category', 'boots'));
    expect(body, containsPair('audience', 'women'));
    expect(body, containsPair('title', 'Qadam етік'));
    expect(body['facts'], {'upper': 'suede', 'shaft': 'knee'});
    expect(body['sizes'], [
      {'label': '38', 'insole_cm': '24,5', 'quantity': 1}
    ]);
    final angles = [for (final p in body['photos'] as List) (p as Map)['angle']];
    expect(angles.where((a) => a == 'frame'), isEmpty);
    expect(angles.where((a) => a == 'defect'), hasLength(1));
    expect(angles.toSet(), containsAll(requiredAngles.keys));
    expect(await kept(), isNull);
  });

  testWidgets('work emptied again by hand is not offered next time', (tester) async {
    SharedPreferences.setMockInitialValues({
      Session.editorDraftKey: jsonEncode({'step': 1, 'title': 'Ойланып жүрмін'})
    });
    await open(tester);
    expect(step(tester), 'Тауар туралы');
    await tester.enterText(find.widgetWithText(TextFormField, 'Атауы'), '');
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    expect(await kept(), isNull); // the page is blank again
  });

  testWidgets('a photo address kept for a week is not trusted: the server may have cleared it', (tester) async {
    SharedPreferences.setMockInitialValues({
      Session.editorDraftKey: jsonEncode({
        'kept_at': 0,
        'title': 'Ескі жұмыс',
        'photos': {
          'front': {'url': 'https://cdn/old.jpg'}
        }
      })
    });
    await open(tester);
    expect(find.byKey(const Key('restored-note')), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Қалу'));
    await tester.pumpAndSettle();
    await pick(tester, find.text('Сырт бүйірі *'));
    await pick(tester, find.text('Ішкі бүйірі *'));
    await pick(tester, find.text('Өкшесі *'));
    await next(tester);
    expect(find.text('Фото жетіспейді: Алдынан.'), findsOneWidget); // the old one is asked for again
  });

  testWidgets('work kept by another version that cannot be read gives a clean page, not half of it', (tester) async {
    SharedPreferences.setMockInitialValues({
      Session.editorDraftKey: jsonEncode({
        'title': 'Жартысы',
        'sizes': [
          [38, 24, 1]
        ]
      })
    });
    await open(tester);
    expect(find.byKey(const Key('restored-note')), findsNothing);
    expect(find.text('Жартысы'), findsNothing);
    expect(await kept(), isNull);
    await pickSides(tester);
    await next(tester);
    expect(find.text('Жартысы'), findsNothing); // not even the title that could be read
    await fillDetails(tester);
    await next(tester);
    await tester.enterText(find.widgetWithText(TextFormField, 'Өлшем'), '38'); // the size row works
    await tester.pump();
  });

  /// Fills all three steps of a new pair and stops before saving.
  Future<void> fillAll(WidgetTester tester) async {
    await pickSides(tester);
    await next(tester);
    await fillDetails(tester);
    await next(tester);
    await tester.enterText(find.widgetWithText(TextFormField, 'Бағасы'), '20000');
    await tester.enterText(find.widgetWithText(TextFormField, 'Өлшем'), '38');
    await tester.enterText(find.widgetWithText(TextFormField, 'Ішкі табан, см'), '24,5');
  }

  testWidgets('weak mobile data: Publish pressed again after a lost answer sends the same key, so one listing',
      (tester) async {
    final keys = <String>[];
    final calls = await open(tester, keys: keys, createLost: (n) => n == 1);
    await fillAll(tester);
    await tester.tap(find.text('Сатылымға шығару'));
    await tester.pumpAndSettle();
    expect(find.text('Байланыс жоқ. Интернетті тексеріп, қайталап көріңіз.'), findsOneWidget);
    expect(find.text('Сатылымға шығару'), findsOneWidget); // still on the page, nothing lost
    await tester.tap(find.text('Сатылымға шығару'));
    await tester.pumpAndSettle();
    expect(keys, hasLength(2));
    expect(keys.first, matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(keys.last, keys.first); // the server answers the second try with the listing the first one made
    expect(calls.where((c) => c.endsWith('/publish')), hasLength(1));
    expect(find.byType(ListingEditorScreen), findsNothing); // done: back on the page underneath
  });

  testWidgets('a pair changed after a lost answer is not made twice, nor published at the old price', (tester) async {
    final keys = <String>[];
    final calls = await open(tester, keys: keys, createLost: (n) => n == 1);
    await fillAll(tester);
    await tester.tap(find.text('Сатылымға шығару'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Бағасы'), '18000');
    tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger)).clearSnackBars(); // read and gone
    await tester.tap(find.text('Сатылымға шығару'));
    await tester.pumpAndSettle();
    expect(keys, hasLength(2));
    expect(keys.last, keys.first); // the same pair: the server answers with the listing it made the first time
    expect(calls.where((c) => c.endsWith('/publish')), isEmpty); // made at 20 000, so not published from here
    expect(find.text('Бұл тауар бұрын сақталған. Өзгерістерді «Менің тауарларым» бетінде енгізіңіз.'), findsOneWidget);
    expect(find.byType(ListingEditorScreen), findsNothing);
  });

  testWidgets('saved as a draft with the answer lost, then published: one listing, published once', (tester) async {
    final keys = <String>[];
    final calls = await open(tester, keys: keys, createLost: (n) => n == 1);
    await fillAll(tester);
    await tester.tap(find.text('Жоба ретінде сақтау'));
    await tester.pumpAndSettle();
    expect(find.byType(ListingEditorScreen), findsOneWidget);
    await tester.tap(find.text('Сатылымға шығару'));
    await tester.pumpAndSettle();
    expect(keys, hasLength(2));
    expect(keys.last, keys.first);
    expect(calls.where((c) => c.endsWith('/publish')), hasLength(1));
  });

  testWidgets('a lost answer to a listing already sent for checking is not published twice', (tester) async {
    final calls = await open(tester, madeStatus: 'moderation');
    await fillAll(tester);
    await tester.tap(find.text('Сатылымға шығару'));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.endsWith('/publish')), isEmpty);
    expect(find.text('Тексеруге жіберілді'), findsOneWidget);
  });

  testWidgets('the same pair keeps its key after the app closed, and starting over gives a new one', (tester) async {
    final keys = <String>[];
    await open(tester, keys: keys, createLost: (n) => n == 1);
    await fillAll(tester);
    await tester.tap(find.text('Сатылымға шығару'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpWidget(const SizedBox()); // the app closed with the answer lost

    await open(tester, keys: keys);
    await tester.tap(find.text('Сатылымға шығару'));
    await tester.pumpAndSettle();
    expect(keys, hasLength(2));
    expect(keys.last, keys.first);

    SharedPreferences.setMockInitialValues({
      Session.editorDraftKey: jsonEncode({'title': 'Ескі', 'save_key': 'a' * 32})
    });
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('start-over')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('start-over-sure')));
    await tester.pumpAndSettle();
    await fillAll(tester);
    await tester.tap(find.text('Сатылымға шығару'));
    await tester.pumpAndSettle();
    expect(keys, hasLength(3));
    expect(keys.last, isNot(startsWith('a' * 32)));
    expect(keys.last.split('-').first, isNot(keys.first.split('-').first));
  });
}
