import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../appearance.dart';
import '../labels.dart';
import '../session.dart';
import '../widgets/common.dart';
import '../widgets/todo_card.dart';
import 'analytics_screen.dart';
import 'blocked_screen.dart';
import 'earnings_screen.dart';
import 'following_screen.dart';
import 'help_screen.dart';
import 'my_listings_screen.dart';
import 'notification_settings_screen.dart';
import 'offers_screen.dart';
import 'promo_codes_screen.dart';
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
        // How buying and paying work is for someone deciding whether to sign in, too.
        body: SignInPrompt(
          text: tr('Профиль мен сатушы режимі үшін кіріңіз.'),
          below: TextButton.icon(
            key: const Key('help-signed-out'),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const HelpScreen())),
            icon: const Icon(Icons.help_outline_rounded),
            label: Text(tr('Қалай жұмыс істейді')),
          ),
        ),
        // heightFactor 1: a plain Center would grow to the whole screen and lie over «Кіру», taking its taps.
        bottomNavigationBar: const SafeArea(
            child: Padding(padding: EdgeInsets.all(16), child: Center(heightFactor: 1, child: LanguageSwitch()))),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(tr('Профиль'))),
      body: me == null
          ? (session.meError != null
              ? ErrorRetry(error: session.meError, onRetry: () => unawaited(session.reloadMe(shown: true)))
              : const Center(child: CircularProgressIndicator()))
          : ListView(
              padding: contentPadding(context, EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom)),
              children: [
                  const TodoCard(),
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
                      onTap: () =>
                          Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MyListingsScreen())),
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
                      key: const Key('promo-codes'),
                      leading: const Icon(Icons.confirmation_number_outlined),
                      title: Text(tr('Промокодтар')),
                      subtitle: Text(tr('Instagram мен WhatsApp-қа жеңілдік коды')),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () =>
                          Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PromoCodesScreen())),
                    ),
                  if (me.isSeller)
                    ListTile(
                      key: const Key('shop-link'),
                      leading: const Icon(Icons.ios_share_rounded),
                      title: Text(tr('Дүкен сілтемесі')),
                      subtitle: Text(tr('Instagram биосына немесе WhatsApp статусына')),
                      onTap: () => shareShop(me.id, me.shopName),
                    ),
                  if (me.isSeller) const ShopAboutTile(),
                  if (me.isSeller) const AwayTile(),
                  ListTile(
                    key: const Key('offers'),
                    leading: const Icon(Icons.local_offer_outlined),
                    title: Text(tr('Баға ұсыныстары')),
                    subtitle: Text(
                        me.isSeller ? tr('Сатып алушылардың ұсыныстарына жауап беру') : tr('Сіздің ұсыныстарыңыз')),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => OffersScreen(seller: me.isSeller))),
                  ),
                  ListTile(
                    key: const Key('following'),
                    leading: const Icon(Icons.storefront_outlined),
                    title: Text(tr('Жазылымдар')),
                    subtitle: Text(tr('Жаңа тауарын хабарлайтын дүкендер')),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const FollowingScreen())),
                  ),
                  if (me.isSeller)
                    ListTile(
                      leading: const Icon(Icons.insights_outlined),
                      title: Text(tr('Аналитика')),
                      subtitle: Text(tr('Қаралым, тапсырыс, сатылым')),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () =>
                          Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AnalyticsScreen())),
                    ),
                  if (me.isSeller)
                    ListTile(
                      leading: const Icon(Icons.account_balance_wallet_outlined),
                      title: Text(tr('Табыс')),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () =>
                          Navigator.of(context).push(MaterialPageRoute(builder: (_) => const EarningsScreen())),
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
                    key: const Key('notification-settings'),
                    leading: const Icon(Icons.notifications_outlined),
                    title: Text(tr('Хабарлама баптаулары')),
                    subtitle: Text(tr('Қандай хабарлама келетінін таңдаңыз')),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => const NotificationSettingsScreen())),
                  ),
                  ListTile(
                    key: const Key('blocked'),
                    leading: const Icon(Icons.block),
                    title: Text(tr('Бұғатталғандар')),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const BlockedScreen())),
                  ),
                  ListTile(
                    key: const Key('help'),
                    leading: const Icon(Icons.help_outline_rounded),
                    title: Text(tr('Қалай жұмыс істейді')),
                    subtitle: Text(tr('Төлем, мерзімдер, қайтару, дау')),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const HelpScreen())),
                  ),
                  ListTile(
                    key: const Key('privacy'),
                    leading: const Icon(Icons.privacy_tip_outlined),
                    title: Text(tr('Құпиялылық саясаты')),
                    trailing: const Icon(Icons.open_in_new_rounded),
                    onTap: () =>
                        launchUrl(Uri.parse(privacyUrl(appLanguage.value)), mode: LaunchMode.externalApplication)
                            .catchError((_) => false),
                  ),
                  ListTile(
                    leading: const Icon(Icons.translate),
                    title: Text(tr('Тіл')),
                    trailing: const LanguageSwitch(),
                  ),
                  ListTile(
                    leading: const Icon(Icons.contrast_rounded),
                    title: Text(tr('Көрініс')),
                    trailing: const ThemeSwitch(),
                  ),
                  ListTile(
                    leading: const Icon(Icons.logout),
                    title: Text(tr('Шығу')),
                    // Next to the theme and the language: a tap meant for them does not sign out unasked.
                    onTap: () async {
                      if (await confirmAction(context, title: tr('Аккаунттан шығу керек пе?'), action: tr('Шығу'))) {
                        await session.signOut();
                      }
                    },
                  ),
                  ListTile(
                    key: const Key('delete-account'),
                    leading: Icon(Icons.delete_forever_outlined, color: Theme.of(context).colorScheme.error),
                    title: Text(tr('Аккаунтты жою'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    onTap: () => _deleteAccount(context),
                  ),
                ]),
    );
  }

  Future<void> _deleteAccount(BuildContext context) async {
    final session = SessionScope.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Аккаунтты жою керек пе?')),
        content: Text(tr(
            'Аты-жөніңіз, мекенжайыңыз, таңдаулылар, сақталған іздеулер мен хабарламалар өшіріледі, тауарларыңыз каталогтан алынады. Тапсырыстар мен төлемдер туралы жазба заң бойынша сақталады. Бұл әрекетті қайтару мүмкін емес.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Жабу'))),
          FilledButton(
            key: const Key('confirm-delete'),
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr('Жою')),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await once((ProfileScreen, #delete), () async {
      // On a slow line the wait is shown, and nothing else can be tapped meanwhile. It is closed by its own route,
      // whatever opened above it, and also when the answer came before it was first drawn.
      BuildContext? shown;
      var finished = false;
      void close() {
        finished = true;
        final route = shown != null && shown!.mounted ? ModalRoute.of(shown!) : null;
        if (route != null && route.isActive) Navigator.of(shown!).removeRoute(route);
      }

      unawaited(showDialog<void>(
        context: context,
        barrierDismissible: false,
        useRootNavigator: true,
        builder: (context) {
          shown = context;
          if (finished) WidgetsBinding.instance.addPostFrameCallback((_) => close());
          return PopScope(
            canPop: false,
            child: AlertDialog(
              key: const Key('deleting-account'),
              content: Row(children: [
                const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
                const SizedBox(width: 16),
                Expanded(child: Text(tr('Аккаунт жойылуда…'))),
              ]),
            ),
          );
        },
      ));
      try {
        final owner = session.me?.id;
        await session.api.deleteAccount();
        close();
        if (owner != null) await session.forgetLocal(owner);
        await session.signOut(server: false); // the deletion ended every sign-in
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Аккаунт жойылды.'))));
        }
      } catch (e) {
        close();
        if (context.mounted) showError(context, e);
      }
    });
  }

  Future<void> _becomeSeller(BuildContext context) async {
    final ok = await showDialog<bool>(context: context, builder: (_) => const _BecomeSellerDialog());
    if (ok == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('Сатушы режимі қосылды. Енді «Менің тауарларым» бөлімінен тауар қоса аласыз.'))));
    }
  }
}

