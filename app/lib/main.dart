import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';
import 'appearance.dart';
import 'demo.dart';
import 'screens/catalog_screen.dart';
import 'screens/chat_screen.dart';
import 'screens/listing_screen.dart';
import 'screens/shop_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/favorites_screen.dart';
import 'screens/orders_screen.dart';
import 'screens/profile_screen.dart';
import 'session.dart';
import 'theme.dart';
import 'i18n.dart';
import 'my_size.dart';
import 'quick_replies.dart';
import 'recent.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await restoreLanguage(_deviceLanguage());
  await restoreMySize();
  await restoreRecent();
  await restoreRecentSearches();
  await restoreQuickReplies();
  await restoreOnboarded();
  await restoreThemeMode();
  final Session session;
  if (demoMode) {
    session = Session(Api(client: await DemoClient.load()))..api.token = demoToken;
    session.update(await session.api.me());
  } else {
    session = Session(Api())..restore();
  }
  runApp(VitrinaApp(session: session));
}

String _deviceLanguage() {
  try {
    return WidgetsBinding.instance.platformDispatcher.locale.languageCode;
  } catch (_) {
    return 'kk'; // some browsers report a locale the engine cannot parse
  }
}

class VitrinaApp extends StatelessWidget {
  const VitrinaApp({super.key, required this.session});
  final Session session;

  @override
  Widget build(BuildContext context) {
    return SessionScope(
      session: session,
      // A language change rebuilds every screen from scratch so no text stays in the old language.
      child: ValueListenableBuilder<String>(
        valueListenable: appLanguage,
        builder: (context, lang, _) => ValueListenableBuilder<ThemeMode>(
          valueListenable: themeMode,
          builder: (context, mode, _) => MaterialApp(
            key: ValueKey(lang),
            themeMode: mode,
            title: 'VITRINA',
            debugShowCheckedModeBanner: false,
            theme: buildTheme(Brightness.light),
            darkTheme: buildTheme(Brightness.dark),
            home: ValueListenableBuilder<bool>(
              valueListenable: onboarded,
              builder: (context, done, _) => done ? const HomeShell() : const OnboardingScreen(),
            ),
            // vitrina://open/listing/7 or vitrina://open/shop/3 from a shared page's "open in app" button.
            onGenerateRoute: (settings) {
              final m = RegExp(r'^/(listing|shop)/(\d+)$').firstMatch(settings.name ?? '');
              if (m == null) return null;
              final id = int.parse(m.group(2)!);
              return MaterialPageRoute(
                  builder: (_) => m.group(1) == 'shop' ? ShopScreen(sellerId: id) : ListingScreen(listingId: id));
            },
          ),
        ),
      ),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

/// Survives the rebuild after a language change, so the person stays on the tab they were on.
int _lastTab = 0;

class _HomeShellState extends State<HomeShell> {
  int _tab = _lastTab;
  Map<String, int> _counts = const {};
  Timer? _poll;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_poll == null) {
      _poll = Timer.periodic(const Duration(minutes: 1), (_) => _refreshBadges());
      _refreshBadges();
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  /// Unread messages and orders that wait on this person, for the numbers on the Chat and Orders tabs.
  Future<void> _refreshBadges() async {
    final session = SessionScope.of(context);
    if (!session.signedIn) {
      if (_counts.isNotEmpty) setState(() => _counts = const {});
      return;
    }
    try {
      final counts = await session.api.todo();
      if (mounted) setState(() => _counts = counts);
    } catch (_) {
      // Badges are a hint; the tabs work without them.
    }
  }

  Widget _badged(Widget icon, int count) =>
      Badge(isLabelVisible: count > 0, label: Text(count > 99 ? '99+' : '$count'), child: icon);

  @override
  Widget build(BuildContext context) {
    final chats = _counts['unread_messages'] ?? 0;
    final orders = ordersWaiting(_counts);
    return Scaffold(
      body: IndexedStack(index: _tab, children: const [
        CatalogScreen(),
        FavoritesScreen(),
        ChatsScreen(),
        OrdersScreen(),
        ProfileScreen(),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) {
          setState(() => _tab = _lastTab = i);
          _refreshBadges();
        },
        destinations: [
          NavigationDestination(
              icon: Icon(Icons.storefront_outlined), selectedIcon: Icon(Icons.storefront), label: tr('Каталог')),
          NavigationDestination(
              icon: Icon(Icons.favorite_border), selectedIcon: Icon(Icons.favorite), label: tr('Таңдаулы')),
          NavigationDestination(
              key: const Key('tab-chat'),
              icon: _badged(const Icon(Icons.chat_bubble_outline_rounded), chats),
              selectedIcon: _badged(const Icon(Icons.chat_bubble_rounded), chats),
              label: tr('Чат')),
          NavigationDestination(
              key: const Key('tab-orders'),
              icon: _badged(const Icon(Icons.receipt_long_outlined), orders),
              selectedIcon: _badged(const Icon(Icons.receipt_long), orders),
              label: tr('Тапсырыс')),
          NavigationDestination(
              icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: tr('Профиль')),
        ],
      ),
    );
  }
}

/// Orders where the next step is this person's, from the to-do counts.
int ordersWaiting(Map<String, int> counts) => [
      'to_pay',
      'to_confirm',
      'to_accept',
      'to_ship',
      'returns',
    ].fold(0, (sum, k) => sum + (counts[k] ?? 0));
