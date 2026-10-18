import 'package:flutter/material.dart';

import 'i18n.dart';

/// The shoe colours a seller picks from, by the Kazakh name the server stores (backend vitrina_core/colors.py, which
/// also turns "черный" or "black" typed by hand into "қара"). Each with the colour of its dot in the picker.
const shoeColors = <String, Color>{
  'қара': Color(0xFF1B1B1F),
  'ақ': Color(0xFFF7F7F4),
  'сұр': Color(0xFF8E8E93),
  'қоңыр': Color(0xFF6D4C3D),
  'құм': Color(0xFFD8C3A5),
  'көк': Color(0xFF2F6FD6),
  'көгілдір': Color(0xFF8EC9F0),
  'қою көк': Color(0xFF1F2A55),
  'жасыл': Color(0xFF3E8E5A),
  'қызыл': Color(0xFFD23B3B),
  'қызғылт': Color(0xFFF2A7C0),
  'сары': Color(0xFFF2CF3B),
  'қызғылт сары': Color(0xFFF08A2C),
  'күлгін': Color(0xFF7E57C2),
  'күміс': Color(0xFFC0C0C8),
  'алтын': Color(0xFFC9A44C),
  'аралас': Color(0x00000000), // drawn as a wheel of colours
};

/// A stored colour in the interface language: the listed colours are translated, a colour the seller typed is shown
/// as typed.
String colorName(String stored) => shoeColors.containsKey(stored) ? tr(stored) : stored;

/// The colour of a listing: a dot for each listed colour to pick, or "another colour" to type one. The text stays in
/// [controller], as the plain field before it did.
class ColorField extends StatefulWidget {
  const ColorField({super.key, required this.controller, this.enabled = true});
  final TextEditingController controller;
  final bool enabled;

  @override
  State<ColorField> createState() => _ColorFieldState();
}

class _ColorFieldState extends State<ColorField> {
  late bool _other = _typed(widget.controller.text);

  /// A colour that is not on the list, typed by the seller (an empty field is not one yet).
  static bool _typed(String text) => text.trim().isNotEmpty && !shoeColors.containsKey(text.trim());

  void _pick(String name) {
    setState(() => _other = false);
    widget.controller.text = name;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return FormField<String>(
      key: const Key('edit-color'),
      initialValue: widget.controller.text,
      validator: (_) => widget.controller.text.trim().length < 2 ? tr('Түсін таңдаңыз') : null,
      builder: (state) {
        final picked = widget.controller.text.trim();
        Widget chip(String name) => ChoiceChip(
              key: Key('color-$name'),
              showCheckmark: false, // the dot stays: the chip's own colour says it is picked
              avatar: _Dot(name),
              label: Text(tr(name)),
              selected: !_other && picked == name,
              onSelected: widget.enabled
                  ? (_) {
                      _pick(name);
                      state.didChange(name);
                    }
                  : null,
            );
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 8),
            child: Text(tr('Түсі'), style: theme.textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant)),
          ),
          Wrap(spacing: 8, runSpacing: 4, children: [
            for (final name in shoeColors.keys) chip(name),
            ChoiceChip(
              key: const Key('color-other'),
              showCheckmark: false,
              avatar: const Icon(Icons.edit_outlined, size: 18),
              label: Text(tr('Басқа түс')),
              selected: _other,
              onSelected: widget.enabled
                  ? (_) {
                      setState(() => _other = true);
                      if (shoeColors.containsKey(picked)) widget.controller.clear();
                      state.didChange(widget.controller.text);
                    }
                  : null,
            ),
          ]),
          if (_other)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextField(
                key: const Key('color-other-text'),
                controller: widget.controller,
                enabled: widget.enabled,
                autofocus: picked.isEmpty,
                maxLength: 40,
                decoration: InputDecoration(labelText: tr('Түсін жазыңыз'), hintText: tr('Мысалы: бордо')),
                onChanged: state.didChange,
              ),
            ),
          if (state.hasError)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(state.errorText!, style: theme.textTheme.bodySmall?.copyWith(color: scheme.error)),
            ),
        ]);
      },
    );
  }
}

/// The colour itself, in a ring so white and silver show on a white chip.
class _Dot extends StatelessWidget {
  const _Dot(this.name);
  final String name;

  @override
  Widget build(BuildContext context) {
    const wheel = SweepGradient(colors: [
      Color(0xFFD23B3B),
      Color(0xFFF2CF3B),
      Color(0xFF3E8E5A),
      Color(0xFF2F6FD6),
      Color(0xFF7E57C2),
      Color(0xFFD23B3B),
    ]);
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: name == 'аралас' ? null : shoeColors[name],
        gradient: name == 'аралас' ? wheel : null,
        border: Border.all(color: Theme.of(context).colorScheme.outline, width: 1),
      ),
    );
  }
}
