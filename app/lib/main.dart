import 'package:flutter/material.dart';

import 'api.dart';
import 'screens/catalog_screen.dart';
import 'screens/favorites_screen.dart';
import 'screens/orders_screen.dart';
import 'screens/profile_screen.dart';
import 'session.dart';

void main() {
  final session = Session(Api())..restore();
  runApp(VitrinaApp(session: session));
}

class VitrinaApp extends StatelessWidget {
  const VitrinaApp({super.key, required this.session});
  final Session session;

  @override
  Widget build(BuildContext context) {
    return SessionScope(
      session: session,
      child: MaterialApp(
        title: 'VITRINA',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: const Color(0xFF1F5EFF), useMaterial3: true),
        darkTheme: ThemeData(colorSchemeSeed: const Color(0xFF1F5EFF), brightness: Brightness.dark, useMaterial3: true),
        home: const HomeShell(),
      ),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _tab, children: const [
        CatalogScreen(),
        FavoritesScreen(),
        OrdersScreen(),
        ProfileScreen(),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.storefront_outlined), label: 'Каталог'),
          NavigationDestination(icon: Icon(Icons.favorite_border), label: 'Таңдаулы'),
          NavigationDestination(icon: Icon(Icons.receipt_long_outlined), label: 'Тапсырыс'),
          NavigationDestination(icon: Icon(Icons.person_outline), label: 'Профиль'),
        ],
      ),
    );
  }
}
