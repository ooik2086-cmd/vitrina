import 'package:flutter/material.dart';

import '../api.dart';
import '../colors.dart';
import '../labels.dart';
import '../i18n.dart';
import 'delivery_eta.dart';

const sortLabels = {'new': 'Жаңалары', 'price_asc': 'Арзанырақ', 'price_desc': 'Қымбатырақ'};

/// Bottom sheet that returns a new [CatalogFilter], or null when dismissed.
class FilterSheet extends StatefulWidget {
  const FilterSheet({super.key, required this.initial});
  final CatalogFilter initial;

  @override
  State<FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<FilterSheet> {
  late String _sort = widget.initial.sort;
  late String? _city = widget.initial.city;
  late final Set<String> _conditions = {...widget.initial.conditions};
  late final Set<String> _colors = {...widget.initial.colors};

  /// Colours not on the list, from a saved search: shown too, so they can be seen and dropped.
  late final List<String> _typedColors = [
    for (final c in widget.initial.colors)
      if (!shoeColors.containsKey(c)) c
  ];
  late final _min = TextEditingController(text: _tenge(widget.initial.minPriceTiyn));
  late final _max = TextEditingController(text: _tenge(widget.initial.maxPriceTiyn));

  static String _tenge(int? tiyn) => tiyn == null ? '' : '${tiyn ~/ 100}';

  static int? _tiyn(String text) {
    final v = int.tryParse(text.replaceAll(RegExp(r'\s'), ''));
    return v == null || v <= 0 ? null : v * 100;
  }

  @override
  void dispose() {
    _min.dispose();
    _max.dispose();
    super.dispose();
  }

  void _apply() {
    var min = _tiyn(_min.text), max = _tiyn(_max.text);
    if (min != null && max != null && min > max) (min, max) = (max, min);
    Navigator.pop(
        context,
        CatalogFilter(
            sort: _sort, conditions: _conditions, minPriceTiyn: min, maxPriceTiyn: max, city: _city, colors: _colors));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Flexible(
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('Сүзгі'), style: theme.textTheme.titleLarge),
                const SizedBox(height: 16),
                Text(tr('Сұрыптау'), style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                Wrap(spacing: 8, children: [
                  for (final e in sortLabels.entries)
                    ChoiceChip(
                        label: Text(tr(e.value)),
                        selected: _sort == e.key,
                        onSelected: (_) => setState(() => _sort = e.key)),
                ]),
                const SizedBox(height: 20),
                Text(tr('Баға, ₸'), style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    child: TextField(
                        key: const Key('min-price'),
                        controller: _min,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(labelText: tr('бастап'))),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                        key: const Key('max-price'),
                        controller: _max,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(labelText: tr('дейін'))),
                  ),
                ]),
                const SizedBox(height: 20),
                Text(tr('Жағдайы'), style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final e in conditions.entries)
                    FilterChip(
                      label: Text(tr(e.value)),
                      selected: _conditions.contains(e.key),
                      onSelected: (on) => setState(() => on ? _conditions.add(e.key) : _conditions.remove(e.key)),
                    ),
                ]),
                const SizedBox(height: 20),
                Text(tr('Түсі'), style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final name in [...shoeColors.keys, ..._typedColors])
                    FilterChip(
                      key: Key('filter-color-$name'),
                      showCheckmark: false, // the dot stays: the chip's own colour says it is picked
                      avatar: ColorDot(name, onPicked: _colors.contains(name)),
                      label: Text(colorName(name)),
                      selected: _colors.contains(name),
                      onSelected: (on) => setState(() => on ? _colors.add(name) : _colors.remove(name)),
                    ),
                ]),
                const SizedBox(height: 20),
                Text(tr('Сатушының қаласы'), style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                DropdownButtonFormField<String?>(
                  key: const Key('filter-city'),
                  initialValue: _city,
                  isExpanded: true,
                  items: [
                    DropdownMenuItem(value: null, child: Text(tr('Кез келген қала'))),
                    for (final c in kzCities) DropdownMenuItem(value: c, child: Text(tr(c))),
                  ],
                  onChanged: (c) => setState(() => _city = c),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(tr('Өз қалаңыздан алсаңыз, тезірек әрі арзанырақ жетеді.'),
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                ),
              ]),
            ),
          ),
          // The buttons stay in sight however far the sections above are scrolled.
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                  onPressed: () => Navigator.pop(context, const CatalogFilter()), child: Text(tr('Тазарту'))),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(key: const Key('apply-filter'), onPressed: _apply, child: Text(tr('Көрсету'))),
            ),
          ]),
        ]),
      ),
    );
  }
}
