import 'package:flutter/material.dart';

import '../api.dart';
import '../session.dart';
import '../theme.dart';

class Stars extends StatelessWidget {
  const Stars({super.key, required this.value, this.size = 16});
  final double value;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (var i = 1; i <= 5; i++)
        Icon(
          value >= i ? Icons.star_rounded : (value >= i - 0.5 ? Icons.star_half_rounded : Icons.star_outline_rounded),
          size: size,
          color: const Color(0xFFFFB020),
        ),
    ]);
  }
}

class SellerReviewsScreen extends StatelessWidget {
  const SellerReviewsScreen({super.key, required this.sellerId, required this.shopName, this.rating});
  final int sellerId;
  final String shopName;
  final double? rating;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(shopName)),
      body: FutureBuilder<List<Review>>(
        future: SessionScope.of(context).api.sellerReviews(sellerId),
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text('${snap.error}'));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final items = snap.data!;
          return ListView(padding: const EdgeInsets.all(20), children: [
            Row(children: [
              Text(rating?.toStringAsFixed(1) ?? '—', style: theme.textTheme.headlineMedium),
              const SizedBox(width: 12),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Stars(value: rating ?? 0, size: 20),
                Text('${items.length} пікір', style: theme.textTheme.bodyMedium),
              ]),
            ]),
            const SizedBox(height: 8),
            Text('Пікірді тек осы сатушыдан сатып алып, тапсырысты аяқтаған адам қалдыра алады.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 16),
            if (items.isEmpty) const Text('Әзірге пікір жоқ.'),
            for (final r in items) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(child: Text(r.buyerName, style: theme.textTheme.titleSmall)),
                      Stars(value: r.rating.toDouble()),
                    ]),
                    if (r.text != null) ...[const SizedBox(height: 8), Text(r.text!)],
                    if (r.sellerReply != null) ...[
                      const SizedBox(height: 10),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
                        child: Text('Сатушы: ${r.sellerReply}', style: weight(theme.textTheme.bodyMedium!, 500)),
                      ),
                    ],
                  ]),
                ),
              ),
              const SizedBox(height: 10),
            ],
          ]);
        },
      ),
    );
  }
}
