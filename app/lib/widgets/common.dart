import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../net_image.dart';
import '../quick_replies.dart';
import '../api.dart';
import '../labels.dart';
import '../screens/listing_screen.dart';
import '../screens/login_screen.dart';
import '../theme.dart';
import '../i18n.dart';
import 'studio.dart';
import 'card_turn.dart';
import 'model_stage.dart';

void showError(BuildContext context, Object error) {
  final text = error is ApiException ? error.message : tr('Байланыс жоқ. Қайта көріңіз.');
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}

/// A load a FutureBuilder shows. Its failure is the builder's to show, so it is never also reported as unhandled,
/// even when it fails before the builder listens (a phone in flight mode fails at once).
Future<T> shown<T>(Future<T> load) => load..ignore();

final _running = <Object>{};

/// Runs [action] unless the one started under the same [key] still runs: a second tap while a slow connection keeps
/// the first waiting would otherwise send it twice, or open its page twice. The second tap is simply let go.
Future<void> once(Object key, Future<void> Function() action) async {
  if (!_running.add(key)) return;
  try {
    await action();
  } finally {
    _running.remove(key);
  }
}

/// Waits for [load] for a pull to refresh. A failure is shown on the screen, not thrown here as well.
Future<void> settled(Future<Object?> load) => load.then((_) {}, onError: (_) {});

/// A length counter shown only near the limit: until then a refusal under the field has the whole width to itself,
/// which at large text is the difference between a readable line and a narrow column.
Widget? nearLimitCounter(BuildContext context,
        {required int currentLength, required bool isFocused, required int? maxLength}) =>
    maxLength != null && currentLength >= maxLength * 0.8
        ? Text('$currentLength/$maxLength', style: Theme.of(context).textTheme.bodySmall)
        : null;

/// The pieces a contacts refusal names, as the server quoted them («a», «b»), a piece cut short ending in «…»; none
/// for any other error.
List<String> refusedContacts(Object? error) {
  if (error is! ApiException || error.code != 'contacts_not_allowed') return const [];
  return contactPieces(error.detail);
}

/// The pieces in what the server found («a», «b»): a refusal's detail or a held listing's moderation.found.
List<String> contactPieces(String? found) => [
      for (final piece in (found ?? '').split('», «'))
        if (piece.isNotEmpty) piece
    ];

/// Whether [text] holds [piece] as written, as a whole word, any run of spaces standing for a space.
bool holdsPiece(String text, String piece) => _pieceIn(piece).hasMatch(text);

/// Where [piece] stands in the words as a whole word. The server quotes it from text with each run of spaces made
/// one, so any run of spaces or line breaks stands for a space.
RegExp _pieceIn(String piece) =>
    RegExp('(?<![\\p{L}\\p{N}_])${piece.split(RegExp(r'\s+')).map(RegExp.escape).join(r'\s+')}(?![\\p{L}\\p{N}_])',
        unicode: true);

/// The pieces one tap can take out of [text]: all that the refusal names, or none when any of them is not in the
/// words as written (a piece cut short ends in «…», so it is not), so the tap never leaves a named contact behind.
List<String> removableContacts(Object? error, String text) {
  final pieces = refusedContacts(error);
  if (pieces.any((p) => !holdsPiece(text, p))) return const [];
  return pieces;
}

const _gone = '\u0000';
const _joiners = ',;:–—-';
const _closers = '.,;:!?)';

/// [text] with [pieces] taken out. Only the lines that held them change: the gap closes with one space, a label's
/// colon or a comma left with nothing to join goes too, and a line left empty is dropped.
String withoutPieces(String text, List<String> pieces) {
  var out = text;
  for (final piece in [...pieces]..sort((a, b) => b.length - a.length)) {
    out = out.replaceAll(_pieceIn(piece), _gone); // the longest first, so a shorter one cannot split it
  }
  out = out.replaceAll(RegExp('[(«"“„]\\s*$_gone\\s*[)»"”“]'), _gone); // brackets or quotes left empty go with it
  final lines = <String>[];
  for (var line in out.split('\n')) {
    if (!line.contains(_gone)) {
      lines.add(line);
      continue;
    }
    while (line.contains(_gone)) {
      final at = line.indexOf(_gone);
      var left = line.substring(0, at).trimRight();
      var right = line.substring(at + 1).trimLeft();
      if (left.isNotEmpty &&
          _joiners.contains(left[left.length - 1]) &&
          (right.isEmpty || _closers.contains(right[0]) || right[0] == _gone)) {
        left = left.substring(0, left.length - 1).trimRight(); // «Жазыңыз: …» at the end: «Жазыңыз»
      }
      if (left.isEmpty && right.isNotEmpty && _joiners.contains(right[0])) {
        right = right.substring(1).trimLeft(); // «…, сурет көп» at the start: «сурет көп»
      }
      final glue = left.isEmpty || right.isEmpty || _closers.contains(right[0]) ? '' : ' ';
      line = '$left$glue$right';
    }
    if (line.trim().isNotEmpty) lines.add(line);
  }
  return lines.join('\n').trim();
}

