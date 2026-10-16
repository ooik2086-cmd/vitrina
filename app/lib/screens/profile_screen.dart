import 'package:flutter/material.dart';

import '../session.dart';
import '../widgets/common.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    final me = session.me;
    if (!session.signedIn) return const SignInPrompt(text: 'Профиль мен сатушы режимі үшін кіріңіз.');
    return Scaffold(
      appBar: AppBar(title: const Text('Профиль')),
      body: me == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(children: [
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text(me.displayName ?? 'Аты көрсетілмеген'),
                subtitle: Text(me.phone),
              ),
              if (me.isSeller)
                ListTile(
                  leading: const Icon(Icons.store_outlined),
                  title: Text(me.shopName ?? ''),
                  subtitle: Text('Сатушы · ${me.city ?? ''}'),
                )
              else
                ListTile(
                  leading: const Icon(Icons.add_business_outlined),
                  title: const Text('Сатушы болу'),
                  subtitle: const Text('Дүкен атауы мен қаланы көрсетіңіз'),
                  onTap: () => _becomeSeller(context),
                ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.logout),
                title: const Text('Шығу'),
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
        title: const Text('Сатушы режимі'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: shop, decoration: const InputDecoration(labelText: 'Дүкен атауы')),
          TextField(controller: city, decoration: const InputDecoration(labelText: 'Қала')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Жабу')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Қосу')),
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
