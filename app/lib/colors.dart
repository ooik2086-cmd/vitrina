import 'package:flutter/material.dart';

import 'i18n.dart';

/// The shoe colours a seller picks from, by the Kazakh name the server stores (backend vitrina_core/colors.py, which
/// also turns "черный" or "black" typed by hand into "қара"). Each with the colour of its dot in the picker; the
/// two-tone and many-colour ones are drawn by [ColorDot].
const shoeColors = <String, Color>{
  'қара': Color(0xFF1B1B1F),
  'ақ': Color(0xFFF7F7F4),
  'сұр': Color(0xFF8E8E93),
  'қоңыр': Color(0xFF6D4C3D),
  'құм түсті': Color(0xFFD8C3A5),
  'сүт түсті': Color(0xFFF1E9D8),
  'көк': Color(0xFF2F6FD6),
  'көгілдір': Color(0xFF8EC9F0),
  'қою көк': Color(0xFF1F2A55),
  'жасыл': Color(0xFF3E8E5A),
  'хаки': Color(0xFF7A7A4E),
  'қызыл': Color(0xFFD23B3B),
  'бордо': Color(0xFF7B1E33),
  'қызғылт': Color(0xFFF2A7C0),
  'сары': Color(0xFFF2CF3B),
  'қызғылт сары': Color(0xFFF08A2C),
  'күлгін': Color(0xFF7E57C2),
  'күміс': Color(0xFFC0C0C8),
  'алтын': Color(0xFFC9A44C),
  'қара-ақ': Color(0xFF1B1B1F),
  'түрлі түсті': Color(0x00000000),
};

/// Two-tone names and the plain colours they are made of (backend PARTS): asking for black shows black-and-white too.
const colorParts = <String, List<String>>{
  'қара-ақ': ['қара', 'ақ'],
};

/// A stored colour in the interface language: the listed colours are translated, a colour the seller typed is shown
/// as typed.
String colorName(String stored) => shoeColors.containsKey(stored) ? tr(stored) : stored;

/// The colour of a listing: a dot for each listed colour to pick, or "another colour" to type one. Once picked, only
/// the pick shows, with a button to change it, so the list does not push the rest of the form away. The text stays
/// in [controller], as the plain field before it did.
class ColorField extends StatefulWidget {
  const ColorField({super.key, required this.controller, this.enabled = true});
  final TextEditingController controller;
  final bool enabled;

  @override
  State<ColorField> createState() => _ColorFieldState();
}

class _ColorFieldState extends State<ColorField> {
  late bool _other;
  late bool _open;

  /// What the seller typed under "another colour", kept while they look at a listed one.
  late String _typedText;

  @override
  void initState() {
    super.initState();
    final text = widget.controller.text;
    _other = _typed(text);
    _open = text.trim().isEmpty;
    _typedText = _other ? text : '';
  }

  /// A colour that is not on the list, typed by the seller (an empty field is not one yet).
  static bool _typed(String text) => text.trim().isNotEmpty && !shoeColors.containsKey(text.trim());

  String? _check(String? _) {
    final text = widget.controller.text.trim();
    if (text.length >= 2) return null;
    return _other ? tr('Түсін жазыңыз') : tr('Түсін таңдаңыз');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return FormField<String>(
      key: const Key('edit-color'),
      initialValue: widget.controller.text,
      validator: _check,
      builder: (state) {
        final picked = widget.controller.text.trim();
        void changed() {
          state.didChange(widget.controller.text);
          if (state.hasError) state.validate(); // the message goes as soon as the colour is there
        }

        Widget chip(String name) => ChoiceChip(
              key: Key('color-$name'),
              showCheckmark: false, // the dot stays: the chip's own colour says it is picked
              avatar: ColorDot(name, onPicked: !_other && picked == name),
              label: Text(tr(name)),
              selected: !_other && picked == name,
              onSelected: widget.enabled
                  ? (_) {
                      setState(() {
                        _other = false;
                        _open = false;
                      });
                      widget.controller.text = name;
                      changed();
                    }
                  : null,
            );
        final other = ChoiceChip(
          key: const Key('color-other'),
          showCheckmark: false,
          avatar: Icon(Icons.edit_outlined, size: 18, color: _other ? scheme.onPrimary : scheme.onSurfaceVariant),
          label: Text(tr('Басқа түс')),
          selected: _other,
          onSelected: widget.enabled
              ? (_) {
                  setState(() {
                    _other = true;
                    _open = true;
                  });
                  widget.controller.text = _typedText; // what they typed before, not the listed colour
                  changed();
                }
              : null,
        );
        return Semantics(
          container: true,
          label: tr('Түсі'),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 8),
                child: Text(tr('Түсі'), style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              ),
              if (!_open)
                Row(children: [
                  Flexible(
                    child: Chip(
                      key: const Key('color-picked'),
                      avatar: _other ? const Icon(Icons.edit_outlined, size: 18) : ColorDot(picked),
                      label: Text(colorName(picked), overflow: TextOverflow.ellipsis),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    key: const Key('color-change'),
                    onPressed: widget.enabled ? () => setState(() => _open = true) : null,
                    child: Text(tr('Өзгерту')),
                  ),
                ])
              else
                Wrap(spacing: 8, runSpacing: 4, children: [for (final name in shoeColors.keys) chip(name), other]),
              if (_open && _other)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: TextField(
                    key: const Key('color-other-text'),
                    controller: widget.controller,
                    enabled: widget.enabled,
                    autofocus: picked.isEmpty,
                    maxLength: 40,
                    decoration: InputDecoration(
                      labelText: tr('Түсін жазыңыз'),
                      hintText: tr('Мысалы: мәрмәр'),
                      errorText: state.errorText, // under the field it is about
                    ),
                    onChanged: (v) {
                      _typedText = v;
                      changed();
                    },
                  ),
                ),
              if (state.hasError && !(_open && _other))
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(state.errorText!, style: theme.textTheme.bodySmall?.copyWith(color: scheme.error)),
                ),
            ]),
          ),
        );
      },
    );
  }
}

/// The colour itself, in a ring so white and silver show on a white chip and dark colours on a dark picked chip.
class ColorDot extends StatelessWidget {
  const ColorDot(this.name, {super.key, this.onPicked = false});
  final String name;
  final bool onPicked;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const wheel = SweepGradient(colors: [
      Color(0xFFD23B3B),
      Color(0xFFF2CF3B),
      Color(0xFF3E8E5A),
      Color(0xFF2F6FD6),
      Color(0xFF7E57C2),
      Color(0xFFD23B3B),
    ]);
    // Black and white halves for the two-tone pair.
    const split = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFF1B1B1F), Color(0xFF1B1B1F), Color(0xFFF7F7F4), Color(0xFFF7F7F4)],
      stops: [0, 0.5, 0.5, 1],
    );
    final gradient = switch (name) {
      'түрлі түсті' => wheel,
      'қара-ақ' => split,
      _ => null,
    };
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: gradient == null ? shoeColors[name] : null,
        gradient: gradient,
        border: Border.all(color: onPicked ? scheme.onPrimary : scheme.outline, width: onPicked ? 1.5 : 1),
      ),
    );
  }
}