/// A refusal as shown under a field: when [RemoveContactsButton] can take every named piece out, only the line naming
/// them, so the button stands right under it, even at large text; otherwise the whole refusal.
String refusalText(Object? error, String text) {
  if (error is ApiException && removableContacts(error, text).isNotEmpty) return error.foundLine ?? errorText(error);
  return errorText(error);
}

/// Under a refused field: one tap takes out what the server found, so a seller need not hunt for it in her words.
/// Nothing is sent: she sees the rest and sends it herself. [onRemoved] hears whether the rest is clean by the app's
/// own copy of the rule (the server names three at most).
class RemoveContactsButton extends StatelessWidget {
  const RemoveContactsButton(
      {super.key, required this.error, required this.controller, required this.onRemoved, this.showRule = false});
  final Object? error;
  final TextEditingController controller;
  final ValueChanged<bool> onRemoved;

  /// Also says the rule under the button, where nothing else near the field does.
  final bool showRule;

  @override
  Widget build(BuildContext context) {
    final pieces = removableContacts(error, controller.text);
    if (pieces.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final button = Align(
      alignment: AlignmentDirectional.centerStart,
      child: FilledButton.tonalIcon(
        key: const Key('remove-contacts'),
        style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
        icon: const Icon(Icons.backspace_outlined),
        label: Text(tr('Мәтіннен алып тастау')),
        onPressed: () {
          final text = withoutPieces(controller.text, pieces);
          controller.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
          final clean = !looksLikeContact(text);
          onRemoved(clean);
          SemanticsService.sendAnnouncement(
              View.of(context),
              tr(clean ? 'Байланыс мәтіннен алынды.' : 'Мәтінде тағы байланыс бар. Оны да алып тастаңыз.'),
              Directionality.of(context));
        },
      ),
    );
    if (!showRule) return button;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      button,
      Text((error as ApiException).reason,
          key: const Key('remove-contacts-rule'),
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
    ]);
  }
}

/// What a tap that left a contact behind shows under the field.
ApiException moreContacts() =>
    ApiException.local(422, 'contacts_left', 'Мәтінде тағы байланыс бар. Оны да алып тастаңыз.');

/// A failed load in people's words: the server's own message when it sent one, never a raw exception.
String errorText(Object? error) => error is ApiException ? error.message : tr('Серверге қосылу мүмкін болмады.');

/// Widest a screen's text column grows on a tablet or the web; phones are narrower than this anyway.
const maxContentWidth = 640.0;

/// Every bottom sheet in the app. Its content stays above the phone's own buttons or gesture bar, which on new Android
/// phones draw over the app (Aza, 2026-10-24: the sheet's last button sat under them and could not be pressed).
Future<T?> showSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  bool? showDragHandle,
  bool useSafeArea = false,
  Color? backgroundColor,
  Clip? clipBehavior,
}) =>
    showModalBottomSheet<T>(
      context: context,
      isScrollControlled: isScrollControlled,
      showDragHandle: showDragHandle,
      useSafeArea: useSafeArea,
      backgroundColor: backgroundColor,
      clipBehavior: clipBehavior,
      builder: (context) => SafeArea(top: false, child: builder(context)),
    );

/// [base] padding widened at the sides so the column, padding included, stays [maxContentWidth] wide and centred,
/// the same box [ContentWidth] draws, so capped lists, rows and chip strips line up on a wide screen.
/// For lists, so the whole screen still scrolls and only the column narrows.
EdgeInsets contentPadding(BuildContext context, EdgeInsets base) {
  final extra = (MediaQuery.sizeOf(context).width - maxContentWidth) / 2;
  return extra <= 0 ? base : base.copyWith(left: base.left + extra, right: base.right + extra);
}