/// The shop's name and city. It stays open until the server says yes: a refusal is said under the fields, with
/// what was typed still there.
class _BecomeSellerDialog extends StatefulWidget {
  const _BecomeSellerDialog();

  @override
  State<_BecomeSellerDialog> createState() => _BecomeSellerDialogState();
}

class _BecomeSellerDialogState extends State<_BecomeSellerDialog> {
  final _shop = TextEditingController();
  final _city = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _shop.dispose();
    _city.dispose();
    super.dispose();
  }

  // The server takes at least 2 letters in each.
  bool get _filled => _shop.text.trim().length >= 2 && _city.text.trim().length >= 2;

  Future<void> _send() async {
    final session = SessionScope.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      session.update(await session.api.becomeSeller(_shop.text.trim(), _city.text.trim()));
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  // While the request is out it cannot be closed: a closed dialog would turn seller mode on without a word.
  Widget build(BuildContext context) => PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(tr('Сатушы режимі')),
        scrollable: true, // large text and the keyboard up: it scrolls rather than overflows
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
              key: const Key('seller-shop'),
              controller: _shop,
              autofocus: true,
              maxLength: 80,
              buildCounter: nearLimitCounter,
              onChanged: (_) => setState(() => _error = null),
              decoration: InputDecoration(labelText: tr('Дүкен атауы'))),
          TextField(
              key: const Key('seller-city'),
              controller: _city,
              maxLength: 60,
              buildCounter: nearLimitCounter,
              onChanged: (_) => setState(() => _error = null),
              decoration: InputDecoration(labelText: tr('Қала'))),
          if (!_filled)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(tr('Дүкен атауы мен қаланы жазыңыз (кемінде 2 әріп).'),
                  style: Theme.of(context).textTheme.bodySmall),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Semantics(
                liveRegion: true,
                child: Text(_error!,
                    key: const Key('seller-error'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            ),
        ]),
        actions: [
          TextButton(
              key: const Key('seller-close'),
              onPressed: _busy ? null : () => Navigator.pop(context, false),
              child: Text(tr('Жабу'))),
          FilledButton(
              key: const Key('seller-on'),
              onPressed: _busy || !_filled ? null : _send,
              child: busyLabel(_busy, Text(tr('Қосу')))),
        ],
      ));
}

