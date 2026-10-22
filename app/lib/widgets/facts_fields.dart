import 'package:flutter/material.dart';

import '../i18n.dart';
import '../labels.dart';

/// What the pair is made of, its season and the country it was made in, and for some kinds of footwear one or two
/// more (a boot's height, how warm it is, a heel's height, how a sandal fastens): each picked from a short list, nothing
/// to type. All may be left: a fact not picked is not shown to buyers.
class FactsFields extends StatelessWidget {
  const FactsFields(
      {super.key,
      required this.category,
      required this.facts,
      required this.onChanged,
      this.fixed = const {},
      this.enabled = true});

  /// The kind of footwear, which decides the kind's own facts; null before it is chosen (the five every pair has).
  final String? category;
  final Map<String, String> facts;
  final ValueChanged<Map<String, String>> onChanged;

  /// Facts that can no longer be changed: on a pair that has been on sale, those picked before (it was bought and
  /// reviewed as that). Shown, not offered.
  final Set<String> fixed;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 4),
        child: Text(tr('Аяқкиім туралы (міндетті емес)'), style: theme.textTheme.titleSmall),
      ),
      if (fixed.isNotEmpty)
        Text(tr('Таңдалғаны өзгермейді, бос қалғанын толтыруға болады.'), style: theme.textTheme.bodySmall),
      for (final key in factKeys(category))
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: DropdownButtonFormField<String?>(
            // Keyed by the value too: the page can change it from outside (work put back, changes thrown away).
            key: ValueKey('fact-$key-${facts[key]}'),
            initialValue: factOptions[key]!.containsKey(facts[key]) ? facts[key] : null,
            isExpanded: true,
            decoration: InputDecoration(labelText: tr(factNames[key]!)),
            items: [
              // Takes a pick back. Its own value, so a fact not picked shows as an empty field, its name inside it
              // like the fields above, not as one more answer.
              if (facts[key] != null) DropdownMenuItem<String?>(value: '', child: Text(tr('Бос қалдыру'))),
              for (final e in factOptions[key]!.entries)
                DropdownMenuItem<String?>(value: e.key, child: Text(tr(e.value))),
            ],
            onChanged: enabled && !fixed.contains(key)
                ? (v) => onChanged({
                      for (final e in facts.entries)
                        if (e.key != key) e.key: e.value,
                      if (v != null && v.isNotEmpty) key: v,
                    })
                : null,
          ),
        ),
    ]);
  }
}
