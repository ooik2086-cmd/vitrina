/// Light, dark or the phone's own setting, remembered on the phone.
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'i18n.dart';

const _prefsKey = 'vitrina_theme';

final themeMode = ValueNotifier<ThemeMode>(ThemeMode.system);

Future<void> restoreThemeMode() async {
  try {
    final saved = (await SharedPreferences.getInstance()).getString(_prefsKey);
    themeMode.value = ThemeMode.values.firstWhere((m) => m.name == saved, orElse: () => ThemeMode.system);
  } catch (_) {}
}

Future<void> setThemeMode(ThemeMode mode) async {
  themeMode.value = mode;
  try {
    await (await SharedPreferences.getInstance()).setString(_prefsKey, mode.name);
  } catch (_) {}
}

/// Three icon segments; the labels are tooltips so the row fits beside the title on a narrow phone.
class ThemeSwitch extends StatelessWidget {
  const ThemeSwitch({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<ThemeMode>(
        valueListenable: themeMode,
        builder: (context, mode, _) => SegmentedButton<ThemeMode>(
          key: const Key('theme'),
          showSelectedIcon: false,
          segments: [
            ButtonSegment(
                value: ThemeMode.system,
                icon: const Icon(Icons.brightness_auto_outlined, size: 18),
                tooltip: tr('Телефондағыдай')),
            ButtonSegment(
                value: ThemeMode.light, icon: const Icon(Icons.light_mode_outlined, size: 18), tooltip: tr('Жарық')),
            ButtonSegment(
                value: ThemeMode.dark, icon: const Icon(Icons.dark_mode_outlined, size: 18), tooltip: tr('Қараңғы')),
          ],
          selected: {mode},
          onSelectionChanged: (s) => setThemeMode(s.first),
        ),
      );
}
