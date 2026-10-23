import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vitrina/api.dart';
import 'package:vitrina/screens/listing_screen.dart';
import 'package:vitrina/session.dart';
import 'package:vitrina/viewer_host_io.dart';
import 'package:vitrina/widgets/color_choice.dart';
import 'package:vitrina/widgets/spin_viewer.dart' show PhotoGallery;
import 'package:vitrina/widgets/model_stage.dart';
import 'package:vitrina/widgets/video_pane.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'support/fake_video.dart';

/// The 3D page as a test sees it: the scripts the stage runs in it, and what it answers.
class FakeView implements ModelView {
  final scripts = <String>[];
  Object? answer;

  @override
  final Widget widget = const ColoredBox(key: Key('fake-3d'), color: Color(0xFF123456));

  @override
  Future<void> run(String script) async => scripts.add(script);

  @override
  Future<Object?> read(String script) async => answer;

  bool disposed = false;

  @override
  void dispose() => disposed = true;
}

/// Stands in for the WebView: each stage made gets its own [FakeView], and the test posts the page's messages.
class FakeMaker {
  final views = <FakeView>[];
  final sends = <void Function(String)>[];
  Brightness? scene;
  bool none = false;

  Future<ModelView?> make(Brightness scene, void Function(String) onMessage) async {
    this.scene = scene;
    if (none) return null;
    sends.add(onMessage);
    final view = FakeView();
    views.add(view);
    return view;
  }

  void post(Map<String, Object?> message) => sends.last(jsonEncode(message));
}

http.Response jsonResponse(Object body) =>
    http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});

Map<String, dynamic> media(String angle, String name) => {
      'original_url': 'https://cdn/$name.jpg',
      'processed_url': null,
      'thumb_url': 'https://cdn/$name-s.webp',
      'angle': angle,
    };

Map<String, dynamic> colorway(int id, String color, {bool current = false}) => {
      'id': id,
      'color': color,
      'price_tiyn': 2990000,
      'current': current,
      'in_stock': true,
      'thumb_url': 'https://cdn/c$id-s.webp',
      'cutout': true,
    };

const model = {'url': 'https://cdn/shoe-1024.glb', 'hq_url': 'https://cdn/shoe-2048.glb'};

Map<String, dynamic> listing(int id,
        {String color = 'көк', String? variant = 'midnight', bool withModel = true, bool withVideo = false}) =>
    {
      'id': id,
      'status': 'published',
      'title': 'Кроссовка $color',
      'category': 'sneakers',
      'brand': 'Runner',
      'model_name': '01',
      'color': color,
      'price_tiyn': 2990000,
      'delivery_price_tiyn': 0,
      'segment': null,
      'condition': 'new_no_box',
      'authenticity': 'unverified',
      'defects': null,
      'description': null,
      'showcase_style': 'clean',
      'backdrop': 'dark',
      'sizes': [
        {'id': id * 10 + 1, 'label': '41', 'insole_cm': '26,5', 'available': true},
        {'id': id * 10 + 2, 'label': '42', 'insole_cm': '27', 'available': true},
      ],
      'media': [media('outer', 'o$id'), media('front', 'f$id')],
      'seller': {'id': 3, 'shop_name': 'Qadam Store', 'city': 'Алматы'},
      'colors': [colorway(3, 'көк', current: id == 3), colorway(4, 'қызғылт', current: id == 4)],
      if (withModel) 'model': {...model, 'variant': variant},
      if (withVideo)
        'video': {
          'state': 'ready',
          'url': 'https://cdn.example/v$id.mp4',
          'poster_url': 'https://cdn.example/v$id.jpg',
          'seconds': 9
        },
    };

/// Starts the stage's server outside the test clock (a socket opens only in real time), so a page that loads in a
/// test is told its model at once.
Future<void> warmHost(WidgetTester tester) => tester.runAsync(() => ViewerHost.instance);

/// The page has loaded: the stage tells it what to show, which takes a real turn of the event loop (the server
/// started outside the test clock).
Future<void> pageLoaded(WidgetTester tester, FakeMaker maker) async {
  maker.post({'type': 'page'});
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
  await tester.pump();
}

