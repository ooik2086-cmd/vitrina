import 'package:flutter/material.dart';

import '../api.dart';
import '../labels.dart';

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
  late final Set<String> _conditions = {...widget.initial.conditions};
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
    Navigator.pop(context, CatalogFilter(sort: _sort, conditions: _conditions, minPriceTiyn: min, maxPriceTiyn: max));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Сүзгі', style: theme.textTheme.titleLarge),
            const SizedBox(height: 16),
            Text('Сұрыптау', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              for (final e in sortLabels.entries)
                ChoiceChip(
                    label: Text(e.value), selected: _sort == e.key, onSelected: (_) => setState(() => _sort = e.key)),
            ]),
            const SizedBox(height: 20),
            Text('Баға, ₸', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: TextField(
                    key: const Key('min-price'),
                    controller: _min,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'бастап')),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                    key: const Key('max-price'),
                    controller: _max,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'дейін')),
              ),
            ]),
            const SizedBox(height: 20),
            Text('Жағдайы', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final e in conditions.entries)
                FilterChip(
                  label: Text(e.value),
                  selected: _conditions.contains(e.key),
                  onSelected: (on) => setState(() => on ? _conditions.add(e.key) : _conditions.remove(e.key)),
                ),
            ]),
            const SizedBox(height: 24),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                    onPressed: () => Navigator.pop(context, const CatalogFilter()), child: const Text('Тазарту')),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(key: const Key('apply-filter'), onPressed: _apply, child: const Text('Көрсету')),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}
