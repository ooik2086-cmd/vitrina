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

  Future<void> _set(String kind, bool on) async {
    final before = _on!;
    setState(() => _on = {...before, kind: on}); // the switch moves at once; it moves back if saving fails
    try {
      final saved = await SessionScope.of(context).api.setNotificationSetting(kind, on);
      if (mounted) setState(() => _on = saved);
    } catch (e) {
      if (!mounted) return;
      setState(() => _on = before);
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
          : ListView(children: [
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