void main() {
  late FakeMaker maker;
  final makeView = ModelStage.maker;
  final fetchModel = ViewerHost.fetch;
  setUp(() {
    maker = FakeMaker();
    ModelStage.maker = maker.make;
  });
  tearDown(() => ModelStage.maker = makeView);

  group('the 3D stage', () {
    final shoe = ListingModel.fromJson({...model, 'variant': 'midnight'});

    Future<void> stage(WidgetTester tester,
        {bool dark = false, bool paused = false, ListingModel? m, VoidCallback? onBroken, Key? key}) async {
      await tester.pumpWidget(MaterialApp(
        home: ModelStage(
            key: key,
            model: m ?? shoe,
            dark: dark,
            paused: paused,
            view: const [0.0, 0.0, 0.0, 1.0, 1.5],
            cover: const SizedBox(key: Key('cover')),
            onBroken: onBroken),
      ));
      await tester.pump();
    }

    testWidgets('the cover stands in until the first 3D picture, then the shoe shows', (tester) async {
      await stage(tester, dark: true);
      expect(maker.scene, Brightness.dark);
      expect(find.byKey(const Key('cover')), findsOneWidget);
      expect(find.byKey(const Key('model-loading')), findsOneWidget);
      expect(
          tester
              .widget<Opacity>(
                  find.ancestor(of: find.byKey(const Key('fake-3d')), matching: find.byType(Opacity)).first)
              .opacity,
          0);
      // The page loads, and is told which model, colour, scene and view to show.
      await tester.runAsync(() async {
        maker.post({'type': 'page'});
        for (var i = 0; i < 50 && maker.views.last.scripts.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      final load = maker.views.last.scripts.single;
      expect(load, startsWith('vitrina.load('));
      final args = jsonDecode(load.substring('vitrina.load('.length, load.length - 1)) as Map;
      expect(args['url'], matches(RegExp(r'^http://127\.0\.0\.1:\d+/[0-9a-f]{32}/m/[0-9a-f]+\.glb$')));
      expect(args['hq'], allOf(matches(RegExp(r'/m/[0-9a-f]+\.glb$')), isNot(args['url'])));
      expect((args['variant'], args['dark']), ('midnight', true));
      expect(args['view'], [0, 0, 0, 1, 1.5]);
      maker.post({'type': 'ready'});
      await tester.pump();
      expect(find.byKey(const Key('cover')), findsNothing);
      expect(
          tester
              .widget<Opacity>(
                  find.ancestor(of: find.byKey(const Key('fake-3d')), matching: find.byType(Opacity)).first)
              .opacity,
          1);
      expect(find.bySemanticsLabel(RegExp('3D')), findsOneWidget);
    });

    testWidgets('a 3D that cannot open leaves the cover and tells the page, once', (tester) async {
      var broken = 0;
      await stage(tester, onBroken: () => broken++);
      maker.post({'type': 'error', 'message': 'WebGL lost'});
      await tester.pump();
      expect(broken, 1);
      expect(find.byKey(const Key('cover')), findsOneWidget);
      expect(find.byKey(const Key('model-loading')), findsNothing);
      expect(find.byKey(const Key('fake-3d')), findsNothing);
      await tester.pump(ModelStage.patience);
      expect(broken, 1);
    });

    testWidgets('a sharper copy that fails after the shoe showed changes nothing', (tester) async {
      var broken = 0;
      await stage(tester, onBroken: () => broken++);
      maker.post({'type': 'ready'});
      maker.post({'type': 'error', 'message': 'hq 404'});
      await tester.pump();
      expect((broken, find.byKey(const Key('fake-3d')).evaluate().length), (0, 1));
    });

    testWidgets('no picture within the patience: the photos instead', (tester) async {
      var broken = 0;
      await stage(tester, onBroken: () => broken++);
      await tester.pump(ModelStage.patience - const Duration(seconds: 1));
      expect(broken, 0);
      await tester.pump(const Duration(seconds: 1));
      expect(broken, 1);
    });

    testWidgets('where there is no 3D at all, the page is told at once', (tester) async {
      maker.none = true;
      var broken = 0;
      await stage(tester, onBroken: () => broken++);
      expect(broken, 1);
    });

    testWidgets('the scene, the pause and the colour change in the open page, not by opening it again', (tester) async {
      await warmHost(tester);
      final key = GlobalKey<ModelStageState>();
      await stage(tester, key: key);
      await pageLoaded(tester, maker);
      maker.post({'type': 'ready'});
      await tester.pump();
      final view = maker.views.single;
      expect(view.scripts.single, startsWith('vitrina.load('));
      view.scripts.clear();
      await stage(tester, key: key, dark: true, paused: true, m: ListingModel.fromJson({...model, 'variant': 'beach'}));
      expect(view.scripts,
          ['vitrina.setVariant("beach", null)', 'vitrina.setBackground(true)', 'vitrina.setPaused(true)']);
      expect(maker.views, hasLength(1));
    });

    testWidgets('a colour made by tint goes with the load, and a new tint alone repaints the same 3D', (tester) async {
      await warmHost(tester);
      final key = GlobalKey<ModelStageState>();
      final red = {
        ...model,
        'variant': 'beach',
        'tint': [0, .62, .66],
      };
      await stage(tester, key: key, m: ListingModel.fromJson(red));
      await pageLoaded(tester, maker);
      maker.post({'type': 'ready'});
      await tester.pump();
      final view = maker.views.single;
      expect(view.scripts.single, contains('"tint":[0.0,0.62,0.66]'));
      view.scripts.clear();
      await stage(tester,
          key: key,
          m: ListingModel.fromJson({
            ...red,
            'tint': [145, .38, .58]
          }));
      expect(view.scripts, ['vitrina.setVariant("beach", [145.0,0.38,0.58])']);
      view.scripts.clear();
      await stage(tester,
          key: key,
          m: ListingModel.fromJson({
            ...red,
            'tint': [145, .38, .58]
          }));
      expect(view.scripts, isEmpty, reason: 'the same tint again is no change');
      await stage(tester, key: key, m: ListingModel.fromJson({...red, 'tint': 'red'}));
      expect(view.scripts, ['vitrina.setVariant("beach", null)'], reason: 'a tint that is not three numbers is none');
      // Out of range is brought in: hue round the circle, saturation 0–1, lightness factor 0–2.
      expect(
          ListingModel.fromJson({
            ...red,
            'tint': [-30, 1.5, 9]
          }).tint,
          [330, 1, 2]);
    });

    testWidgets('the phone taking the drawing back after the shoe showed brings the photos, and the page is left be',
        (tester) async {
      await warmHost(tester);
      var broken = 0;
      final key = GlobalKey<ModelStageState>();
      await stage(tester, key: key, onBroken: () => broken++);
      await pageLoaded(tester, maker);
      maker.post({'type': 'ready', 'load': 1});
      await tester.pump();
      maker.post({'type': 'lost', 'message': 'webgl context lost'});
      await tester.pump();
      expect(broken, 1);
      expect(find.byKey(const Key('fake-3d')), findsNothing);
      expect(find.byKey(const Key('cover')), findsOneWidget);
      final view = maker.views.single..scripts.clear();
      await stage(tester, key: key, dark: true, m: ListingModel.fromJson({...model, 'variant': 'beach'}));
      expect(view.scripts, isEmpty); // nothing more is asked of a page that cannot draw
      await tester.pumpWidget(const SizedBox());
      expect(view.disposed, isTrue);
    });

    testWidgets('a page opened over the stage stops its drawing; back on it, it draws again', (tester) async {
      await warmHost(tester);
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
          navigatorKey: nav,
          home: ModelStage(model: shoe, dark: false, paused: false, cover: const SizedBox(key: Key('cover')))));
      await tester.pump();
      await pageLoaded(tester, maker);
      maker.post({'type': 'ready', 'load': 1});
      await tester.pump();
      final view = maker.views.single..scripts.clear();
      nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Scaffold()));
      await tester.pumpAndSettle();
      expect(view.scripts, ['vitrina.setPaused(true)']);
      nav.currentState!.pop();
      await tester.pumpAndSettle();
      expect(view.scripts, ['vitrina.setPaused(true)', 'vitrina.setPaused(false)']);
    });

    testWidgets('a late answer about the model before is not taken for the one now coming', (tester) async {
      await warmHost(tester);
      final key = GlobalKey<ModelStageState>();
      await stage(tester, key: key);
      await pageLoaded(tester, maker);
      maker.post({'type': 'ready', 'load': 1});
      await tester.pump();
      final view = maker.views.single..scripts.clear();
      // Another colour made as its own model.
      await stage(tester, key: key, m: ListingModel.fromJson({'url': 'https://cdn/other-1024.glb', 'variant': null}));
      await tester.runAsync(() async {
        for (var i = 0; i < 50 && view.scripts.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pump();
      final args = jsonDecode(view.scripts.single.substring('vitrina.load('.length, view.scripts.single.length - 1));
      expect(args['load'], 2);
      expect(find.byKey(const Key('cover')), findsOneWidget);
      maker.post({'type': 'ready', 'load': 1});
      maker.post({'type': 'error', 'message': 'old one failed', 'load': 1});
      await tester.pump();
      expect(find.byKey(const Key('cover')), findsOneWidget); // still waiting for its own picture, not broken
      maker.post({'type': 'ready', 'load': 2});
      await tester.pump();
      expect(find.byKey(const Key('cover')), findsNothing);
    });

    testWidgets('the turn and zoom are read back as the phone gives them', (tester) async {
      final key = GlobalKey<ModelStageState>();
      await stage(tester, key: key);
      expect(await key.currentState!.view(), isNull); // nothing shown yet
      maker.post({'type': 'ready'});
      await tester.pump();
      final view = maker.views.single;
      view.answer = '"[0.1,0.2,0.3,0.9,2]"'; // Android: a JSON string, still quoted
      expect(await key.currentState!.view(), [0.1, 0.2, 0.3, 0.9, 2.0]);
      view.answer = [0, 0, 0, 1, 1]; // iOS: the list itself
      expect(await key.currentState!.view(), [0.0, 0.0, 0.0, 1.0, 1.0]);
      view.answer = 'undefined';
      expect(await key.currentState!.view(), isNull);
    });
  });

  group('the listing page', () {
    late List<String> asked;
    late Map<int, Map<String, dynamic>> listings;

    Future<void> open(WidgetTester tester, Map<String, dynamic> first) async {
      asked = [];
      listings = {3: first, 4: listing(4, color: 'қызғылт', variant: 'beach')};
      final api = Api(
          base: 'http://x/api/v1',
          client: MockClient((req) async {
            asked.add(req.url.path);
            if (req.url.path.endsWith('/similar')) return jsonResponse({'items': []});
            final id = int.tryParse(req.url.pathSegments.last);
            return jsonResponse(listings[id] ?? first);
          }));
      tester.view.physicalSize = const Size(360, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
          SessionScope(session: Session(api), child: const MaterialApp(home: Scaffold(body: Text('catalog')))));
      Navigator.of(tester.element(find.text('catalog')))
          .push(MaterialPageRoute<void>(builder: (_) => const ListingScreen(listingId: 3)));
      await tester.pumpAndSettle();
    }

    testWidgets('a shoe with a model opens in 3D, with a small 360°/Фото/Видео switch as on the demo', (tester) async {
      await open(tester, listing(3));
      expect(find.byType(ModelStage), findsOneWidget);
      final toggle = find.byKey(const Key('stage-switch'));
      final segment = find.descendant(of: toggle, matching: find.byType(TextButton)).first;
      expect(tester.getSize(toggle).height, 48); // the demo's 42, made the smallest a finger is sure to hit
      expect(tester.getSize(segment).width, greaterThan(100)); // each third wide and easy to hit
      expect(find.text('360°'), findsOneWidget);
      expect(find.text('Фото'), findsOneWidget);
      expect(find.text('Видео'), findsOneWidget); // always there, as on the demo, even before the seller adds one
      await tester.tap(find.text('Видео'));
      await tester.pump();
      expect(find.text('Сатушы әлі видео қоспаған'), findsOneWidget);
    });

    testWidgets('Фото shows the photos at once and keeps the 3D open, paused, for 360° to come back to',
        (tester) async {
      await warmHost(tester);
      await open(tester, listing(3));
      await pageLoaded(tester, maker);
      maker.post({'type': 'ready'});
      await tester.pump();
      await tester.tap(find.text('Фото'));
      await tester.pump();
      expect(find.byType(PhotoGallery), findsOneWidget);
      expect(find.byType(ModelStage, skipOffstage: false), findsOneWidget);
      expect(maker.views.single.scripts.last, 'vitrina.setPaused(true)');
      await tester.tap(find.text('360°'));
      await tester.pump();
      expect(maker.views, hasLength(1)); // not opened again
      expect(maker.views.single.scripts.last, 'vitrina.setPaused(false)');
    });

    testWidgets('the scene button turns the stage light or dark in place', (tester) async {
      await warmHost(tester);
      await open(tester, listing(3));
      await pageLoaded(tester, maker);
      maker.post({'type': 'ready'});
      await tester.pump();
      await tester.tap(find.byKey(const Key('scene')));
      await tester.pump();
      expect(maker.views.single.scripts.last, 'vitrina.setBackground(false)'); // the dark backdrop was the listing's
      await tester.tap(find.byKey(const Key('scene')));
      await tester.pump();
      expect(maker.views.single.scripts.last, 'vitrina.setBackground(true)');
    });

    testWidgets('another colour opens in place: the same 3D, only its colour changes, the size and scroll kept',
        (tester) async {
      await warmHost(tester);
      await open(tester, listing(3));
      await pageLoaded(tester, maker);
      maker.post({'type': 'ready'});
      await tester.pump();
      final size42 = find.byKey(const Key('size-32'));
      // Mid-screen, clear of the bar over the page.
      await tester.runAsync(() => Scrollable.ensureVisible(tester.element(size42), alignment: 0.5));
      await tester.pumpAndSettle();
      await tester.tap(size42);
      await tester.pump();
      expect(tester.getSemantics(find.bySemanticsLabel(RegExp('^Өлшем 42'))), isSemantics(isSelected: true));
      final page = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
      page.jumpTo(200);
      await tester.pump();
      final view = maker.views.single;
      view.scripts.clear();
      await tester.tap(find.byKey(const Key('color-4')));
      await tester.pumpAndSettle();
      expect(asked, contains('/api/v1/listings/4'));
      expect(maker.views, hasLength(1)); // the stage was not opened again
      expect(view.scripts, ['vitrina.setVariant("beach", null)']);
      expect(tester.widget<Text>(find.byKey(const Key('color-name'))).textSpan!.toPlainText(), 'Түсі: қызғылт');
      expect(page.pixels, closeTo(200, 10)); // where it was, not back at the top
      expect(tester.getSemantics(find.bySemanticsLabel(RegExp('^Өлшем 42'))), isSemantics(isSelected: true));
      // Back still leads where the buyer came from.
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();
      expect(find.text('catalog'), findsOneWidget);
    });

    testWidgets('a colour that did not load leaves the page as it was', (tester) async {
      await open(tester, listing(3));
      listings.remove(4);
      listings[4] = {'detail': 'gone'};
      await tester.tap(find.byKey(const Key('color-4')));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.byKey(const Key('color-name'))).textSpan!.toPlainText(), 'Түсі: көк');
      expect(find.byKey(const Key('color-coming-4')), findsNothing);
    });

    testWidgets('a 3D that cannot open leaves the photos, with no switch to it', (tester) async {
      await open(tester, listing(3));
      maker.post({'type': 'error', 'message': 'no WebGL'});
      await tester.pump();
      expect(find.byType(ModelStage), findsNothing);
      expect(find.byType(PhotoGallery), findsOneWidget);
      expect(find.byKey(const Key('stage-switch')), findsNothing);
    });

    testWidgets('the seller\'s video is a third tab: its poster first, played on a tap, paused by another tab',
        (tester) async {
      final video = FakeVideoPlatform();
      VideoPlayerPlatform.instance = video;
      await warmHost(tester);
      await open(tester, listing(3, withVideo: true));
      await pageLoaded(tester, maker);
      maker.post({'type': 'ready'});
      await tester.pump();
      final toggle = find.byKey(const Key('stage-switch'));
      expect(find.descendant(of: toggle, matching: find.byType(TextButton)), findsNWidgets(3));
      for (final part in find.descendant(of: toggle, matching: find.byType(TextButton)).evaluate()) {
        expect(
            tester.getSize(find.byWidget(part.widget)).width, greaterThanOrEqualTo(96)); // a third, still easy to hit
      }
      expect(find.byType(VideoPane), findsNothing); // nothing of it until asked for
      await tester.tap(find.text('Видео'));
      await tester.pump();
      expect(maker.views.single.scripts.last, 'vitrina.setPaused(true)'); // the 3D rests meanwhile
      expect(find.byKey(const Key('video-play')), findsOneWidget);
      expect(video.made, isEmpty); // the poster only: nothing comes down before a tap
      expect(find.byKey(const Key('scene')), findsNothing); // the scene button is the 3D's and the photos'
      await tester.tap(find.byKey(const Key('video-play')));
      await tester.pumpAndSettle();
      expect(video.made, ['https://cdn.example/v3.mp4']);
      expect(video.calls, contains('play'));
      expect(find.byKey(const Key('fake-video')), findsOneWidget);
      await tester.tap(find.text('Фото'));
      await tester.pump();
      expect(video.calls.last, 'pause');
      await tester.tap(find.text('Видео'));
      await tester.pump();
      expect(video.made, hasLength(1)); // kept where it was, not opened again
      expect(find.byKey(const Key('fake-video')), findsOneWidget);
    });

    testWidgets('a video that does not open says so on its poster, and a tap tries again', (tester) async {
      final video = FakeVideoPlatform()..fail = true;
      VideoPlayerPlatform.instance = video;
      await open(tester, listing(3, withModel: false, withVideo: true));
      // No 3D: the switch has the photos and the video.
      expect(find.text('360°'), findsNothing);
      await tester.tap(find.text('Видео'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('video-play')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('video-failed')), findsOneWidget);
      video.fail = false;
      await tester.tap(find.byKey(const Key('video-play')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('fake-video')), findsOneWidget);
    });

    testWidgets('another colour without a video goes back to the photos', (tester) async {
      VideoPlayerPlatform.instance = FakeVideoPlatform();
      await open(tester, listing(3, withModel: false, withVideo: true));
      listings[4] = listing(4, color: 'қызғылт', withModel: false);
      await tester.tap(find.text('Видео'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('color-4')));
      await tester.pumpAndSettle();
      expect(find.byType(VideoPane), findsNothing);
      expect(find.text('Видео'), findsNothing);
      expect(find.byType(PhotoGallery), findsOneWidget);
    });

    testWidgets('a shoe without a model shows its photos, with no switch', (tester) async {
      await open(tester, listing(3, withModel: false));
      expect(find.byType(ModelStage), findsNothing);
      expect(find.byType(PhotoGallery), findsOneWidget);
      expect(find.byKey(const Key('stage-switch')), findsNothing);
    });
  });

  group('the colour row', () {
    Future<void> row(WidgetTester tester, int count) async {
      tester.view.physicalSize = const Size(360, 400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ColorSwatches(
            colors: [for (var i = 0; i < count; i++) Colorway.fromJson(colorway(i + 1, 'қара', current: i == 0))],
            ring: Colors.black,
            edge: Colors.grey,
            gap: Colors.white,
            onPick: (_) {},
          ),
        ),
      ));
    }

    testWidgets('34 px pictures in 44 px targets, 4 px apart, ringed when shown', (tester) async {
      await row(tester, 3);
      expect(tester.getSize(find.byKey(const Key('color-1'))), const Size(44, 44));
      expect(tester.getSize(find.byKey(const Key('color-ring-1'))), const Size(41, 41));
      expect(
          tester.getTopLeft(find.byKey(const Key('color-2'))).dx -
              tester.getTopRight(find.byKey(const Key('color-1'))).dx,
          4);
      expect(find.byType(ShaderMask), findsNothing); // all in view: no fade
    });

    testWidgets('ten colours stay in one row that scrolls, its edge fading', (tester) async {
      await row(tester, 10);
      final first = tester.getTopLeft(find.byKey(const Key('color-1'))).dy;
      expect(tester.getTopLeft(find.byKey(const Key('color-10'), skipOffstage: false)).dy, first);
      expect(find.byType(ShaderMask), findsOneWidget);
      await tester.drag(find.byKey(const Key('color-3')), const Offset(-300, 0));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('color-10')).hitTestable(), findsOneWidget);
    });
  });

  group('the stage\'s own server', () {
    late Directory cache;
    setUp(() {
      cache = Directory.systemTemp.createTempSync('models');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'), (call) async => cache.path);
    });
    tearDown(() {
      ViewerHost.fetch = fetchModel;
      cache.deleteSync(recursive: true);
    });

    final glb = Uint8List.fromList([...'glTF'.codeUnits, 2, 0, 0, 0, 12, 0, 0, 0]);

    Future<(int, List<int>)> get(Uri uri) async {
      final client = HttpClient();
      try {
        final response = await (await client.getUrl(uri)).close();
        return (response.statusCode, await response.fold<List<int>>([], (a, b) => a..addAll(b)));
      } finally {
        client.close();
      }
    }

    testWidgets('serves the page and the models only under its secret path, fetching each model once', (tester) async {
      await tester.runAsync(() async {
        final previous = HttpOverrides.current;
        HttpOverrides.global = null; // the real loopback, not the test's answer-everything-with-400
        try {
          final host = (await ViewerHost.instance)!;
          final fetched = <Uri>[];
          ViewerHost.fetch = (uri) async {
            fetched.add(uri);
            return uri.path.endsWith('bad.glb') ? Uint8List.fromList(utf8.encode('<html>error</html>')) : glb;
          };
          final page = host.page;
          final (status, body) = await get(page);
          expect(status, 200);
          expect(utf8.decode(body), contains('viewer.js'));
          expect((await get(page.replace(path: '/wrong${page.path}'))).$1, 404);
          expect((await get(page.replace(path: '/index.html'))).$1, 404);
          final at = Uri.parse(host.modelAt('https://cdn/shoe-1024.glb'));
          expect((await get(at)).$2, glb);
          expect((await get(at)).$2, glb); // from the phone the second time
          expect(fetched, [Uri.parse('https://cdn/shoe-1024.glb')]);
          // An error page is not a model and is not kept.
          expect((await get(Uri.parse(host.modelAt('https://cdn/bad.glb')))).$1, 502);
          expect(cache.listSync(recursive: true).where((f) => f.path.contains('.glb')), hasLength(1));
          // Only models it was given, and only from the web: never a file on the phone.
          expect(
              (await get(at.replace(path: '${at.path.substring(0, at.path.lastIndexOf('/'))}/unknown.glb'))).$1, 404);
          expect((await get(Uri.parse(host.modelAt('file:///data/shoe.glb')))).$1, 502);
          expect(fetched, [Uri.parse('https://cdn/shoe-1024.glb'), Uri.parse('https://cdn/bad.glb')]);
        } finally {
          HttpOverrides.global = previous;
        }
      });
    });

    testWidgets('a model download that stalls is dropped, and the next open tries again', (tester) async {
      await tester.runAsync(() async {
        final previous = HttpOverrides.current;
        HttpOverrides.global = null;
        final stall = ViewerHost.stall;
        ViewerHost.stall = const Duration(milliseconds: 300);
        // A server that starts sending the model, then goes silent (a dead 3G link); the second time it sends it all.
        final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        var asked = 0;
        origin.listen((request) async {
          asked++;
          request.response.headers.contentLength = glb.length;
          if (asked == 1) {
            request.response.add(glb.sublist(0, 4));
            await request.response.flush();
            return; // never finished
          }
          request.response.add(glb);
          await request.response.close();
        });
        try {
          final host = (await ViewerHost.instance)!;
          // Plain http to a local server: allowed in debug builds only, as tests are.
          final at = Uri.parse(host.modelAt('http://127.0.0.1:${origin.port}/slow.glb'));
          final watch = Stopwatch()..start();
          expect((await get(at)).$1, 502);
          expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
          expect(host.arriving('http://127.0.0.1:${origin.port}/slow.glb'), isFalse);
          expect((await get(at)).$2, glb);
        } finally {
          ViewerHost.stall = stall;
          HttpOverrides.global = previous;
          await origin.close(force: true);
        }
      });
    });
  });
}