/// Keeps a screen body no wider than [maxContentWidth], centred, on wide screens.
class ContentWidth extends StatelessWidget {
  const ContentWidth({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: maxContentWidth), child: child),
      );
}

/// An icon, one friendly line and an optional action: for empty lists and failed loads.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.text, this.action});
  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 40, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(text, style: theme.textTheme.bodyLarge, textAlign: TextAlign.center),
          if (action != null) action!,
        ]),
      ),
    );
  }
}

/// A load that failed, with a retry. Used wherever a screen has nothing to show but the error.
class ErrorRetry extends StatelessWidget {
  const ErrorRetry({super.key, required this.error, required this.onRetry});
  final Object? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final e = error;
    return EmptyState(
      icon: e is ApiException && !e.offline ? Icons.error_outline_rounded : Icons.wifi_off_rounded,
      text: errorText(e),
      action: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: TextButton(key: const Key('retry'), onPressed: onRetry, child: Text(tr('Қайта көру'))),
      ),
    );
  }
}

/// A part of a screen that failed to load, as one line with a retry, where the rest of the screen did load. Without
/// it the part would just be missing and nobody would know to try again. [what] names the part; while [busy] the
/// line stays where it is with a small spinner, so the page does not jump and a screen reader keeps its place.
class RetryLine extends StatelessWidget {
  const RetryLine({super.key, required this.what, required this.error, required this.onRetry, this.busy = false});
  final String what;
  final Object? error;
  final VoidCallback onRetry;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final e = error;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(children: [
        SizedBox(
          width: 20,
          height: 20,
          child: busy
              ? const CircularProgressIndicator(strokeWidth: 2)
              : Icon(e is ApiException && !e.offline ? Icons.error_outline_rounded : Icons.wifi_off_rounded,
                  size: 20, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(width: 12),
        Expanded(
          // Said again when a retry fails too.
          child: Semantics(
            liveRegion: true,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(what, style: theme.textTheme.titleSmall),
              Text(errorText(e), style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            ]),
          ),
        ),
        TextButton(key: const Key('retry'), onPressed: busy ? null : onRetry, child: Text(tr('Қайта көру'))),
      ]),
    );
  }
}

/// Shown on tabs that need an account.
class SignInPrompt extends StatelessWidget {
  const SignInPrompt({super.key, required this.text, this.below});
  final String text;
  final Widget? below;

  @override
  Widget build(BuildContext context) {
    // Scrolls when large text and a short phone leave too little room for all three.
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(text, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LoginScreen())),
            child: Text(tr('Кіру')),
          ),
          if (below != null) ...[const SizedBox(height: 8), below!],
        ]),
      ),
    );
  }
}

/// Camera or gallery, asked in a bottom sheet. Null when the person cancels.
Future<XFile?> pickPhoto(BuildContext context, {String? title, String? subtitle}) async {
  final source = await showSheet<ImageSource>(
    context: context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (title != null) ListTile(title: Text(title), subtitle: subtitle == null ? null : Text(subtitle)),
        ListTile(
          leading: const Icon(Icons.photo_camera_outlined),
          title: Text(tr('Камера')),
          onTap: () => Navigator.pop(context, ImageSource.camera),
        ),
        ListTile(
          leading: const Icon(Icons.photo_library_outlined),
          title: Text(tr('Галерея')),
          onTap: () => Navigator.pop(context, ImageSource.gallery),
        ),
      ])),
    ),
  );
  if (source == null || !context.mounted) return null;
  return takePhoto(context, () => ImagePicker().pickImage(source: source, maxWidth: 1600, imageQuality: 90),
      camera: source == ImageSource.camera);
}

/// The phone's camera or gallery. Refused (no permission, the picker failed): said in words, never a tap that does
/// nothing.
Future<XFile?> takePhoto(BuildContext context, Future<XFile?> Function() pick, {required bool camera}) async {
  try {
    return await pick();
  } catch (e) {
    // image_picker names a refused permission camera_access_denied / photo_access_denied; anything else is a file
    // that did not open, and asking to change the settings would send the seller the wrong way.
    final refused = e is PlatformException && e.code.contains('access_denied');
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        duration: const Duration(seconds: 8),
        content: Text(!refused
            ? tr('Фотоны ашу мүмкін болмады. Қайта көріңіз.')
            : camera
                ? tr('Камераға рұқсат берілмеді. Телефон баптауларынан рұқсат беріңіз.')
                : tr('Фотоларға рұқсат берілмеді. Телефон баптауларынан рұқсат беріңіз.')),
      ));
    }
    return null;
  }
}

