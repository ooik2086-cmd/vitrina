import 'package:flutter/material.dart';

import '../api.dart';
import '../i18n.dart';
import '../labels.dart';
import '../theme.dart';
import 'common.dart';

/// The listing page's compact parts, as on the approved demo: sizes as one row of small circles, and the reviews,
/// the description and the questions each as one calm line that opens a sheet.

/// The sizes as one row of round buttons that scrolls sideways: 36 px circles, each in a 48 px target (the app's
/// least for a finger; the approved demo's 44 px targets 2 px apart put the circles 10 px apart, these 12). A
/// sold-out size is struck through; tapping it asks to hear when it is back ([onSoldOut]), where that is offered.
class SizeCircles extends StatelessWidget {
  const SizeCircles(
      {super.key,
      required this.sizes,
      required this.selected,
      required this.onPick,
      this.alerted = const {},
      this.onSoldOut});
  final List<ShoeSize> sizes;
  final int? selected;
  final ValueChanged<ShoeSize> onPick;
  final Set<int> alerted;
  final ValueChanged<ShoeSize>? onSoldOut;

  static const circle = 36.0, target = 48.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final number = weight(theme.textTheme.bodyMedium!, 700).copyWith(fontSize: 14);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      clipBehavior: Clip.none,
      child: Row(children: [
        for (final s in sizes)
          if ((s.id == selected, alerted.contains(s.id)) case (final on, final waiting))
            Semantics(
              container: true,
              button: true,
              selected: on,
              enabled: s.available || onSoldOut != null,
              label: trf('Өлшем {0}, {1} см{2}', [
                s.label,
                s.insoleCm,
                s.available ? '' : (waiting ? tr(', қалмады, хабарлаймыз') : tr(', қалмады')),
              ]),
              excludeSemantics: true,
              child: InkResponse(
                key: Key('size-${s.id}'),
                radius: target / 2,
                onTap: s.available ? () => onPick(s) : (onSoldOut == null ? null : () => onSoldOut!(s)),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: target, minHeight: target),
                  child: Padding(
                    // Grown with large text, neighbouring pills still keep a gap.
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Center(
                      widthFactor: 1,
                      heightFactor: 1,
                      child: Stack(clipBehavior: Clip.none, children: [
                        Container(
                          // A circle; with large text it grows into a pill around its number, never cutting it.
                          constraints: const BoxConstraints(minWidth: circle, minHeight: circle),
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          alignment: Alignment.center,
                          decoration: ShapeDecoration(
                            shape:
                                StadiumBorder(side: BorderSide(color: on ? scheme.onSurface : scheme.outlineVariant)),
                            color: on ? scheme.onSurface : (s.available ? scheme.surface : null),
                          ),
                          child: Text(s.label,
                              maxLines: 1,
                              style: number.copyWith(
                                  color:
                                      on ? scheme.surface : (s.available ? scheme.onSurface : scheme.onSurfaceVariant),
                                  decoration: s.available ? null : TextDecoration.lineThrough)),
                        ),
                        if (waiting)
                          Positioned(
                            right: -2,
                            top: -2,
                            child: Icon(Icons.notifications_active,
                                key: Key('alert-${s.id}'), size: 14, color: Brand.accent),
                          ),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
      ]),
    );
  }
}

/// How buyers said the pair fits, in a few words: on the size line and as its sheet's title.
String fitWords(String verdict) => switch (verdict) {
      'small' => tr('Кішілеу келеді'),
      'large' => tr('Үлкендеу келеді'),
      _ => tr('Өлшеміне сай'),
    };

/// The size chart of this very pair: each size with the insole length the seller measured, sold-out ones said so; a
/// tap picks the size. Under it, the way to find one's own size ([onGuide]).
class ListingSizeChart extends StatelessWidget {
  const ListingSizeChart(
      {super.key, required this.sizes, required this.selected, required this.onPick, required this.onGuide});
  final List<ShoeSize> sizes;
  final int? selected;
  final ValueChanged<ShoeSize> onPick;
  final VoidCallback onGuide;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant);
    final strong = weight(theme.textTheme.bodyLarge!, 650);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Expanded(child: Text(tr('Өлшем'), style: muted)),
          Expanded(flex: 2, child: Text(tr('Ұлтарақ ұзындығы'), style: muted)),
        ]),
      ),
      for (final s in sizes)
        Semantics(
          button: s.available,
          selected: s.id == selected,
          child: InkWell(
            key: Key('chart-${s.id}'),
            onTap: s.available ? () => onPick(s) : null,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Row(children: [
                Expanded(
                    child: Text(s.label,
                        style: strong.copyWith(
                            color: s.available ? null : scheme.onSurfaceVariant,
                            decoration: s.available ? null : TextDecoration.lineThrough))),
                Expanded(
                  flex: 2,
                  child: Text(
                      s.available ? trf('{0} см', [s.insoleCm]) : '${trf('{0} см', [s.insoleCm])} · ${tr('қалмады')}',
                      style: s.available ? strong : muted),
                ),
                if (s.id == selected) Icon(Icons.check_rounded, color: scheme.onSurface),
              ]),
            ),
          ),
        ),
      const SizedBox(height: 8),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: LineButton(key: const Key('size-guide-how'), title: tr('Аяғыңыздың өлшемін табу'), onTap: onGuide),
      ),
    ]);
  }
}

