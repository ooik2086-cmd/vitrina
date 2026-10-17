import 'package:flutter/material.dart';

import '../api.dart';
import '../i18n.dart';
import '../labels.dart';
import '../session.dart';
import '../theme.dart';

/// Phone as the server stores it (+7XXXXXXXXXX), or null when it cannot be one.
String? normalizeKzPhone(String raw) {
  var p = raw.replaceAll(RegExp(r'[\s()\-]'), '');
  if (p.length == 11 && p.startsWith('8')) p = '+7${p.substring(1)}';
  if (p.length == 10 && p.startsWith('7')) p = '+7$p';
  return RegExp(r'^\+7\d{10}$').hasMatch(p) ? p : null;
}

/// What the buyer chose right before ordering.
class Checkout {
  const Checkout(this.delivery, {this.promoCode});
  final Delivery delivery;
  final String? promoCode;
}

/// Asked right before an order: who receives the pair and where. Filled in from the last order.
/// With [listingId], the buyer can also try the seller's promo code and see the new price.
/// With [itemPriceTiyn], the sheet ends with what the order will cost in all, so nothing surprises on the next step.
class DeliverySheet extends StatefulWidget {
  const DeliverySheet({super.key, this.listingId, this.itemPriceTiyn, this.deliveryPriceTiyn = 0});
  final int? listingId;
  final int? itemPriceTiyn;
  final int deliveryPriceTiyn;

  @override
  State<DeliverySheet> createState() => _DeliverySheetState();
}

