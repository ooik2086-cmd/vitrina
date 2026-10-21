// The seller is told while the photos they just gave are still being prepared (background removed, small copies,
// the 360° start), so a listing shown as taken does not look like a failed upload.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vitrina/api.dart';
import 'package:vitrina/demo.dart';
import 'package:vitrina/screens/manage_listing_screen.dart';
import 'package:vitrina/screens/my_listings_screen.dart';
import 'package:vitrina/session.dart';

import 'support/press.dart';
import 'support/screens.dart';

/// The demo's first listing as its seller sees it.
Map<String, Object?> _own({required bool pending, String status = 'published'}) => {
      ...((jsonDecode(File('demo/api.json').readAsStringSync()) as Map)['GET /listings/1'] as Map)
          .cast<String, Object?>(),
      'stats': {'views': 3, 'favorites': 0, 'chats': 0, 'orders': 0, 'sold': 0},
      'photos_pending': pending,
      'status': status,
    };

/// What the server says now; a test may change it while the screen is open.
var _serverPending = false;
var _serverStatus = 'published';

Future<void> _open(WidgetTester tester, Widget screen, {required bool pending}) async {
  _serverPending = pending;
  addTearDown(() => _serverStatus = 'published');
  tester.view.physicalSize = const Size(360, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await loadFonts(tester);
  final demo = (await tester.runAsync(() => DemoClient.load()))!;
  final client = MockClient.streaming((req, body) async {
    final path = req.url.path.replaceFirst('/api/v1', '');
    if (req.method == 'GET' && (path == '/me/listings' || path == '/listings/1')) {
      final own = _own(pending: _serverPending, status: _serverStatus);
      final bytes = utf8.encode(jsonEncode(path == '/me/listings'
          ? {
              'items': [own]
            }
          : own));
      return http.StreamedResponse(Stream.value(bytes), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }
    return demo.send(req);
  });
  final session = Session(Api(base: 'http://demo/api/v1', client: client))..api.token = demoToken;
  session.update((await tester.runAsync(() => session.api.me()))!);
  await tester.pumpWidget(SessionScope(session: session, child: MaterialApp(home: screen)));
  await settle(tester);
}

void main() {
  testWidgets('the card goes by itself once the photos are ready, keeping what the seller is editing', (tester) async {
    await _open(tester, ManageListingScreen(listing: Listing.fromJson(_own(pending: true))), pending: true);
    expect(find.byKey(const Key('photos-pending')), findsOneWidget);
    await tester.pump(const Duration(seconds: 21));
    await settle(tester);
    expect(find.byKey(const Key('photos-pending')), findsOneWidget, reason: 'still being prepared: looks again');
    _serverPending = false;
    await tester.pump(const Duration(seconds: 21));
    await settle(tester);
    expect(find.byKey(const Key('photos-pending')), findsNothing);
    expect(find.text('Фотолар дайын'), findsOneWidget);
  });

  testWidgets('a listing hidden by a moderator shows no photos card', (tester) async {
    await _open(tester, ManageListingScreen(listing: Listing.fromJson(_own(pending: true, status: 'hidden'))),
        pending: true);
    expect(find.byKey(const Key('photos-pending')), findsNothing);
  });

  for (final pending in [true, false]) {
    testWidgets('the listing page says the photos are being prepared: $pending', (tester) async {
      await _open(tester, ManageListingScreen(listing: Listing.fromJson(_own(pending: pending))), pending: pending);
      expect(find.byKey(const Key('photos-pending')), pending ? findsOneWidget : findsNothing);
      if (pending) expect(find.text('Фотолар өңделуде'), findsOneWidget);
    });

    testWidgets('my listings say which listing has photos being prepared: $pending', (tester) async {
      await _open(tester, const MyListingsScreen(), pending: pending);
      expect(find.textContaining('фото өңделуде'), pending ? findsOneWidget : findsNothing);
    });
  }

  testWidgets('in my listings a listing sent back or hidden stands out by its word, the others stay calm',
      (tester) async {
    for (final (status, stands) in [
      ('rejected', true),
      ('hidden', true),
      ('published', false),
      ('moderation', false)
    ]) {
      _serverStatus = status;
      await tester.pumpWidget(const SizedBox());
      await _open(tester, const MyListingsScreen(), pending: false);
      final word = listingStatuses[status]!;
      final line = tester.widget<Text>(find.textContaining('$word ·')).textSpan! as TextSpan;
      final error = Theme.of(tester.element(find.byType(MyListingsScreen))).colorScheme.error;
      expect(line.children!.first.toPlainText(), word);
      expect(line.children!.first.style?.color, stands ? error : isNull, reason: status);
      expect(line.style?.color, isNull, reason: 'only the word, $status');
      expect(line.children![1].style?.color, isNull, reason: 'the rest stays calm, $status');
    }
  });
}
