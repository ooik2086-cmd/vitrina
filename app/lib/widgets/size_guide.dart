import 'package:flutter/material.dart';

import '../i18n.dart';
import '../my_size.dart';
import '../theme.dart';
import 'common.dart';

/// A common conversion between foot length and shop sizes. Brands differ by up to half a size, which is why
/// every listing also states each pair's insole length in centimetres.
const sizeChart = <({String cm, String eu, String uk, String usM, String usW})>[
  (cm: '22', eu: '35', uk: '2,5', usM: '3,5', usW: '5'),
  (cm: '22,5', eu: '36', uk: '3,5', usM: '4', usW: '5,5'),
  (cm: '23', eu: '36,5', uk: '4', usM: '4,5', usW: '6'),
  (cm: '23,5', eu: '37', uk: '4,5', usM: '5', usW: '6,5'),
  (cm: '24', eu: '38', uk: '5', usM: '5,5', usW: '7'),
  (cm: '24,5', eu: '38,5', uk: '5,5', usM: '6', usW: '7,5'),
  (cm: '25', eu: '39', uk: '6', usM: '6,5', usW: '8'),
  (cm: '25,5', eu: '40', uk: '6,5', usM: '7', usW: '8,5'),
  (cm: '26', eu: '40,5', uk: '7', usM: '7,5', usW: '9'),
  (cm: '26,5', eu: '41', uk: '7,5', usM: '8', usW: '9,5'),
  (cm: '27', eu: '42', uk: '8', usM: '8,5', usW: '10'),
  (cm: '27,5', eu: '42,5', uk: '8,5', usM: '9', usW: '10,5'),
  (cm: '28', eu: '43', uk: '9', usM: '9,5', usW: '11'),
  (cm: '28,5', eu: '44', uk: '9,5', usM: '10', usW: '11,5'),
  (cm: '29', eu: '44,5', uk: '10', usM: '10,5', usW: '12'),
  (cm: '29,5', eu: '45', uk: '10,5', usM: '11', usW: '12,5'),
  (cm: '30', eu: '46', uk: '11', usM: '11,5', usW: '13'),
];

/// Opens the guide; returns the centimetres the buyer picked (also saved as their size), or null.
Future<String?> showSizeGuide(BuildContext context) => showSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const SizeGuideSheet(),
    );

class SizeGuideSheet extends StatelessWidget {
  const SizeGuideSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final mine = mySize.value;
    TextStyle head = theme.textTheme.labelMedium!.copyWith(color: scheme.onSurfaceVariant);
    Widget cell(String text, {TextStyle? style, int flex = 1}) =>
        Expanded(flex: flex, child: Text(text, textAlign: TextAlign.center, style: style));
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: .85,
      maxChildSize: .95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: [
          Text(tr('Өлшем кестесі'), style: weight(theme.textTheme.titleLarge!, 800)),
          const SizedBox(height: 12),
          for (final (i, step) in [
            tr('Қағазға тұрып, өкше мен ең ұзын саусақтың ұшын белгілеңіз. Кешке өлшеңіз: аяқ сәл ісінеді.'),
            tr('Екі белгінің арасын сызғышпен өлшеңіз. Екі аяқты да өлшеп, үлкенін алыңыз.'),
            tr('Төмендегі кестеден сол сантиметрді басыңыз: каталог пен тауар беті сізге сай өлшемді көрсетеді.'),
          ].indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                CircleAvatar(
                  radius: 11,
                  backgroundColor: scheme.surfaceContainerHighest,
                  child: Text('${i + 1}', style: theme.textTheme.labelSmall),
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(step, style: theme.textTheme.bodyMedium)),
              ]),
            ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(children: [
              cell(tr('см'), style: head),
              cell('EU', style: head),
              cell('UK', style: head),
              cell(tr('US ер'), style: head),
              cell(tr('US әйел'), style: head),
            ]),
          ),
          for (final r in sizeChart)
            Material(
              color: r.cm == mine ? Brand.accent.withValues(alpha: .12) : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                key: Key('size-row-${r.cm}'),
                borderRadius: BorderRadius.circular(10),
                onTap: () async {
                  await setMySize(r.cm);
                  if (context.mounted) Navigator.pop(context, r.cm);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12), // a row is a finger's 48 tall
                  child: Row(children: [
                    cell(r.cm, style: weight(theme.textTheme.bodyLarge!, 700)),
                    cell(r.eu),
                    cell(r.uk),
                    cell(r.usM),
                    cell(r.usW),
                  ]),
                ),
              ),
            ),
          const SizedBox(height: 12),
          Text(
            tr('Брендтер арасында жарты өлшемге дейін айырма болады. Күмәндансаңыз, тауар бетіндегі ұлтарақ ұзындығына (см) және сатып алушылардың «өлшемі қалай келді» деген бағасына сүйеніңіз.'),
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
