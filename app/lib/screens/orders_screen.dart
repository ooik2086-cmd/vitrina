import 'package:flutter/material.dart';

import '../net_image.dart';
import '../api.dart';
import '../labels.dart';
import '../session.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'order_screen.dart';
import '../i18n.dart';

class OrdersScreen extends StatelessWidget {
  const OrdersScreen({super.key, this.sellerTab = false, this.onlyMine = false});

  /// Opened from the profile's to-do card: straight to the side and the orders that wait on this person.
  final bool sellerTab;
  final bool onlyMine;

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    if (!session.signedIn) return SignInPrompt(text: tr('Тапсырыстарыңызды көру үшін кіріңіз.'));
    final seller = session.me?.isSeller ?? false;
    final filter = onlyMine ? 'mine' : 'all';
    return DefaultTabController(
      length: seller ? 2 : 1,
      initialIndex: seller && sellerTab ? 1 : 0,
      child: Scaffold(
        appBar: AppBar(
          title: Text(tr('Тапсырыстар')),
          bottom: seller ? TabBar(tabs: [Tab(text: tr('Сатып алғаным')), Tab(text: tr('Сатқаным'))]) : null,
        ),
        body: TabBarView(children: [
          _OrderList(role: 'buyer', filter: filter),
          if (seller) _OrderList(role: 'seller', filter: filter),
        ]),
      ),
    );
  }
}

const _waitsForBuyer = {'CREATED', 'PAYMENT_PENDING', 'DELIVERED_PENDING_CONFIRMATION'};
const _waitsForSeller = {'PAID', 'SELLER_ACCEPTED', 'RETURN_REQUESTED'};
const finishedStatuses = {'COMPLETED', 'CANCELLED', 'REFUNDED'};

/// True when the next step is this side's: pay or confirm for the buyer, accept, ship or answer a return for the seller.
bool orderWaitsForMe(OrderInfo o, String role) =>
    (role == 'seller' ? _waitsForSeller : _waitsForBuyer).contains(o.status);

class _OrderList extends StatefulWidget {
  const _OrderList({required this.role, this.filter = 'all'});
  final String role;
  final String filter;

  @override
  State<_OrderList> createState() => _OrderListState();
}

class _OrderListState extends State<_OrderList> {
  Future<List<OrderInfo>>? _orders;
  late String _filter = widget.filter;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _orders ??= shown(_load());
  }

  Future<List<OrderInfo>> _load() => SessionScope.of(context).api.orders(role: widget.role);

  Future<void> _reload() async {
    final f = _load();
    setState(() {
      _orders = shown(f);
    });
    await settled(f);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<OrderInfo>>(
      future: _orders,
      builder: (context, snap) {
        if (snap.hasError && snap.connectionState == ConnectionState.done) {
          return ErrorRetry(error: snap.error, onRetry: _reload);
        }
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final all = snap.data!;
        bool keep(OrderInfo o, String f) => switch (f) {
              'mine' => orderWaitsForMe(o, widget.role),
              'active' => !finishedStatuses.contains(o.status),
              'done' => finishedStatuses.contains(o.status),
              _ => true,
            };
        final items = [
          for (final o in all)
            if (keep(o, _filter)) o
        ];
        final filters = [
          ('all', tr('Барлығы')),
          ('mine', tr('Сізді күтеді')),
          ('active', tr('Белсенді')),
          ('done', tr('Аяқталған')),
        ];
        return RefreshIndicator(
          onRefresh: _reload,
          child: all.isEmpty
              ? ListView(children: [SizedBox(height: 120), Center(child: Text(tr('Әзірге тапсырыс жоқ.')))])
              : ListView.separated(
                  itemCount: items.length + 1,
                  // Rows are capped one by one, so the filter chips above can still scroll the full width.
                  separatorBuilder: (_, i) =>
                      i == 0 ? const SizedBox.shrink() : const ContentWidth(child: Divider(indent: 96)),
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        SizedBox(
                          height: 64, // a chip's 48 tap height and the padding
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            padding: contentPadding(context, const EdgeInsets.fromLTRB(16, 10, 16, 6)),
                            children: [
                              for (final (code, name) in filters) ...[
                                ChoiceChip(
                                  key: Key('orders-${widget.role}-$code'),
                                  label: Text('$name ${all.where((o) => keep(o, code)).length}'),
                                  selected: _filter == code,
                                  onSelected: (_) => setState(() => _filter = code),
                                ),
                                const SizedBox(width: 8),
                              ],
                            ],
                          ),
                        ),
                        if (items.isEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 80),
                            child: Center(
                                child: Text(_filter == 'mine'
                                    ? tr('Сіздің әрекетіңізді күтетін тапсырыс жоқ.')
                                    : tr('Сай тапсырыс жоқ.'))),
                          ),
                      ]);
                    }
                    final o = items[index - 1];
                    final waits = orderWaitsForMe(o, widget.role);
                    return ContentWidth(
                        child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: Container(
                          width: 56,
                          height: 56,
                          color: Brand.studio,
                          child: o.listingCover == null
                              ? const Icon(Icons.image_outlined)
                              : Image(
                                  image: netImage(o.listingCover!),
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => const Icon(Icons.image_outlined)),
                        ),
                      ),
                      // Up to three lines: pairs of one model differ by the colour at the end of the title.
                      title: Text(o.listingTitle ?? trf('Тапсырыс №{0}', [o.id]),
                          maxLines: 3, overflow: TextOverflow.ellipsis),
                      subtitle: Text.rich(TextSpan(children: [
                        TextSpan(text: label(orderStatuses, o.status)),
                        if (waits)
                          TextSpan(
                              text: ' · ${tr('Сізді күтеді')}',
                              style: TextStyle(
                                  color: accentText(context),
                                  fontWeight: FontWeight.w700,
                                  fontVariations: const [FontVariation('wght', 700)])),
                      ])),
                      trailing: Text(formatTenge(o.totalTiyn),
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontVariations: [FontVariation('wght', 700)])),
                      onTap: () async {
                        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => OrderScreen(orderId: o.id)));
                        _reload();
                      },
                    ));
                  },
                ),
        );
      },
    );
  }
}
