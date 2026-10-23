import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:vitrina/api.dart';
import 'package:vitrina/session.dart';
import 'package:vitrina/widgets/listing_video.dart';

/// Gives the video asked for, and remembers how long a recording it allowed.
class _FakePicker extends ImagePickerPlatform {
  final asked = <(ImageSource, Duration?)>[];
  Uint8List bytes = utf8.encode('a minute of video');

  @override
  Future<XFile?> getVideo(
      {required ImageSource source,
      CameraDevice preferredCameraDevice = CameraDevice.rear,
      Duration? maxDuration}) async {
    asked.add((source, maxDuration));
    return XFile.fromData(bytes, name: 'clip.mp4', path: '/picked/clip.mp4');
  }
}

http.Response jsonResponse(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

Map<String, dynamic> listing({Map<String, dynamic>? video}) => {
      'id': 7,
      'status': 'published',
      'title': 'Nike Air Force 1',
      'category': 'sneakers',
      'color': 'қара',
      'price_tiyn': 4500000,
      'delivery_price_tiyn': 150000,
      'condition': 'used_good',
      'authenticity': 'unverified',
      'showcase_style': 'clean',
      'sizes': [
        {'id': 1, 'label': '42', 'insole_cm': '27,0', 'available': true},
      ],
      'media': [
        {'original_url': 'https://cdn/front.jpg', 'processed_url': null, 'angle': 'front'},
      ],
      'seller': {'id': 3, 'shop_name': 'Qadam Store', 'city': 'Алматы'},
      'ever_on_sale': true,
      'video': video,
    };

const processing = {'state': 'processing', 'url': null, 'poster_url': null, 'seconds': 42};
const ready = {'state': 'ready', 'url': 'https://cdn/v.mp4', 'poster_url': 'https://cdn/v.jpg', 'seconds': 42};

/// Holds the listing as the manage page does: what the section reports becomes the listing it shows.
class _Page extends StatefulWidget {
  const _Page(this.first);
  final Listing first;
  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  late Listing l = widget.first;
  @override
  Widget build(BuildContext context) => Scaffold(
      body: Padding(
          padding: const EdgeInsets.all(16),
          child: ListingVideoSection(listing: l, onChanged: (next) => setState(() => l = next))));
}

void main() {
  late _FakePicker picker;
  late List<http.BaseRequest> sent;
  late List<int> body;

  Future<void> open(WidgetTester tester, Map<String, dynamic> first,
      {http.Response Function(http.BaseRequest req)? answer}) async {
    picker = _FakePicker();
    ImagePickerPlatform.instance = picker;
    sent = [];
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          sent.add(req);
          if (req.method == 'POST') body = req.bodyBytes;
          return answer?.call(req) ?? jsonResponse(listing(video: ready));
        }));
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
        SessionScope(session: Session(api)..api.token = 't', child: MaterialApp(home: _Page(Listing.fromJson(first)))));
  }

  testWidgets('a video is filmed for a minute at most, sent, made, then shown ready', (tester) async {
    await open(tester, listing(), answer: (req) {
      if (req.method == 'POST') return jsonResponse(listing(video: processing), 202);
      return jsonResponse(listing(video: ready)); // asked again later: made by now
    });
    expect(find.byKey(const Key('video-note')), findsOneWidget);
    await tester.tap(find.byKey(const Key('add-video')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('video-camera')));
    // Not settled: the page would ask again meanwhile and show the video ready before the sent state is seen.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(picker.asked, [(ImageSource.camera, const Duration(seconds: 60))]);
    final post = sent.single;
    expect((post.method, post.url.path), ('POST', '/api/v1/listings/7/video'));
    expect(utf8.decode(body, allowMalformed: true), allOf(contains('a minute of video'), contains('clip.mp4')));
    expect(find.byKey(const Key('video-processing')), findsOneWidget);
    expect(find.text('Видео жіберілді. Дайын болғанда көрінеді.'), findsOneWidget);
    // The page asks again now and then while the server makes it.
    await tester.pump(const Duration(seconds: 8));
    await tester.pumpAndSettle();
    expect(sent.last.url.path, '/api/v1/listings/7');
    expect(find.byKey(const Key('video-ready')), findsOneWidget);
    expect(find.text('Видео дайын: 0:42'), findsOneWidget);
    final asked = sent.length;
    await tester.pump(const Duration(seconds: 30));
    expect(sent, hasLength(asked)); // ready: no more asking
  });

  testWidgets('a refusal says why in the seller\'s words, and the page stays as it was', (tester) async {
    await open(tester, listing(),
        answer: (_) => jsonResponse({
              'code': 'video_too_long',
              'message_kk': 'Видео 1 минуттан аспауы керек. Қысқасын түсіріп, қайта жіберіңіз.',
              'message_ru': 'ru',
              'message_en': 'en',
            }, 422));
    await tester.tap(find.byKey(const Key('add-video')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('video-gallery')));
    await tester.pumpAndSettle();
    expect(picker.asked.single.$1, ImageSource.gallery);
    expect(find.text('Видео 1 минуттан аспауы керек. Қысқасын түсіріп, қайта жіберіңіз.'), findsOneWidget);
    expect(find.byKey(const Key('add-video')), findsOneWidget);
    expect(find.byKey(const Key('video-sending')), findsNothing);
  });

  testWidgets('a ready video is taken off only after asking', (tester) async {
    await open(tester, listing(video: ready), answer: (_) => jsonResponse(listing()));
    await tester.tap(find.byKey(const Key('remove-video')));
    await tester.pumpAndSettle();
    expect(find.text('Видеоны өшіру керек пе?'), findsOneWidget);
    expect(sent, isEmpty);
    await tester.tap(find.text('Өшіру').last);
    await tester.pumpAndSettle();
    expect((sent.single.method, sent.single.url.path), ('DELETE', '/api/v1/listings/7/video'));
    expect(find.byKey(const Key('add-video')), findsOneWidget);
  });

  testWidgets('a video that could not be made says so, with the button to send it again', (tester) async {
    await open(tester, listing(video: {...processing, 'state': 'failed'}));
    expect(find.text('Видео дайындалмады. Қайта жіберіп көріңіз.'), findsOneWidget);
    expect(find.byKey(const Key('add-video')), findsOneWidget);
  });

  testWidgets('leaving the page stops asking about a video still being made', (tester) async {
    await open(tester, listing(video: processing), answer: (_) => jsonResponse(listing(video: processing)));
    await tester.pump(const Duration(seconds: 8));
    expect(sent, hasLength(1));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 30));
    expect(sent, hasLength(1));
  });
}
