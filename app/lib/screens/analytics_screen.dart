import 'package:flutter/material.dart';

import '../api.dart';
import '../i18n.dart';
import '../labels.dart';
import '../session.dart';
import '../theme.dart';
import 'manage_listing_screen.dart';

/// How the seller's listings are doing: daily views for the last two weeks, orders, sales and the top listings.
class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key});

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  Future<Analytics>? _data;
  int _days = 14;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _data ??= SessionScope.of(context).api.analytics(days: _days);
  }

  void _period(int days) => setState(() {
        _days = days;
        _data = SessionScope.of(context).api.analytics(days: days);
      });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr('Аналитика'))),
      body: FutureBuilder<Analytics>(
        future: _data,
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text('${snap.error}'));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final a = snap.data!;
          return ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 32), children: [
            SegmentedButton<int>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(value: 7, label: Text(tr('7 күн'))),
                ButtonSegment(value: 14, label: Text(tr('14 күн'))),
                ButtonSegment(value: 30, label: Text(tr('30 күн'))),
              ],
              selected: {_days},
              onSelectionChanged: (s) => _period(s.first),
            ),
            const SizedBox(height: 16),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.9,
              children: [
                _Tile(label: tr('Қаралым'), value: '${a.views}'),
                _Tile(label: tr('Тапсырыс'), value: '${a.orders}'),
                _Tile(
                    label: tr('Конверсия'),
                    value: a.conversion == null
                        ? '—'
                        : '${(a.conversion! * 100).toStringAsFixed(1).replaceAll('.', ',')}%'),
                _Tile(label: tr('Сатылды'), value: formatTenge(a.soldTiyn)),
              ],
            ),
            const SizedBox(height: 24),
            Text(tr('Күн сайынғы қаралым'), style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(tr('Бағанды басып, сол күнді көріңіз'),
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 12),
            ViewsChart(days: a.days),
            const SizedBox(height: 28),
            Text(tr('Ең көп қаралған тауарлар'), style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            if (a.top.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(tr('Бұл кезеңде қаралым әлі жоқ.'),
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ),
            for (final t in a.top)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(trf('{0} қаралым · {1} тапсырыс · {2}',
                    [t.views, t.orders, tr(listingStatuses[t.status] ?? t.status)])),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  final api = SessionScope.of(context).api;
                  final l = await api.listing(t.id);
                  if (!context.mounted) return;
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => ManageListingScreen(listing: l)));
                },
              ),
          ]);
        },
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(Brand.radius),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child:
          Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
        Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(value, style: weight(theme.textTheme.headlineSmall!, 800)),
        ),
      ]),
    );
  }
}

/// One series, so one colour and no legend: the title names it. Thin bars with rounded tops on a shared
/// baseline, a 2px gap between them, recessive gridlines. Tapping a bar shows that day's numbers.
class ViewsChart extends StatefulWidget {
  const ViewsChart({super.key, required this.days});
  final List<DayStats> days;

  @override
  State<ViewsChart> createState() => _ViewsChartState();
}

class _ViewsChartState extends State<ViewsChart> {
  int? _picked;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final days = widget.days;
    final lastActive = days.lastIndexWhere((d) => d.views > 0 || d.orders > 0);
    final picked =
        _picked == null || _picked! >= days.length ? (lastActive < 0 ? days.length - 1 : lastActive) : _picked!;
    final d = days[picked];
    final top = _niceMax(days.fold<int>(0, (m, d) => d.views > m ? d.views : m));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(
        trf('{0}: {1} қаралым, {2} тапсырыс',
            ['${d.date.day}.${d.date.month.toString().padLeft(2, '0')}', d.views, d.orders]),
        key: const Key('chart-readout'),
        style: theme.textTheme.bodyMedium,
      ),
      const SizedBox(height: 8),
      LayoutBuilder(builder: (context, box) {
        const height = 160.0;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (e) => setState(
              () => _picked = (e.localPosition.dx / box.maxWidth * days.length).floor().clamp(0, days.length - 1)),
          onHorizontalDragUpdate: (e) => setState(
              () => _picked = (e.localPosition.dx / box.maxWidth * days.length).floor().clamp(0, days.length - 1)),
          child: CustomPaint(
            size: Size(box.maxWidth, height),
            painter: _BarsPainter(
              values: [for (final d in days) d.views],
              max: top,
              picked: picked,
              bar: scheme.onSurface,
              dim: scheme.onSurface.withValues(alpha: 0.28),
              grid: scheme.outlineVariant,
            ),
          ),
        );
      }),
      const SizedBox(height: 6),
      Row(children: [
        Text('${days.first.date.day}.${days.first.date.month.toString().padLeft(2, '0')}',
            style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
        const Spacer(),
        Text(trf('ең көбі {0}', [top]), style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
        const Spacer(),
        Text('${days.last.date.day}.${days.last.date.month.toString().padLeft(2, '0')}',
            style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
      ]),
    ]);
  }

  static int _niceMax(int v) {
    if (v <= 5) return 5;
    for (final step in [10, 20, 25, 50, 100, 200, 250, 500, 1000, 2000, 5000, 10000]) {
      if (v <= step) return step;
    }
    return ((v / 10000).ceil()) * 10000;
  }
}

class _BarsPainter extends CustomPainter {
  _BarsPainter({
    required this.values,
    required this.max,
    required this.picked,
    required this.bar,
    required this.dim,
    required this.grid,
  });
  final List<int> values;
  final int max;
  final int picked;
  final Color bar, dim, grid;

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (final f in [0.0, 0.5, 1.0]) {
      final y = size.height - f * size.height;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
    final slot = size.width / values.length;
    const gap = 2.0;
    final width = (slot - gap).clamp(2.0, 18.0);
    for (var i = 0; i < values.length; i++) {
      final h = values[i] == 0 ? 0.0 : (values[i] / max * size.height).clamp(3.0, size.height);
      if (h == 0) continue;
      final left = i * slot + (slot - width) / 2;
      final rect = RRect.fromRectAndCorners(Rect.fromLTWH(left, size.height - h, width, h),
          topLeft: const Radius.circular(4), topRight: const Radius.circular(4));
      canvas.drawRRect(rect, Paint()..color = i == picked ? bar : dim);
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) => old.values != values || old.picked != picked || old.max != max;
}
