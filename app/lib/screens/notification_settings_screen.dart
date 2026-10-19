import 'package:flutter/material.dart';

import '../i18n.dart';
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

class _NotificationSettingsScreenState extends State<NotificationSettingsScreen> {
  Map<String, bool>? _on;
  Object? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_on == null) _load();
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
