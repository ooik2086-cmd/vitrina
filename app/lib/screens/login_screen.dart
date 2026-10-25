import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

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
  Timer? _timer;
  DateTime? _until; // when a new code may be asked for; a deadline, so time spent in the SMS app counts too

  int get _wait =>
      _until == null ? 0 : (_until!.difference(clock.now()).inMilliseconds / 1000).ceil().clamp(0, 1 << 30);

  @override
  void dispose() {
    _timer?.cancel();
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  /// The number as the server takes it, +7XXXXXXXXXX, however it was typed: 8 701…, 7 701…, 701… or +7 701….
  String get _normalizedPhone {
    final typed = _phone.text.replaceAll(RegExp(r'[\s()-]'), '');
    final digits = typed.replaceAll(RegExp(r'\D'), '');
    // Typed after the "+7" already in the field: +7 8 701… or +7 7 701….
    if (digits.length == 12 && digits.startsWith('7') && (digits[1] == '8' || digits[1] == '7')) {
      return '+7${digits.substring(2)}';
    }
    if (digits.length == 11 && (digits.startsWith('8') || digits.startsWith('7'))) return '+7${digits.substring(1)}';
    if (digits.length == 10 && digits.startsWith('7')) return '+7$digits';
    return typed.startsWith('+') ? '+$digits' : typed;
  }

  /// The code as typed or pasted, without the spaces or dashes a message may carry.
  String get _typedCode => _code.text.replaceAll(RegExp(r'\D'), '');
  bool get _codeTyped => _typedCode.length == 6;

  void _countDown(int seconds) {
    _timer?.cancel();
    setState(() => _until = clock.now().add(Duration(seconds: seconds)));
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() {});
      if (_wait == 0) t.cancel();
    });
  }

  void _changeNumber() {
    _timer?.cancel();
    setState(() {
      _codeSent = false;
      _until = null;
      _devCode = null;
      _code.clear();
    });
  }

  /// "45 сек" for a short wait, "12 мин" once the hourly or daily limit is reached.
  String get _waitText => _wait > 90 ? trf('{0} мин', [(_wait / 60).ceil()]) : trf('{0} сек', [_wait]);

  Future<void> _run(Future<void> Function(Session) step) async {
    setState(() => _busy = true);
    try {
      await step(SessionScope.of(context));
    } on ApiException catch (e) {
      // The server says how long until a new code: the code already sent is still on its way.
      if (e.code == 'otp_too_soon' && mounted) {
        setState(() => _codeSent = true);
        _countDown(int.tryParse(e.detail ?? '') ?? 60);
      } else if (e.code == 'rate_limited' && int.tryParse(e.detail ?? '') != null && mounted) {
        _countDown(int.parse(e.detail!)); // the hourly or daily limit: the button waits it out instead of failing
      }
      if (!mounted) return;
      if (e.code == 'account_blocked') {
        await showAccountBlocked(context, e);
      } else {
        if (e.code == 'otp_locked') _code.clear(); // that code is spent: a new one is asked for
        showError(context, e);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _sendCode() => _run((s) async {
        final again = _codeSent;
        final sent = await s.api.requestOtp(_normalizedPhone);
        if (!mounted) return;
        if (again) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(tr('Жаңа код жіберілді. Бұрынғы код та жарамды.'))));
        }
        setState(() {
          _codeSent = true;
          _devCode = sent.devCode;
        });
        _countDown(sent.resendAfter);
      });

  void _verify() => _run((s) async {
        await s.signIn(_normalizedPhone, _typedCode);
        if (mounted) Navigator.of(context).pop();
      });

  @override
  void initState() {
    super.initState();
    _code.addListener(() => setState(() {})); // "Растау" waits for all six digits: a short code only uses up a try
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('Кіру'))),
      body: ListView(padding: contentPadding(context, const EdgeInsets.all(24)), children: [
        TextField(
          controller: _phone,
          enabled: !_codeSent,
          keyboardType: TextInputType.phone,
          decoration: InputDecoration(labelText: tr('Телефон нөмірі'), hintText: '+7 701 000 00 00'),
        ),
        if (_codeSent) ...[
          const SizedBox(height: 8),
          Text(trf('Код {0} нөміріне жіберілді', [_normalizedPhone]), style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          TextField(
            key: const Key('otp-code'),
            controller: _code,
            keyboardType: TextInputType.number,
            maxLength: 6,
            autofocus: true,
            autofillHints: const [AutofillHints.oneTimeCode],
            decoration: InputDecoration(labelText: tr('SMS коды')),
          ),
          if (_devCode != null)
            Text(trf('Сынақ режимі: SMS жіберілмейді, код {0}', [_devCode]),
                style: TextStyle(color: Theme.of(context).colorScheme.tertiary)),
        ],
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _busy || (!_codeSent && _wait > 0) || (_codeSent && !_codeTyped)
              ? null
              : (_codeSent ? _verify : _sendCode),
          child: Text(_codeSent
              ? tr('Растау')
              : _wait > 0
                  ? trf('Жаңа код: {0} кейін', [_waitText])
                  : tr('Код алу')),
        ),
        if (!_codeSent) ...[
          const SizedBox(height: 12),
          Text(tr('Кодты алу арқылы сіз жеке деректеріңізді жинауға және өңдеуге келісім бересіз.'),
              textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
          TextButton(
            key: const Key('privacy'),
            onPressed: () => launchUrl(Uri.parse(privacyUrl(appLanguage.value)), mode: LaunchMode.externalApplication)
                .catchError((_) => false),
            child: Text(tr('Құпиялылық саясаты')),
          ),
        ],
        if (_codeSent) ...[
          TextButton(
            key: const Key('resend-code'),
            onPressed: _busy || _wait > 0 ? null : _sendCode,
            child: Text(_wait > 0 ? trf('Жаңа код: {0} кейін', [_waitText]) : tr('Кодты қайта жіберу')),
          ),
          TextButton(
            onPressed: _busy ? null : _changeNumber,
            child: Text(tr('Нөмірді өзгерту')),
          ),
        ],
      ]),
    );
  }
}

/// The account is blocked: said in a box that stays until closed, with where to write (the server's support contact,
/// when it gave one) to copy down.
Future<void> showAccountBlocked(BuildContext context, ApiException e) => showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('account-blocked'),
        title: Text(e.message),
        content: (e.detail ?? '').isEmpty ? null : SelectableText(e.detail!),
        actions: [FilledButton(onPressed: () => Navigator.pop(context), child: Text(tr('Жабу')))],
      ),
    );
