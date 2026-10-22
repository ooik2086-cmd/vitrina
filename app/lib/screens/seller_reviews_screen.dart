import 'package:flutter/material.dart';

import '../net_image.dart';
import '../api.dart';
import '../session.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../i18n.dart';
import '../labels.dart';

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

class SellerReviewsScreen extends StatefulWidget {
  const SellerReviewsScreen(
      {super.key, required this.sellerId, required this.shopName, this.rating, this.inSheet = false});
  final int sellerId;
  final String shopName;
  final double? rating;

  /// Shown in a sheet over the listing page: closed by its round × as the page's other sheets, not a back arrow.
  final bool inSheet;

  @override
  State<SellerReviewsScreen> createState() => _SellerReviewsScreenState();
}

class _SellerReviewsScreenState extends State<SellerReviewsScreen> {
  Future<List<Review>>? _items;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _items ??= shown(SessionScope.of(context).api.sellerReviews(widget.sellerId));
  }

  void _retry() {
    setState(() {
      _items = shown(SessionScope.of(context).api.sellerReviews(widget.sellerId));
    });
  }

  /// The seller answers each review once, in public, under the buyer's words.
  Future<void> _reply(Review r) async {
    final text = TextEditingController();
    final answer = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Пікірге жауап')),
        content: TextField(
          controller: text,
          autofocus: true,
          maxLines: 4,
          maxLength: 1000,
          decoration: InputDecoration(hintText: tr('Жауабыңызды барлық сатып алушылар көреді')),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Болдырмау'))),
          FilledButton(onPressed: () => Navigator.pop(context, text.text.trim()), child: Text(tr('Жіберу'))),
        ],
      ),
    );
    if (answer == null || answer.isEmpty || !mounted) return;
    try {
      await SessionScope.of(context).api.replyToReview(r.id, answer);
      if (mounted) {
        setState(() {
          _items = shown(SessionScope.of(context).api.sellerReviews(widget.sellerId));
        });
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rating = widget.rating;
    final isOwner = SessionScope.of(context).me?.id == widget.sellerId;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.inSheet,
        title: Text(widget.shopName),
        actions: [
          if (widget.inSheet)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: IconButton.outlined(
                key: const Key('sheet-close'),
                tooltip: tr('Жабу'),
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded, size: 20),
              ),
            ),
        ],
      ),
      body: FutureBuilder<List<Review>>(
        future: _items,
        builder: (context, snap) {
          if (snap.hasError && snap.connectionState == ConnectionState.done) {
            return ErrorRetry(error: snap.error, onRetry: _retry);
          }
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final items = snap.data!;
          return ListView(padding: contentPadding(context, const EdgeInsets.all(20)), children: [
            Row(children: [
              Text(rating == null ? '—' : ratingText(rating), style: theme.textTheme.headlineMedium),
              const SizedBox(width: 12),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Stars(value: rating ?? 0, size: 20),
                Text(trf('{0} пікір', [items.length]), style: theme.textTheme.bodyMedium),
              ]),
            ]),
            const SizedBox(height: 8),
            Text(tr('Пікірді тек осы сатушыдан сатып алып, тапсырысты аяқтаған адам қалдыра алады.'),
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 16),
            if (items.isEmpty) Text(tr('Әзірге пікір жоқ.')),
            for (final r in items) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(child: Text(personName(r.buyerName), style: theme.textTheme.titleSmall)),
                      Stars(value: r.rating.toDouble()),
                    ]),
                    if (r.fit != null) ...[
                      const SizedBox(height: 6),
                      Text(trf('Өлшемі: {0}', [tr(fits[r.fit] ?? r.fit!)]),
                          style: theme.textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.w600, fontVariations: const [FontVariation('wght', 600)])),
                    ],
                    if (r.text != null) ...[const SizedBox(height: 8), Text(r.text!)],
                    if (r.photos.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Wrap(spacing: 8, children: [
                        for (final url in r.photos)
                          Semantics(
                            button: true,
                            label: tr('Фотоны ашу'),
                            child: GestureDetector(
                              onTap: () => showDialog<void>(
                                context: context,
                                builder: (_) => Dialog(
                                  insetPadding: const EdgeInsets.all(12),
                                  clipBehavior: Clip.antiAlias,
                                  child: InteractiveViewer(
                                      child: Image(
                                          image: netImage(url),
                                          fit: BoxFit.contain,
                                          errorBuilder: (_, __, ___) => const SizedBox(
                                              height: 200, child: Center(child: Icon(Icons.broken_image_outlined))))),
                                ),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: Image(
                                    image: netImage(url),
                                    key: Key('review-photo-$url'),
                                    width: 84,
                                    height: 84,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) =>
                                        Container(width: 84, height: 84, color: Brand.studio)),
                              ),
                            ),
                          ),
                      ]),
                    ],
                    if (r.sellerReply != null) ...[
                      const SizedBox(height: 10),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
                        child:
                            Text(trf('Сатушы: {0}', [r.sellerReply]), style: weight(theme.textTheme.bodyMedium!, 500)),
                      ),
                    ] else if (isOwner)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: () => _reply(r),
                          icon: const Icon(Icons.reply_rounded, size: 18),
                          label: Text(tr('Жауап беру')),
                        ),
                      ),
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
