import 'package:flutter/material.dart';

import 'api.dart';
import 'screens/catalog_screen.dart';
import 'screens/chat_screen.dart';
import 'screens/listing_screen.dart';
import 'screens/favorites_screen.dart';
import 'screens/orders_screen.dart';
import 'screens/profile_screen.dart';
import 'session.dart';
import 'theme.dart';
import 'i18n.dart';
import 'my_size.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await restoreLanguage(_deviceLanguage());
  await restoreMySize();
  final session = Session(Api())..restore();
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
        builder: (context, lang, _) => MaterialApp(
          key: ValueKey(lang),
          title: 'VITRINA',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          home: const HomeShell(),
          // vitrina://open/listing/7 from a shared link's "open in app" button.
          onGenerateRoute: (settings) {
            final m = RegExp(r'^/listing/(\d+)$').firstMatch(settings.name ?? '');
            if (m == null) return null;
            return MaterialPageRoute(builder: (_) => ListingScreen(listingId: int.parse(m.group(1)!)));
          },
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

  @override
  Widget build(BuildContext context) {
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
        onDestinationSelected: (i) => setState(() => _tab = _lastTab = i),
        destinations: [
          NavigationDestination(
              icon: Icon(Icons.storefront_outlined), selectedIcon: Icon(Icons.storefront), label: tr('Каталог')),
          NavigationDestination(
              icon: Icon(Icons.favorite_border), selectedIcon: Icon(Icons.favorite), label: tr('Таңдаулы')),
          NavigationDestination(
              icon: Icon(Icons.chat_bubble_outline_rounded),
              selectedIcon: Icon(Icons.chat_bubble_rounded),
              label: tr('Чат')),
          NavigationDestination(
              icon: Icon(Icons.receipt_long_outlined), selectedIcon: Icon(Icons.receipt_long), label: tr('Тапсырыс')),
          NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: tr('Профиль')),
        ],
      ),
    );
  }
}
