import 'package:flutter/material.dart';

import '../api.dart';
import '../i18n.dart';
import '../session.dart';
import 'common.dart';

/// Cities the server can place, the same list it returns with an estimate.
const kzCities = [
  'Алматы',
  'Астана',
  'Шымкент',
  'Қарағанды',
  'Ақтөбе',
  'Тараз',
  'Павлодар',
  'Өскемен',
  'Семей',
  'Атырау',
  'Қостанай',
  'Қызылорда',
  'Орал',
  'Петропавл',
  'Ақтау',
  'Түркістан',
  'Көкшетау',
  'Талдықорған',
  'Екібастұз',
  'Жезқазған',
  'Қонаев',
];

const _months = ['қаң', 'ақп', 'нау', 'сәу', 'мам', 'мау', 'шіл', 'там', 'қыр', 'қаз', 'қар', 'жел'];

/// The city picked on a product page, kept while the app is open so every page shows the same one.
final pickedDeliveryCity = ValueNotifier<String?>(null);

/// "20–22 қаз" or "30 қаз – 2 қар".
String dateRange(DateTime a, DateTime b) {
  final ma = tr(_months[a.month - 1]), mb = tr(_months[b.month - 1]);
  if (a.month == b.month) return a.day == b.day ? '${a.day} $ma' : '${a.day}–${b.day} $ma';
  return '${a.day} $ma – ${b.day} $mb';
}

/// Under the delivery price: about when the pair arrives, and a tap to pick another city.
class DeliveryEta extends StatefulWidget {
  const DeliveryEta({super.key, required this.listingId});
  final int listingId;

  @override
  State<DeliveryEta> createState() => _DeliveryEtaState();
}

class _DeliveryEtaState extends State<DeliveryEta> {
  DeliveryEstimate? _estimate;
  List<String> _cities = const [];
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) _load(pickedDeliveryCity.value);
  }

  /// [asked]: the buyer picked the city, so a failure is said; the first, unasked load stays quiet.
  Future<void> _load(String? city, {bool asked = false}) async {
    _loaded = true;
    try {
      final (e, cities) = await SessionScope.of(context).api.deliveryEstimate(widget.listingId, city: city);
      // The buyer's pick is kept for the next listing only once it is shown here, so the two never differ.
      if (asked) pickedDeliveryCity.value = city;
      if (mounted) {
        setState(() {
          _estimate = e;
          _cities = cities;
        });
      }
    } catch (e) {
      // An estimate is a convenience; the page works without it.
      if (asked && mounted) showError(context, e);
    }
  }

  Future<void> _pick() async {
    final city = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(tr('Қай қалаға жеткізу?')),
        children: [
          for (final c in _cities)
            SimpleDialogOption(key: Key('eta-city-$c'), onPressed: () => Navigator.pop(context, c), child: Text(tr(c))),
        ],
      ),
    );
    if (city == null) return;
    await _load(city, asked: true);
  }

  @override
  Widget build(BuildContext context) {
    if (_cities.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final e = _estimate;
    return InkWell(
      key: const Key('delivery-eta'),
      onTap: _pick,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Icon(Icons.schedule_rounded, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text.rich(TextSpan(children: [
              if (e == null)
                TextSpan(text: tr('Қашан жететінін білу үшін қалаңызды таңдаңыз'))
              else ...[
                TextSpan(text: '${tr(e.city)}: '),
                TextSpan(
                    text: trf('шамамен {0}', [dateRange(e.earliest, e.latest)]),
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ],
            ])),
          ),
          Icon(Icons.expand_more_rounded, size: 18, color: theme.colorScheme.onSurfaceVariant),
        ]),
      ),
    );
  }
}
