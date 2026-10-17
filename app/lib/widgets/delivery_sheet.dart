import 'package:flutter/material.dart';

import '../api.dart';
import '../i18n.dart';
import '../session.dart';
import '../theme.dart';

/// Phone as the server stores it (+7XXXXXXXXXX), or null when it cannot be one.
String? normalizeKzPhone(String raw) {
  var p = raw.replaceAll(RegExp(r'[\s()\-]'), '');
  if (p.length == 11 && p.startsWith('8')) p = '+7${p.substring(1)}';
  if (p.length == 10 && p.startsWith('7')) p = '+7$p';
  return RegExp(r'^\+7\d{10}$').hasMatch(p) ? p : null;
}

/// Asked right before an order: who receives the pair and where. Filled in from the last order.
class DeliverySheet extends StatefulWidget {
  const DeliverySheet({super.key});

  @override
  State<DeliverySheet> createState() => _DeliverySheetState();
}

class _DeliverySheetState extends State<DeliverySheet> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name, _phone, _city, _address, _note;

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
    for (final c in [_name, _phone, _city, _address, _note]) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    if (!_form.currentState!.validate()) return;
    Navigator.pop(
      context,
      Delivery(
        recipientName: _name.text.trim(),
        recipientPhone: normalizeKzPhone(_phone.text)!,
        city: _city.text.trim(),
        address: _address.text.trim(),
        note: _note.text.trim().isEmpty ? null : _note.text.trim(),
      ),
    );
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
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const Key('delivery-continue'),
                onPressed: _submit,
                child: Text(tr('Тапсырысты рәсімдеу')),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
