// Every main screen on a small phone with large text, against the demo data and the app's own font: nothing may
// run off the screen or past its box (Flutter reports that as an overflow).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

/// The narrowest common phone with the largest text Android offers, and a usual phone with text a size up.
const setups = [('kk', Size(320, 640), 2.0), ('ru', Size(320, 640), 2.0), ('kk', Size(360, 640), 1.3)];

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

  for (final (lang, size, scale) in setups) {
    for (final e in screens.entries) {
      testWidgets('${e.key} fits at ${size.width.round()} wide, text ×$scale ($lang)', (tester) async {
        SharedPreferences.setMockInitialValues({});
        await loadFonts(tester);
        appLanguage.value = lang;
        final client = await tester.runAsync(() => DemoClient.load());
        final session = Session(Api(base: 'http://demo/api/v1', client: client!))..api.token = demoToken;
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final errors = <String>[];
        final old = FlutterError.onError;
        FlutterError.onError = (d) {
          final where = RegExp(r'lib/[a-z_/]+\.dart:\d+').firstMatch(d.toString())?.group(0) ?? '?';
          errors.add('${d.exceptionAsString().split('\n').first.replaceAll('A RenderFlex overflowed by ', '')} $where');
        };
        await tester.pumpWidget(
            SessionScope(session: session, child: MaterialApp(theme: buildTheme(Brightness.light), home: e.value())));
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 300));
        }
        // Down through the page, so parts built only near the screen are laid out too.
        final lists = find.byType(Scrollable);
        if (lists.evaluate().isNotEmpty) {
          for (var i = 0; i < 8; i++) {
            await tester.drag(lists.first, const Offset(0, -400), warnIfMissed: false);
            await tester.pump(const Duration(milliseconds: 200));
          }
        }
        FlutterError.onError = old;
        await tester.pumpWidget(const SizedBox());
        for (var i = 0; i < 3; i++) {
          await tester.pump(const Duration(seconds: 2));
        }
        expect(errors, isEmpty);
      });
    }
  }
}