/// ҚАЗ / РУС / ENG, with the full name as a tooltip. Every screen is rebuilt in the chosen language.
class LanguageSwitch extends StatelessWidget {
  const LanguageSwitch({super.key});

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<String>(
      key: const Key('language'),
      showSelectedIcon: false,
      // Narrow, as the short names need, but a finger's 48 tall.
      style: const ButtonStyle(minimumSize: WidgetStatePropertyAll(Size(56, 48))),
      segments: [
        for (final e in languages.entries)
          ButtonSegment(value: e.key, label: Text(languageShort[e.key]!), tooltip: e.value),
      ],
      selected: {appLanguage.value},
      onSelectionChanged: (s) => setLanguage(s.first),
    );
  }
}

/// A listing's cover as tiles and the page opening from them draw it, so both share one decoded copy.
/// A tile is at most 240 wide; three times that covers dense screens.
ImageProvider coverImage(String url) => ResizeImage.resizeIfNeeded(720, null, netImage(url));

class ListingTile extends StatelessWidget {
  const ListingTile({super.key, required this.listing});
  final Listing listing;

  Widget _cover(String url) => CoverPhoto(
      image: coverImage(url),
      cutout: listing.coverIsCutout,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined, color: Colors.black26));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cover = listing.coverUrl;
    return GestureDetector(
      // The 3D's first picture comes down while the finger is still on the card.
      onTapDown: listing.model == null ? null : (_) => ModelStage.prepare(context, listing.model!),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ListingScreen(listingId: listing.id))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AspectRatio(
          aspectRatio: 1,
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: studioBackdrop(radius: BorderRadius.circular(Brand.radius)),
            child: Stack(fit: StackFit.expand, children: [
              switch (cover) {
                null => const Icon(Icons.image_outlined, color: Colors.black26),
                // A shoe with a 3D turns under a sideways finger here too, as on its page.
                final cover when (listing.model?.turn.length ?? 0) >= CardTurn.minFrames =>
                  CardTurn(frames: listing.model!.turn, cover: _cover(cover)),
                final cover => _cover(cover),
              },
              // The shoe turns in 3D on its page: the card only says so.
              if (listing.model != null) const Positioned(left: 10, top: 10, child: IgnorePointer(child: Badge360())),
              if (listing.wasPriceTiyn != null)
                Positioned(right: 10, top: 10, child: IgnorePointer(child: SaleBadge(listing: listing))),
            ]),
          ),
        ),
        const SizedBox(height: 10),
        PriceLine(listing: listing, style: weight(theme.textTheme.titleMedium!, 750)),
        const SizedBox(height: 2),
        Text(listing.title,
            maxLines: titleLines(context), overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
        const SizedBox(height: 2),
        Text(label(conditions, listing.condition),
            maxLines: conditionLines(context),
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ]),
    );
  }
}

int salePercent(Listing l) => ((1 - l.priceTiyn / l.wasPriceTiyn!) * 100).round();

/// "−20%" on an accent pill, for listings whose price was really cut.
class SaleBadge extends StatelessWidget {
  const SaleBadge({super.key, required this.listing});
  final Listing listing;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(color: Brand.accentStrong, borderRadius: BorderRadius.circular(99)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          child: Text('−${salePercent(listing)}%',
              style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontVariations: [FontVariation('wght', 800)],
                  fontSize: 12)),
        ),
      );
}

/// The price, and during a sale the old one crossed out beside it.
class PriceLine extends StatelessWidget {
  const PriceLine({super.key, required this.listing, required this.style});
  final Listing listing;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final was = listing.wasPriceTiyn;
    // A price is never broken over lines: with large text in a narrow tile it shrinks to fit instead.
    return Wrap(crossAxisAlignment: WrapCrossAlignment.end, spacing: 8, children: [
      FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(formatTenge(listing.priceTiyn),
              style: was == null ? style : style.copyWith(color: accentText(context)))),
      if (was != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Text(formatTenge(was),
              key: const Key('was-price'),
              style: TextStyle(
                  fontSize: (style.fontSize ?? 16) * 0.7,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  decoration: TextDecoration.lineThrough)),
        ),
    ]);
  }
}

