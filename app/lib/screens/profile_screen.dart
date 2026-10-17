import 'package:flutter/material.dart';

import '../session.dart';
import '../widgets/common.dart';
import 'earnings_screen.dart';
import 'my_listings_screen.dart';
import 'shop_screen.dart';
import '../i18n.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    final me = session.me;
    if (!session.signedIn) {
      return Scaffold(
        body: SignInPrompt(text: tr('Профиль мен сатушы режимі үшін кіріңіз.')),
        bottomNavigationBar: const SafeArea(
            child: Padding(padding: EdgeInsets.all(16), child: Center(child: LanguageSwitch()))),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(tr('Профиль'))),
      body: me == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(children: [
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text(me.displayName ?? tr('Аты көрсетілмеген')),
                subtitle: Text(me.phone),
              ),
              if (me.isSeller)
                ListTile(
                  leading: const Icon(Icons.store_outlined),
                  title: Text(me.shopName ?? ''),
                  subtitle: Text(trf('Сатушы · {0}', [me.city ?? ''])),
                ),
              if (me.isSeller)
                ListTile(
                  leading: const Icon(Icons.inventory_2_outlined),
                  title: Text(tr('Менің тауарларым')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MyListingsScreen())),
                ),
              if (me.isSeller)
                ListTile(
                  leading: const Icon(Icons.storefront_outlined),
                  title: Text(tr('Дүкенім және пікірлер')),
                  subtitle: Text(tr('Сатып алушылар көретін бет')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () =>
                      Navigator.of(context).push(MaterialPageRoute(builder: (_) => ShopScreen(sellerId: me.id))),
                ),
              if (me.isSeller)
                ListTile(
                  leading: const Icon(Icons.account_balance_wallet_outlined),
                  title: Text(tr('Табыс')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const EarningsScreen())),
                )
              else
                ListTile(
                  leading: const Icon(Icons.add_business_outlined),
                  title: Text(tr('Сатушы болу')),
                  subtitle: Text(tr('Дүкен атауы мен қаланы көрсетіңіз')),
                  onTap: () => _becomeSeller(context),
                ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.translate),
                title: Text(tr('Тіл')),
                trailing: const LanguageSwitch(),
              ),
              ListTile(
                leading: const Icon(Icons.logout),
                title: Text(tr('Шығу')),
                onTap: session.signOut,
              ),
            ]),
    );
  }

  Future<void> _becomeSeller(BuildContext context) async {
    final session = SessionScope.of(context);
    final shop = TextEditingController();
    final city = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Сатушы режимі')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: shop, decoration: InputDecoration(labelText: tr('Дүкен атауы'))),
          TextField(controller: city, decoration: InputDecoration(labelText: tr('Қала'))),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Жабу'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('Қосу'))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      session.update(await session.api.becomeSeller(shop.text.trim(), city.text.trim()));
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }
}
