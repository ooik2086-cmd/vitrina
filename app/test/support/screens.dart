// The app's main screens and sheets on the demo data, and a walk through one of them, for tests that check every
// screen the same way (large text, accessibility).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:vitrina/widgets/common.dart';
import 'package:vitrina/widgets/delivery_sheet.dart';
import 'package:vitrina/widgets/filter_sheet.dart';
import 'package:vitrina/widgets/size_guide.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vitrina/api.dart';
import 'package:vitrina/demo.dart';
import 'package:vitrina/i18n.dart';
import 'package:vitrina/session.dart';
import 'package:vitrina/theme.dart';
import 'package:vitrina/main.dart';
import 'package:vitrina/screens/analytics_screen.dart';
import 'package:vitrina/screens/compare_screen.dart';
import 'package:vitrina/screens/seller_reviews_screen.dart';
import 'package:vitrina/widgets/questions.dart';
import 'package:vitrina/widgets/shop_sale.dart';
import 'package:vitrina/screens/catalog_screen.dart';
import 'package:vitrina/screens/chat_screen.dart';
import 'package:vitrina/screens/earnings_screen.dart';
import 'package:vitrina/screens/favorites_screen.dart';
import 'package:vitrina/screens/following_screen.dart';
import 'package:vitrina/screens/help_screen.dart';
import 'package:vitrina/screens/listing_editor_screen.dart';
import 'package:vitrina/screens/listing_screen.dart';
import 'package:vitrina/screens/login_screen.dart';
import 'package:vitrina/screens/manage_listing_screen.dart';
import 'package:vitrina/screens/my_listings_screen.dart';
import 'package:vitrina/screens/notification_settings_screen.dart';
import 'package:vitrina/screens/notifications_screen.dart';
import 'package:vitrina/screens/offers_screen.dart';
import 'package:vitrina/screens/onboarding_screen.dart';
import 'package:vitrina/screens/order_screen.dart';
import 'package:vitrina/screens/orders_screen.dart';
import 'package:vitrina/screens/profile_screen.dart';
import 'package:vitrina/screens/promo_codes_screen.dart';
import 'package:vitrina/screens/saved_searches_screen.dart';
import 'package:vitrina/screens/shop_screen.dart';

/// The app's own font, so text is as wide and tall as on a phone (the test font's square letters are not). Icons
/// keep their size whatever font draws them.
Future<void> loadFonts(WidgetTester tester) =>
    tester.runAsync(() => (FontLoader('Inter')..addFont(rootBundle.load('assets/fonts/Inter.ttf'))).load());

final _demo = jsonDecode(File('demo/api.json').readAsStringSync()) as Map;
final listing1 = Listing.fromJson(_demo['GET /listings/1'] as Map<String, dynamic>);
final listing4 = Listing.fromJson(_demo['GET /listings/4'] as Map<String, dynamic>);

/// The demo has no answered question, so the seller's answer is shown here as it would be.
Question _question(String? answer) => Question.fromJson({
      'id': answer == null ? 2 : 1,
      'text': 'Өлшемі кіші ме, үлкен бе?',
      'answer': answer,
      'asked_at': '2026-10-10T10:00:00Z',
      'mine': false,
    });

/// Every main screen, by name.
final screens = <String, Widget Function()>{
  'catalog': () => const Scaffold(body: CatalogScreen()),
  'listing1': () => const ListingScreen(listingId: 1),
  'listing4': () => const ListingScreen(listingId: 4),
  'manage': () => ManageListingScreen(listing: listing1),
  'editor': () => const ListingEditorScreen(),
  'chats': () => const ChatsScreen(),
  'chat1': () => const ChatScreen(conversationId: 1, pollEvery: Duration(hours: 1)),
  'orders': () => const OrdersScreen(),
  'sales': () => const OrdersScreen(sellerTab: true),
  for (final id in [1, 2, 1001, 1002, 1003, 1004, 1005, 1006, 1007]) 'order$id': () => OrderScreen(orderId: id),
  'profile': () => const ProfileScreen(),
  'notifications': () => const NotificationsScreen(),
  'notif-settings': () => const NotificationSettingsScreen(),
  'offers': () => const OffersScreen(),
  'offers-buyer': () => const OffersScreen(seller: false),
  'my-listings': () => const MyListingsScreen(),
  'earnings': () => const EarningsScreen(),
  'analytics': () => const AnalyticsScreen(),
  'promo': () => const PromoCodesScreen(),
  'saved': () => const SavedSearchesScreen(),
  'following': () => const FollowingScreen(),
  'favorites': () => const FavoritesScreen(),
  'help': () => const HelpScreen(),
  'shop1': () => const ShopScreen(sellerId: 1),
  'login': () => const LoginScreen(),
  'onboarding': () => const OnboardingScreen(),
  'home': () => const HomeShell(),
  'compare': () => CompareScreen(items: [listing1, listing4]),
  'seller-reviews': () => const SellerReviewsScreen(sellerId: 1, shopName: 'Qadam Store'),
  'questions': () => Scaffold(
          body: ListView(padding: const EdgeInsets.all(16), children: [
        QuestionTile(question: _question('Өлшеміне сай, әдеттегі өлшеміңізді алыңыз.')),
        QuestionTile(question: _question(null)),
      ])),
};

