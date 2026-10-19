// Every main screen on a small phone with large text, against the demo data and the app's own font: nothing may
// run off the screen or past its box (Flutter reports that as an overflow).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
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
import 'package:vitrina/screens/analytics_screen.dart';
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

/// The narrowest common phone with the largest text Android offers and with text a step below it, and a usual
/// phone with text a size up.
const setups = [
  ('kk', Size(320, 640), 2.0),
  ('ru', Size(320, 640), 2.0),
  ('ru', Size(320, 640), 1.5),
  ('kk', Size(360, 640), 1.3),
];

/// The app's own font, so text is as wide and tall as on a phone (the test font's square letters are not). Icons
/// keep their size whatever font draws them.
Future<void> loadFonts(WidgetTester tester) =>
    tester.runAsync(() => (FontLoader('Inter')..addFont(rootBundle.load('assets/fonts/Inter.ttf'))).load());

void main() {
  final listing1 = Listing.fromJson(
      (jsonDecode(File('demo/api.json').readAsStringSync()) as Map)['GET /listings/1'] as Map<String, dynamic>);
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
  };
  testWidgets('with large text the buy button goes under the total and the hint gives the shoe its room',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await loadFonts(tester);
    appLanguage.value = 'kk';
    final client = await tester.runAsync(() => DemoClient.load());
    final session = Session(Api(base: 'http://demo/api/v1', client: client!))..api.token = demoToken;
    Future<void> show(double scale) async {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      await tester.pumpWidget(SessionScope(
          session: session,
          child: MaterialApp(theme: buildTheme(Brightness.light), home: const ListingScreen(listingId: 1))));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
    }

    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await show(1);
    expect(tester.getCenter(find.byKey(const Key('buy'))).dy,
        closeTo(tester.getCenter(find.byKey(const Key('total'))).dy, 20));
    expect(find.byKey(const Key('showcase-hint')), findsOneWidget);
    await show(2);
    expect(tester.getTopLeft(find.byKey(const Key('buy'))).dy,
        greaterThan(tester.getBottomLeft(find.byKey(const Key('total'))).dy));
    expect(find.byKey(const Key('showcase-hint')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  /// Opens [screen] on the demo data in [lang] at [size] with text [scale], goes through all of it, and returns the
  /// layout errors Flutter reported.
  Future<List<String>> visit(WidgetTester tester, String lang, Size size, double scale, Widget Function() screen,
      {Widget? sheet, Future<void> Function(WidgetTester tester)? check}) async {
    SharedPreferences.setMockInitialValues({});
    await loadFonts(tester);
    appLanguage.value = lang;
    final client = await tester.runAsync(() => DemoClient.load());
    final session = Session(Api(base: 'http://demo/api/v1', client: client!))..api.token = demoToken;
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
            theme: buildTheme(Brightness.light),
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
    try {
      await check?.call(tester);
    } on TestFailure catch (e) {
      errors.add('${e.message}');
    }
    // The screen has loaded its demo data: not still waiting, and not showing a failed load.
    if (find.byType(CircularProgressIndicator).evaluate().isNotEmpty) errors.add('still loading');
    if (find.byType(ErrorRetry).evaluate().isNotEmpty) errors.add('failed to load');
    // Pages side by side (the introduction) are each laid out.
    final pages = find.byType(PageView);
    for (var i = 0; pages.evaluate().isNotEmpty && i < 6; i++) {
      await tester.drag(pages.first, const Offset(-300, 0), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 500));
    }
    // To the end of the page's own list, so parts built only near the screen are laid out too.
    final lists =
        find.byWidgetPredicate((w) => w is Scrollable && axisDirectionToAxis(w.axisDirection) == Axis.vertical);
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
      }
      if (main.position.pixels <= 0) errors.add('the page did not scroll');
    }
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
    return errors;
  }

  testWidgets('at the usual text size the shop\'s follow button keeps to the end of its row', (tester) async {
    final errors =
        await visit(tester, 'kk', const Size(400, 800), 1, () => const ShopScreen(sellerId: 1), check: (tester) async {
      final follow = find.byKey(const Key('follow')).evaluate().isEmpty ? 'unfollow' : 'follow';
      expect(tester.getTopRight(find.byKey(Key(follow))).dx, greaterThan(400 - 40));
    });
    expect(errors, isEmpty);
  });

  final sheets = <String, Widget Function()>{
    'offer': () => OfferSheet(listing: listing1, size: listing1.sizes.first),
    'delivery': () => DeliverySheet(listingId: 1, itemPriceTiyn: listing1.priceTiyn),
    'filters': () => const FilterSheet(initial: CatalogFilter()),
    'size guide': () => const SizeGuideSheet(),
    'report': () => const ReportSheet(listingId: 1),
  };

  for (final (lang, size, scale) in setups) {
    for (final e in screens.entries) {
      testWidgets('${e.key} fits at ${size.width.round()} wide, text ×$scale ($lang)', (tester) async {
        expect(await visit(tester, lang, size, scale, e.value), isEmpty);
      });
    }
    for (final e in sheets.entries) {
      testWidgets('the ${e.key} sheet fits at ${size.width.round()} wide, text ×$scale ($lang)', (tester) async {
        expect(await visit(tester, lang, size, scale, () => const SizedBox(), sheet: e.value()), isEmpty);
      });
    }
  }
}