class _DeliverySheetState extends State<DeliverySheet> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name, _phone, _city, _address, _note;
  final _promo = TextEditingController();
  bool _promoOpen = false, _checking = false;
  PromoPreview? _applied;
  String? _promoError;

  @override
  void initState() {
    super.initState();
    final me = context.getInheritedWidgetOfExactType<SessionScope>()?.notifier?.me;
    final last = me?.lastDelivery;
    _name = TextEditingController(text: last?.recipientName ?? me?.displayName ?? '');
    _phone = TextEditingController(text: last?.recipientPhone ?? me?.phone ?? '');
    _city = TextEditingController(text: last?.city ?? me?.city ?? '');
    _address = TextEditingController(text: last?.address ?? '');
    _note = TextEditingController(text: last?.note ?? '');
  }

  @override
  void dispose() {
    for (final c in [_name, _phone, _city, _address, _note, _promo]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _checkPromo() async {
    final code = _promo.text.trim();
    if (code.isEmpty) return;
    setState(() {
      _checking = true;
      _promoError = null;
    });
    try {
      final p = await SessionScope.of(context).api.checkPromo(widget.listingId!, code);
      if (mounted) setState(() => _applied = p);
    } on ApiException catch (e) {
      if (mounted) setState(() => _promoError = e.message);
    } catch (_) {
      if (mounted) setState(() => _promoError = tr('Байланыс жоқ. Қайта көріңіз.'));
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  void _submit() {
    if (!_form.currentState!.validate()) return;
    Navigator.pop(
      context,
      Checkout(
        Delivery(
          recipientName: _name.text.trim(),
          recipientPhone: normalizeKzPhone(_phone.text)!,
          city: _city.text.trim(),
          address: _address.text.trim(),
          note: _note.text.trim().isEmpty ? null : _note.text.trim(),
        ),
        promoCode: _applied?.code,
      ),
    );
  }

  Widget _promoBlock(ThemeData theme) {
    final applied = _applied;
    if (applied != null) {
      return Container(
        key: const Key('promo-applied'),
        padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(children: [
          const Icon(Icons.local_offer_rounded, size: 20, color: Brand.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(trf('{0}: −{1}', [applied.code, formatTenge(applied.discountTiyn)]),
                  style: weight(theme.textTheme.titleSmall!, 700)),
              Text(trf('Жеткізумен бірге төлейсіз: {0}', [formatTenge(applied.totalTiyn)]),
                  style: theme.textTheme.bodySmall),
            ]),
          ),
          IconButton(
            tooltip: tr('Промокодты алып тастау'),
            icon: const Icon(Icons.close_rounded),
            onPressed: () => setState(() => _applied = null),
          ),
        ]),
      );
    }
    if (!_promoOpen) {
      return TextButton.icon(
        key: const Key('promo-open'),
        onPressed: () => setState(() => _promoOpen = true),
        icon: const Icon(Icons.local_offer_outlined, size: 18),
        label: Text(tr('Промокод бар ма?')),
      );
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(
        child: TextField(
          key: const Key('promo-code'),
          controller: _promo,
          textCapitalization: TextCapitalization.characters,
          decoration: InputDecoration(labelText: tr('Промокод'), errorText: _promoError, errorMaxLines: 2),
          onSubmitted: (_) => _checkPromo(),
        ),
      ),
      const SizedBox(width: 8),
      SizedBox(
        height: 48, // the field's height, so the button lines up with it
        child: FilledButton.tonal(
          key: const Key('promo-apply'),
          onPressed: _checking ? null : _checkPromo,
          child: Text(tr('Қолдану')),
        ),
      ),
    ]);
  }

  /// Item, delivery, the promo code's cut and the sum, as the order screen will show them.
  Widget _summary(ThemeData theme, int item) {
    final discount = _applied?.discountTiyn ?? 0;
    Widget row(String label, String value, {TextStyle? style}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Expanded(child: Text(label, style: style ?? theme.textTheme.bodyMedium)),
            Text(value, style: style ?? theme.textTheme.bodyMedium),
          ]),
        );
    return Padding(
      key: const Key('checkout-summary'),
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(children: [
        row(tr('Тауар'), formatTenge(item)),
        row(tr('Жеткізу'), widget.deliveryPriceTiyn == 0 ? tr('Тегін') : formatTenge(widget.deliveryPriceTiyn)),
        if (discount > 0)
          row(trf('Промокод {0}', [_applied!.code]), '−${formatTenge(discount)}',
              style: theme.textTheme.bodyMedium?.copyWith(color: accentText(context))),
        const Divider(height: 16),
        row(tr('Жиыны'), formatTenge(_total!), style: weight(theme.textTheme.titleMedium!, 750)),
        const SizedBox(height: 4),
        Text(
            tr('Келесі қадамда төлейсіз. Ақша VITRINA-да сақталып, сатушыға тауарды алғаныңызды растағанда не тексеру мерзімі өткенде өтеді.'),
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ]),
    );
  }

  /// What the buyer pays: the promo preview's own sum once a code is applied, else item plus delivery.
  int? get _total {
    final item = widget.itemPriceTiyn;
    if (_applied != null) return _applied!.totalTiyn;
    return item == null ? null : item + widget.deliveryPriceTiyn;
  }

  String? _atLeast(String? v, int n, String message) => (v ?? '').trim().length < n ? message : null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    InputDecoration field(String label, {String? hint, IconData? icon}) =>
        InputDecoration(labelText: label, hintText: hint, prefixIcon: icon == null ? null : Icon(icon));
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 8, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: Form(
        key: _form,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('Жеткізу мекенжайы'), style: weight(theme.textTheme.titleLarge!, 800)),
            const SizedBox(height: 4),
            Row(children: [
              Icon(Icons.lock_outline_rounded, size: 16, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(
                child: Text(tr('Сатушы мекенжайды тек төлемнен кейін көреді.'),
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ),
            ]),
            const SizedBox(height: 16),
            TextFormField(
              key: const Key('delivery-name'),
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: field(tr('Алушының аты-жөні'), icon: Icons.person_outline),
              validator: (v) => _atLeast(v, 2, tr('Аты-жөнін жазыңыз')),
            ),
            const SizedBox(height: 10),
            TextFormField(
              key: const Key('delivery-phone'),
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: field(tr('Телефон'), hint: '+7 701 000 00 00', icon: Icons.phone_outlined),
              validator: (v) =>
                  normalizeKzPhone(v ?? '') == null ? tr('Телефонды +7 701 000 00 00 түрінде жазыңыз') : null,
            ),
            const SizedBox(height: 10),
            TextFormField(
              key: const Key('delivery-city'),
              controller: _city,
              textCapitalization: TextCapitalization.words,
              decoration: field(tr('Қала'), icon: Icons.location_city_outlined),
              validator: (v) => _atLeast(v, 2, tr('Қаланы жазыңыз')),
            ),
            const SizedBox(height: 10),
            TextFormField(
              key: const Key('delivery-address'),
              controller: _address,
              decoration: field(tr('Көше, үй, пәтер'), icon: Icons.home_outlined),
              validator: (v) => _atLeast(v, 5, tr('Көше мен үйді жазыңыз')),
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _note,
              maxLength: 200,
              decoration: field(tr('Курьерге ескерту (міндетті емес)'), icon: Icons.sticky_note_2_outlined),
            ),
            if (widget.listingId != null) ...[_promoBlock(theme), const SizedBox(height: 12)],
            const SizedBox(height: 8),
            if (widget.itemPriceTiyn != null) _summary(theme, widget.itemPriceTiyn!),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const Key('delivery-continue'),
                onPressed: _submit,
                child: Text(_total == null
                    ? tr('Тапсырысты рәсімдеу')
                    : trf('Тапсырысты рәсімдеу · {0}', [formatTenge(_total!)])),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