class Badge360 extends StatelessWidget {
  const Badge360({super.key, this.dark = false});
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final fg = dark ? Colors.white : Brand.ink;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: dark ? Colors.black.withValues(alpha: 0.55) : Colors.white.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.threesixty, size: 14, color: fg),
          const SizedBox(width: 4),
          Text('360°', style: weight(Theme.of(context).textTheme.labelSmall!, 700).copyWith(color: fg)),
        ]),
      ),
    );
  }
}

/// Height of the lines under a [ListingTile]'s photo at the current text size: price, the title's lines, condition.
double listingTileTextExtent(BuildContext context) {
  final t = Theme.of(context).textTheme;
  final scaler = MediaQuery.textScalerOf(context);
  double line(TextStyle? s, double size, double height) => scaler.scale(s?.fontSize ?? size) * (s?.height ?? height);
  final price = line(t.titleMedium, 16, 1.5);
  // With large text a sale price and the crossed-out one no longer fit side by side.
  final priceLines = scaler.scale(16) > 20 ? 2 : 1;
  return 10 +
      price * priceLines +
      2 +
      titleLines(context) * line(t.bodyMedium, 14, 1.43) +
      2 +
      conditionLines(context) * line(t.labelMedium, 12, 1.33) +
      4;
}

/// With large text a tile's title gets a third line: the colour, which tells pairs of one model apart, ends it.
int titleLines(BuildContext context) => MediaQuery.textScalerOf(context).scale(14) > 16 ? 3 : 2;

/// The condition under a tile's title takes a second line once text is set any larger, so «Киілген, өте жақсы» is read whole.
int conditionLines(BuildContext context) => MediaQuery.textScalerOf(context).scale(12) > 12.5 ? 2 : 1;

/// Listing tiles up to 240 wide, each row as tall as a square photo plus the lines under it at the current text
/// size, so large text never makes one tile run into the next (a fixed aspect ratio did).
class ListingGridDelegate extends SliverGridDelegate {
  const ListingGridDelegate({required this.textExtent, this.mainAxisSpacing = 22, this.crossAxisSpacing = 14});
  ListingGridDelegate.of(BuildContext context, {double mainAxisSpacing = 22})
      : this(textExtent: listingTileTextExtent(context), mainAxisSpacing: mainAxisSpacing);

  static const maxCrossAxisExtent = 240.0;
  final double textExtent;
  final double mainAxisSpacing;
  final double crossAxisSpacing;

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    final across = constraints.crossAxisExtent;
    final count = max(1, ((across + crossAxisSpacing) / (maxCrossAxisExtent + crossAxisSpacing)).ceil());
    final width = max(0.0, (across - crossAxisSpacing * (count - 1)) / count);
    return SliverGridRegularTileLayout(
      crossAxisCount: count,
      mainAxisStride: width + textExtent + mainAxisSpacing,
      crossAxisStride: width + crossAxisSpacing,
      childMainAxisExtent: width + textExtent,
      childCrossAxisExtent: width,
      reverseCrossAxis: axisDirectionIsReversed(constraints.crossAxisDirection),
    );
  }

  @override
  bool shouldRelayout(ListingGridDelegate oldDelegate) =>
      oldDelegate.textExtent != textExtent ||
      oldDelegate.mainAxisSpacing != mainAxisSpacing ||
      oldDelegate.crossAxisSpacing != crossAxisSpacing;
}

class ListingGrid extends StatelessWidget {
  const ListingGrid({super.key, required this.items, this.padding = const EdgeInsets.all(16)});
  final List<Listing> items;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: padding,
      gridDelegate: ListingGridDelegate.of(context, mainAxisSpacing: 20),
      itemCount: items.length,
      itemBuilder: (_, i) => ListingTile(listing: items[i]),
    );
  }
}

/// Asks before an action that cannot be taken back; true only when the person pressed [action].
Future<bool> confirmAction(BuildContext context,
    {required String title, required String action, bool destructive = false}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Болдырмау'))),
        FilledButton(
          key: const Key('confirm-action'),
          style: destructive ? FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error) : null,
          onPressed: () => Navigator.pop(context, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return ok == true;
}