/// One calm line that opens more: "★ 4,8 · 23 пікір ›", "Сипаттама · Кроссовка, Runner 01 ›", "Сұрақтар · 2 ›".
class LineButton extends StatelessWidget {
  const LineButton({super.key, required this.title, this.detail, this.leading, required this.onTap});
  final String title;
  final String? detail;
  final Widget? leading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final style = weight(theme.textTheme.bodyLarge!, 700);
    return Semantics(
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (leading != null) ...[leading!, const SizedBox(width: 6)],
            Flexible(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: title),
                  if (detail != null) TextSpan(text: ' · $detail', style: weight(style, 500).copyWith(color: muted)),
                ]),
                style: style,
              ),
            ),
            const SizedBox(width: 6),
            ExcludeSemantics(child: Icon(Icons.chevron_right_rounded, size: 20, color: muted)),
          ]),
        ),
      ),
    );
  }
}

/// A sheet from the bottom with its title and a round close button, up to most of the screen, scrolling when long.
Future<T?> showPageSheet<T>(BuildContext context, {required String title, required WidgetBuilder builder}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (context) {
      final theme = Theme.of(context);
      return ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.86),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: contentPadding(context, const EdgeInsets.fromLTRB(20, 0, 12, 4)),
            child: Row(children: [
              Expanded(child: Semantics(header: true, child: Text(title, style: theme.textTheme.titleLarge))),
              IconButton.outlined(
                key: const Key('sheet-close'),
                tooltip: tr('Жабу'),
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded, size: 20),
              ),
            ]),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: contentPadding(context, const EdgeInsets.fromLTRB(20, 4, 20, 24)),
              child: builder(context),
            ),
          ),
        ]),
      );
    },
  );
}

/// What the description line names: the kind of shoe and its name, "Кроссовкалар, Runner 01".
String descriptionLine(Listing l) {
  final name = [l.brand, l.modelName].whereType<String>().where((s) => s.trim().isNotEmpty).join(' ');
  final parts = [label(categories, l.category), if (name.isNotEmpty) name];
  return parts.join(', ');
}

/// The description sheet: the facts in two columns (empty ones left out), then the seller's own words in full.
class ListingFacts extends StatelessWidget {
  const ListingFacts({super.key, required this.listing});
  final Listing listing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = listing;
    final name = [l.brand, l.modelName].whereType<String>().where((s) => s.trim().isNotEmpty).join(' ');
    final facts = [
      (tr('Түрі'), label(categories, l.category)),
      if (name.isNotEmpty) (tr('Атауы'), name),
      // What the seller picked: what it is made of, season, country, the kind's own. Those not picked are left out.
      for (final key in factKeys(l.category))
        if (l.facts[key] case final option? when factText(key, option) != null)
          (tr(factNames[key]!), factText(key, option)!),
      (tr('Жағдайы'), label(conditions, l.condition)),
      if (l.audience != null) (tr('Кімге арналған'), label(audiences, l.audience)),
      (tr('Түпнұсқалығы'), label(authenticity, l.authenticity)),
      if (l.segment != null) (tr('Баға деңгейі'), label(segments, l.segment)),
    ];
    // With larger text the two columns leave the values too narrow (a long material word split in two): each name
    // then stands over its value.
    final stacked = MediaQuery.textScalerOf(context).scale(16) > 18;
    final muted = theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final strong = weight(theme.textTheme.bodyLarge!, 650);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (stacked)
        Column(key: const Key('facts'), crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final (name, value) in facts)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name, style: muted),
                Text(value, style: strong),
              ]),
            ),
        ])
      else
        Table(
          key: const Key('facts'),
          columnWidths: const {0: IntrinsicColumnWidth(), 1: FlexColumnWidth()},
          children: [
            for (final (name, value) in facts)
              TableRow(children: [
                Padding(padding: const EdgeInsets.fromLTRB(0, 5, 20, 5), child: Text(name, style: muted)),
                Padding(padding: const EdgeInsets.symmetric(vertical: 5), child: Text(value, style: strong)),
              ]),
          ],
        ),
      if ((l.description ?? '').trim().isNotEmpty) ...[
        const SizedBox(height: 14),
        Text(l.description!, key: const Key('description'), style: theme.textTheme.bodyLarge?.copyWith(height: 1.5)),
      ],
    ]);
  }
}