/// The sheets that slide up over a screen, by name.
final sheets = <String, Widget Function()>{
  'offer': () => OfferSheet(listing: listing1, size: listing1.sizes.first),
  'delivery': () => DeliverySheet(listingId: 1, itemPriceTiyn: listing1.priceTiyn),
  'filters': () => const FilterSheet(initial: CatalogFilter()),
  'size guide': () => const SizeGuideSheet(),
  'report': () => const ReportSheet(listingId: 1),
  'shop sale': () => ShopSaleSheet(listings: [listing1, listing4]),
};

/// The demo server behind a connection that can drop: while [down], every request but the account's fails as a lost
/// connection does.
class Line extends http.BaseClient {
  Line(this._inner);
  final http.Client _inner;
  bool down = false;

  /// The requests that failed, and those answered, each as method and path.
  final dropped = <String>[], served = <String>{};

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final what = '${request.method} ${request.url.path.replaceFirst(RegExp(r'^.*/api/v1'), '')}';
    if (down && !request.url.path.endsWith('/me')) {
      dropped.add(what);
      throw http.ClientException('offline', request.url);
    }
    served.add(what);
    return _inner.send(request);
  }
}

/// Opens [screen] on the demo data in [lang] at [size] with text [scale], goes through all of it, and returns the
/// layout errors Flutter reported. [look] adds its own findings once the screen has loaded and again at its end.
/// With [offline] the screen opens with the connection down, which it must say and recover from; [keepsMissing] is
/// for a screen whose parts out of sight (other tabs) are tried again only once shown.
Future<List<String>> visit(WidgetTester tester, String lang, Size size, double scale, Widget Function() screen,
    {Widget? sheet,
    Future<void> Function(WidgetTester tester)? check,
    Brightness brightness = Brightness.light,
    Future<void> Function(WidgetTester tester, List<String> errors)? look,
    bool offline = false,
    bool keepsMissing = false}) async {
  SharedPreferences.setMockInitialValues({});
  await loadFonts(tester);
  appLanguage.value = lang;
  final client = await tester.runAsync(() => DemoClient.load());
  final line = Line(client!)..down = offline;
  final session = Session(Api(base: 'http://demo/api/v1', client: line))..api.token = demoToken;
  session.update((await tester.runAsync(() => session.api.me()))!); // signed in, as the demo app is
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final errors = <String>[];
  final old = FlutterError.onError;
  addTearDown(() => FlutterError.onError = old); // also when a check below fails
  FlutterError.onError = (d) {
    final where = RegExp(r'lib/[a-z_/]+\.dart:\d+').firstMatch(d.toString())?.group(0) ?? '?';
    errors.add('${d.exceptionAsString().split('\n').first.replaceAll('A RenderFlex overflowed by ', '')} $where');
  };
  await tester.pumpWidget(SessionScope(
      session: session,
      child: MaterialApp(
          theme: buildTheme(brightness),
          home: sheet == null
              ? screen()
              : Builder(
                  builder: (context) => Scaffold(
                      body: Center(
                          child: TextButton(
                              onPressed: () => showModalBottomSheet<void>(
                                  context: context,
                                  isScrollControlled: true,
                                  showDragHandle: true,
                                  builder: (_) => sheet),
                              child: const Text('open'))))))));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
  if (sheet != null) {
    await tester.tap(find.text('open'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }
  if (offline) {
    // With the connection down a screen says so and offers to try again; it neither waits for ever nor shows nothing.
    if (find.byType(CircularProgressIndicator).evaluate().isNotEmpty) errors.add('offline: still loading');
    // Saying so is not enough: there is a «Try again» (ErrorRetry and RetryLine both have one).
    bool told() => find.byKey(const Key('retry')).evaluate().isNotEmpty;
    // With large text the message can sit below a tall header, as the goods would: it counts once scrolled to.
    final page =
        find.byWidgetPredicate((w) => w is Scrollable && axisDirectionToAxis(w.axisDirection) == Axis.vertical);
    for (var i = 0; i < 6 && !told() && page.evaluate().isNotEmpty; i++) {
      await tester.drag(page.first, const Offset(0, -300), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 300));
    }
    if (line.dropped.isNotEmpty && !told()) {
      errors.add('offline: nothing says the connection is down (${line.dropped.toSet().join(', ')})');
    }
    await look?.call(tester, errors);
    // Back online, each «Try again» a person can reach is pressed: a part lower down the page is scrolled to, a tab
    // out of sight is not.
    line.down = false;
    final tried = <Element>{};
    for (var i = 0; i < 8; i++) {
      final next = find.byKey(const Key('retry')).evaluate().where((e) => !tried.contains(e)).firstOrNull;
      if (next == null) break;
      tried.add(next);
      final retry = find.byElementPredicate((e) => e == next);
      await tester.ensureVisible(retry);
      await tester.pump();
      if (retry.hitTestable().evaluate().isEmpty) continue;
      await tester.tap(retry);
      for (var j = 0; j < 6; j++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
    }
    // Every part that failed was asked for again and came: nothing is left missing without a word.
    final missing = line.dropped.toSet().difference(line.served);
    if (missing.isNotEmpty && !keepsMissing) errors.add('offline: never fetched again: ${missing.join(', ')}');
  }
  await look?.call(tester, errors);
  try {
    await check?.call(tester);
  } on TestFailure catch (e) {
    errors.add('${e.message}');
  }
  // The screen has loaded its demo data: not still waiting, and not showing a failed load.
  if (find.byType(CircularProgressIndicator).evaluate().isNotEmpty) errors.add('still loading');
  // After a lost connection only what is on screen was tried again; a tab out of sight keeps its «Try again».
  Finder shown(Finder f) => offline ? f.hitTestable() : f;
  if (shown(find.byType(ErrorRetry)).evaluate().isNotEmpty || shown(find.byType(RetryLine)).evaluate().isNotEmpty) {
    errors.add('failed to load');
  }
  // Pages side by side (the introduction) are each laid out.
  final pages = find.byType(PageView);
  for (var i = 0; pages.evaluate().isNotEmpty && i < 6; i++) {
    await tester.drag(pages.first, const Offset(-300, 0), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 500));
  }
  // To the end of the page's own list, so parts built only near the screen are laid out too.
  final lists = find.byWidgetPredicate((w) => w is Scrollable && axisDirectionToAxis(w.axisDirection) == Axis.vertical);
  ScrollableState? main;
  for (final e in lists.evaluate()) {
    final state = (e as StatefulElement).state as ScrollableState;
    if (state.position.hasContentDimensions &&
        (main == null || state.position.maxScrollExtent > main.position.maxScrollExtent)) {
      main = state;
    }
  }
  if (main != null && main.position.maxScrollExtent > 0) {
    final up = main.widget.axisDirection == AxisDirection.up; // a chat runs from the bottom
    for (var i = 0; i < 20 && main.mounted && main.position.pixels < main.position.maxScrollExtent; i++) {
      await tester.dragFrom(tester.getCenter(find.byWidget(main.widget)), Offset(0, up ? 300 : -300));
      await tester.pump(const Duration(milliseconds: 200));
      await look?.call(tester, errors); // each screenful, not only the first and the last
    }
    if (main.position.pixels <= 0) errors.add('the page did not scroll');
  }
  await look?.call(tester, errors);
  // The buy button's words are whole: each fits its line.
  for (final e in find.byKey(const Key('buy-text')).evaluate()) {
    final text = e.renderObject! as RenderParagraph;
    for (final word in text.text.toPlainText().split(' ')) {
      final w = TextPainter(
          text: TextSpan(text: word, style: text.text.style),
          textScaler: text.textScaler,
          textDirection: TextDirection.ltr)
        ..layout();
      if (w.width > text.constraints.maxWidth + 0.5) errors.add('a word broken on the buy button: $word');
      w.dispose();
    }
  }
  FlutterError.onError = old;
  await tester.pumpWidget(const SizedBox());
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(seconds: 2));
  }
  return errors.toSet().toList(); // one finding seen at several stops is one
}
