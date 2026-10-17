import 'package:flutter/material.dart';

import '../api.dart';
import '../labels.dart';
import '../session.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'order_screen.dart';

class OrdersScreen extends StatelessWidget {
  const OrdersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    if (!session.signedIn) return const SignInPrompt(text: 'Тапсырыстарыңызды көру үшін кіріңіз.');
    final seller = session.me?.isSeller ?? false;
    return DefaultTabController(
      length: seller ? 2 : 1,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Тапсырыстар'),
          bottom: seller ? const TabBar(tabs: [Tab(text: 'Сатып алғаным'), Tab(text: 'Сатқаным')]) : null,
        ),
        body: TabBarView(children: [
          const _OrderList(role: 'buyer'),
          if (seller) const _OrderList(role: 'seller'),
        ]),
      ),
    );
  }
}

class _OrderList extends StatefulWidget {
  const _OrderList({required this.role});
  final String role;

  @override
  State<_OrderList> createState() => _OrderListState();
}

class _OrderListState extends State<_OrderList> {
  Future<List<OrderInfo>>? _orders;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _orders ??= _load();
  }

  Future<List<OrderInfo>> _load() => SessionScope.of(context).api.orders(role: widget.role);

  Future<void> _reload() async {
    final f = _load();
    setState(() => _orders = f);
    await f;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<OrderInfo>>(
      future: _orders,
      builder: (context, snap) {
        if (snap.hasError) return Center(child: Text('${snap.error}'));
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final items = snap.data!;
        return RefreshIndicator(
          onRefresh: _reload,
          child: items.isEmpty
              ? ListView(children: const [SizedBox(height: 120), Center(child: Text('Әзірге тапсырыс жоқ.'))])
              : ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const Divider(indent: 96),
                  itemBuilder: (context, i) {
                    final o = items[i];
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: Container(
                          width: 56,
                          height: 56,
                          color: Brand.studio,
                          child: o.listingCover == null
                              ? const Icon(Icons.image_outlined)
                              : Image.network(o.listingCover!,
                                  fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.image_outlined)),
                        ),
                      ),
                      title: Text(o.listingTitle ?? 'Тапсырыс №${o.id}', maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(label(orderStatuses, o.status)),
                      trailing: Text(formatTenge(o.totalTiyn), style: const TextStyle(fontWeight: FontWeight.w700)),
                      onTap: () async {
                        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => OrderScreen(orderId: o.id)));
                        _reload();
                      },
                    );
                  },
                ),
        );
      },
    );
  }
}
