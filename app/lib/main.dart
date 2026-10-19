import 'dart:async';
import 'dart:math' as math;

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
            builder: canvasBehind,
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

/// A fresh home opens on the catalog, as at launch.
@visibleForTesting
void forgetLastTab() => _lastTab = 0;

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int _tab = _lastTab;
  Map<String, int> _counts = const {};
  Timer? _poll;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _startPolling();
      _refreshBadges();
    }
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(minutes: 1), (_) => _refreshBadges());
  }

  /// The badges stop counting while the app is in the background and catch up when it comes back.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshBadges();
      _startPolling();
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _poll?.cancel();
      _poll = null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
    final labels = [tr('Каталог'), tr('Таңдаулы'), tr('Чат'), tr('Тапсырыс'), tr('Профиль')];
    // Every label on one line: a long one (Russian «Избранное», large text) makes all of them a little smaller;
    // when that is not enough, only the chosen tab is named, made as small as it needs to fit.
    final fit = navLabelFit(context, labels);
    final roomy = fit >= 0.8;
    final scale = roomy ? fit : navLabelFit(context, [labels[_tab]], tabs: labels.length);
    // Back on another tab returns to the catalog first, rather than closing the app.
    return PopScope(
      canPop: _tab == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _tab = _lastTab = 0);
      },
      child: Scaffold(
        // The hidden tabs stay alive but fly no photos: the catalog and favourites show the same shoe under one
        // hero tag, and two such heroes on one route break the flight to the listing page.
        body: IndexedStack(index: _tab, children: [
          for (final (i, tab) in const [
            CatalogScreen(),
            FavoritesScreen(),
            ChatsScreen(),
            OrdersScreen(),
            ProfileScreen(),
          ].indexed)
            HeroMode(enabled: i == _tab, child: tab),
        ]),
        bottomNavigationBar: NavigationBarTheme(
          data: navLabelsScaled(context, scale),
          child: NavigationBar(
            selectedIndex: _tab,
            labelBehavior: roomy
                ? NavigationDestinationLabelBehavior.alwaysShow
                : NavigationDestinationLabelBehavior.onlyShowSelected,
            onDestinationSelected: (i) {
              setState(() => _tab = _lastTab = i);
              _refreshBadges();
            },
            destinations: [
              NavigationDestination(
                  icon: Icon(Icons.storefront_outlined), selectedIcon: Icon(Icons.storefront), label: labels[0]),
              NavigationDestination(
                  icon: Icon(Icons.favorite_border), selectedIcon: Icon(Icons.favorite), label: labels[1]),
              NavigationDestination(
                  key: const Key('tab-chat'),
                  icon: _badged(const Icon(Icons.chat_bubble_outline_rounded), chats),
                  selectedIcon: _badged(const Icon(Icons.chat_bubble_rounded), chats),
                  label: labels[2]),
              NavigationDestination(
                  key: const Key('tab-orders'),
                  icon: _badged(const Icon(Icons.receipt_long_outlined), orders),
                  selectedIcon: _badged(const Icon(Icons.receipt_long), orders),
                  label: labels[3]),
              NavigationDestination(
                  icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: labels[4]),
            ],
          ),
        ),
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

/// How much the bottom bar's labels must shrink so the widest fits on one line in its tab (1 = no shrinking).
double navLabelFit(BuildContext context, List<String> labels, {int? tabs}) {
  final style = Theme.of(context).navigationBarTheme.labelTextStyle?.resolve({WidgetState.selected}) ??
      Theme.of(context).textTheme.labelMedium!;
  final room = MediaQuery.sizeOf(context).width / (tabs ?? labels.length) - 8; // a tab, less a little air
  var widest = 0.0;
  for (final label in labels) {
    final painter = TextPainter(
        text: TextSpan(text: label, style: style),
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1)
      ..layout();
    widest = math.max(widest, painter.width);
    painter.dispose();
  }
  return widest <= room ? 1 : room / widest;
}

/// The bar's theme with its label text made [scale] times its size.
NavigationBarThemeData navLabelsScaled(BuildContext context, double scale) {
  final theme = Theme.of(context).navigationBarTheme;
  if (scale >= 1) return theme;
  return theme.copyWith(labelTextStyle: WidgetStateProperty.resolveWith((states) {
    final style = theme.labelTextStyle?.resolve(states) ?? Theme.of(context).textTheme.labelMedium!;
    return style.copyWith(fontSize: (style.fontSize ?? 12) * scale);
  }));
}