/// The seller's own lines on the shop page. Contacts are refused by the server, so the chat stays the one channel.
class ShopAboutTile extends StatelessWidget {
  const ShopAboutTile({super.key});

  Future<void> _edit(BuildContext context) async {
    final session = SessionScope.of(context);
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _ShopAboutDialog(initial: session.me?.shopAbout ?? ''),
    );
    if (saved == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Дүкен беті жаңартылды.'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final about = SessionScope.of(context).me?.shopAbout;
    return ListTile(
      key: const Key('shop-about-tile'),
      leading: const Icon(Icons.edit_note_rounded),
      title: Text(tr('Дүкен туралы')),
      subtitle:
          Text(about ?? tr('Жазылмаған: жөнелту, қайтару, жұмыс уақыты'), maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _edit(context),
    );
  }
}

/// Owns its controller, so it is disposed only after the dialog's closing animation.
class _ShopAboutDialog extends StatefulWidget {
  const _ShopAboutDialog({required this.initial});
  final String initial;

  @override
  State<_ShopAboutDialog> createState() => _ShopAboutDialogState();
}

class _ShopAboutDialogState extends State<_ShopAboutDialog> {
  late final _text = TextEditingController(text: widget.initial);
  bool _busy = false;
  Object? _error; // a refusal stays under the field with the text, so the seller can fix it and save again

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final session = SessionScope.of(context);
    final text = _text.text.trim();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      session.update(await session.api.setShopAbout(text.isEmpty ? null : text));
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        scrollable: true, // the whole refusal reads at 2× text too
        title: Text(tr('Дүкен туралы')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            key: const Key('shop-about-field'),
            controller: _text,
            autofocus: true,
            maxLines: 5,
            maxLength: 500,
            buildCounter: nearLimitCounter,
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            decoration: InputDecoration(
                hintText: tr('Мысалы: жөнелту мерзімі, қайтару шарты, жұмыс уақыты. Телефон мен сілтеме жазылмайды.'),
                errorText: _error == null ? null : refusalText(_error, _text.text),
                errorMaxLines: 30),
          ),
          RemoveContactsButton(
              error: _error,
              controller: _text,
              showRule: true, // the hint that says the rule is hidden while there is text
              onRemoved: (clean) => setState(() => _error = clean ? null : moreContacts())),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Болдырмау'))),
          FilledButton(key: const Key('shop-about-save'), onPressed: _busy ? null : _save, child: Text(tr('Сақтау'))),
        ],
      );
}

/// Holiday mode: the shop stays visible, but orders and offers wait until the seller is back.
class AwayTile extends StatefulWidget {
  const AwayTile({super.key});

  @override
  State<AwayTile> createState() => _AwayTileState();
}

class _AwayTileState extends State<AwayTile> {
  bool _busy = false;

  Future<void> _set(DateTime? until) async {
    final session = SessionScope.of(context);
    setState(() => _busy = true);
    try {
      session.update(await session.api.setAway(until));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(until == null
              ? tr('Демалыс режимі өшірілді. Тапсырыс қабылданады.')
              : trf('{0} дейін тапсырыс пен баға ұсынысы қабылданбайды.', [formatDay(until)]))));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _tap(DateTime? current) async {
    if (current != null) {
      final off = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(tr('Демалыс режимі')),
          content: Text(trf('{0} дейін қосулы.', [formatDay(current)])),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Күнін өзгерту'))),
            FilledButton(
                key: const Key('away-off'),
                onPressed: () => Navigator.pop(context, true),
                child: Text(tr('Демалысты аяқтау'))),
          ],
        ),
      );
      if (off == null || !mounted) return;
      if (off) return _set(null);
    }
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      helpText: tr('Қай күнге дейін демаласыз?'),
      initialDate: current ?? today.add(const Duration(days: 7)),
      firstDate: today,
      lastDate: today.add(const Duration(days: 60)),
    );
    if (picked != null && mounted) await _set(picked);
  }

  @override
  Widget build(BuildContext context) {
    final away = SessionScope.of(context).me?.awayUntil;
    return ListTile(
      key: const Key('away'),
      enabled: !_busy,
      leading: Icon(Icons.beach_access_outlined, color: away == null ? null : Theme.of(context).colorScheme.error),
      title: Text(tr('Демалыс режимі')),
      subtitle: Text(away == null
          ? tr('Өшірулі: тапсырыс қабылданады')
          : trf('{0} дейін қосулы: тапсырыс қабылданбайды', [formatDay(away)])),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _tap(away),
    );
  }
}
