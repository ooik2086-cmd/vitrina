import 'package:flutter/material.dart';

import '../api.dart';
import '../session.dart';
import '../widgets/common.dart';
import '../i18n.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _phone = TextEditingController(text: '+7');
  final _code = TextEditingController();
  bool _codeSent = false;
  bool _busy = false;
  String? _devCode;

  @override
  void dispose() {
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  String get _normalizedPhone => _phone.text.replaceAll(RegExp(r'[\s()-]'), '');

  Future<void> _run(Future<void> Function(Session) step) async {
    setState(() => _busy = true);
    try {
      await step(SessionScope.of(context));
    } on ApiException catch (e) {
      if (mounted) showError(context, e);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _sendCode() => _run((s) async {
        final dev = await s.api.requestOtp(_normalizedPhone);
        setState(() {
          _codeSent = true;
          _devCode = dev;
        });
      });

  void _verify() => _run((s) async {
        await s.signIn(_normalizedPhone, _code.text.trim());
        if (mounted) Navigator.of(context).pop();
      });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('Кіру'))),
      body: ListView(padding: const EdgeInsets.all(24), children: [
        TextField(
          controller: _phone,
          enabled: !_codeSent,
          keyboardType: TextInputType.phone,
          decoration: InputDecoration(labelText: tr('Телефон нөмірі'), hintText: '+7 701 000 00 00'),
        ),
        if (_codeSent) ...[
          const SizedBox(height: 16),
          TextField(
            controller: _code,
            keyboardType: TextInputType.number,
            maxLength: 6,
            autofocus: true,
            decoration: InputDecoration(labelText: tr('SMS коды')),
          ),
          if (_devCode != null)
            Text(trf('Сынақ режимі: SMS жіберілмейді, код {0}', [_devCode]),
                style: TextStyle(color: Theme.of(context).colorScheme.tertiary)),
        ],
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _busy ? null : (_codeSent ? _verify : _sendCode),
          child: Text(_codeSent ? tr('Растау') : tr('Код алу')),
        ),
        if (_codeSent)
          TextButton(
            onPressed: _busy ? null : () => setState(() => _codeSent = false),
            child: Text(tr('Нөмірді өзгерту')),
          ),
      ]),
    );
  }
}
