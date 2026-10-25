import 'package:flutter/material.dart';

import '../i18n.dart';
import '../push.dart';
import '../session.dart';
import '../widgets/common.dart';

/// Optional alerts, each with what it is for. Order, payment, chat and offer news always arrives.
const optionalAlerts = {
  'price_drop': ('Таңдаулы тауар арзандады', 'Таңдаулыларға қосқан тауардың бағасы түскенде'),
  'saved_search': ('Сақталған іздеу бойынша жаңа тауар', 'Іздеуіңізге сай тауар сатылымға шыққанда'),
  'followed_shop': ('Жазылған дүкеннің жаңа тауары', 'Жазылған дүкен жаңа тауар қойғанда'),
  'back_in_stock': ('Өлшем қайта шықты', 'Күткен өлшеміңіз қайта сатылымда болғанда'),
};

class NotificationSettingsScreen extends StatefulWidget {
  const NotificationSettingsScreen({super.key});

  @override
  State<NotificationSettingsScreen> createState() => _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState extends State<NotificationSettingsScreen> with WidgetsBindingObserver {
  Map<String, bool>? _on;
  Object? _error;

  /// Whether alerts reach this phone while the app is closed; null in a build without push, or while asking.
  bool? _phone;
  bool _phoneBusy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkPhone();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Back from the phone's settings: the switch shows what the phone allows now.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkPhone();
  }

  void _checkPhone() {
    if (!Push.available) return;
    Push.on().then((v) {
      if (mounted && !_phoneBusy) setState(() => _phone = v);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_on == null) _load();
  }

  Future<void> _setPhone(bool on) async {
    if (_phoneBusy) return;
    setState(() => _phoneBusy = true);
    try {
      final bool now;
      if (on) {
        now = await Push.turnOn();
      } else {
        await Push.turnOff();
        now = false;
      }
      if (!mounted) return;
      setState(() => _phone = now);
      if (on && !now) {
        Push.refused(context);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _phoneBusy = false);
    }
  }

  void _load() {
    SessionScope.of(context).api.notificationSettings().then((v) {
      if (mounted) setState(() => _on = v);
    }, onError: (Object e) {
      if (mounted) setState(() => _error = e);
    });
  }

  void _retry() {
    setState(() => _error = null);
    _load();
  }

  /// What the person last asked for each switch whose save is still on its way.
  final _wanted = <String, bool>{};

  /// The switch moves at once; it moves back if saving fails. A switch flipped again while its save is on the way is
  /// saved once that one is answered, so a slow connection can neither answer them out of order nor lose the last.
  Future<void> _set(String kind, bool on) async {
    final saving = _wanted.containsKey(kind);
    _wanted[kind] = on;
    setState(() => _on = {..._on!, kind: on});
    if (saving) return;
    var confirmed = !on;
    try {
      while (true) {
        final wish = _wanted[kind]!;
        final saved = await SessionScope.of(context).api.setNotificationSetting(kind, wish);
        confirmed = saved[kind] ?? wish;
        if (!mounted) return;
        if (_wanted[kind] == wish) {
          _wanted.remove(kind);
          // Only this switch is taken from the answer: another switch's answer may already be newer than this one.
          setState(() => _on = {..._on!, kind: confirmed});
          return;
        }
      }
    } catch (e) {
      _wanted.remove(kind);
      if (!mounted) return;
      setState(() => _on = {..._on!, kind: confirmed});
      showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final on = _on;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Хабарлама баптаулары'))),
      body: on == null
          ? (_error != null
              ? ErrorRetry(error: _error, onRetry: _retry)
              : const Center(child: CircularProgressIndicator()))
          : ListView(
              padding: contentPadding(context, EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom)),
              children: [
                  if (_phone != null)
                    SwitchListTile(
                      key: const Key('alert-phone'),
                      secondary: const Icon(Icons.phone_android_rounded),
                      title: Text(tr('Телефонға хабарландыру')),
                      subtitle: Text(tr('Қосымша жабық тұрса да, жаңа хат пен тапсырыс туралы телефон айтады')),
                      value: _phone!,
                      onChanged: _phoneBusy ? null : _setPhone,
                    ),
                  if (_phone != null) const Divider(),
                  for (final e in optionalAlerts.entries)
                    if (on.containsKey(e.key))
                      SwitchListTile(
                        key: Key('alert-${e.key}'),
                        title: Text(tr(e.value.$1)),
                        subtitle: Text(tr(e.value.$2)),
                        value: on[e.key]!,
                        onChanged: (v) => _set(e.key, v),
                      ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Icon(Icons.info_outline, size: 18, color: theme.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                            tr('Тапсырыс, төлем, чат және баға ұсынысы туралы хабарламалар әрқашан келеді: олар сіздің ақшаңыз бен тауарыңызға қатысты.'),
                            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                      ),
                    ]),
                  ),
                ]),
    );
  }
}
