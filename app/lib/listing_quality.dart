/// How complete a listing's page is, scored from what the seller filled in, with the next things to add.
/// Nothing here is a guess about sales: each tip names a gap a buyer would otherwise ask about in the chat.
library;

import 'dart:math' as math;

import 'api.dart';
import 'i18n.dart';
import 'screens/listing_editor_screen.dart' show optionalAngles, requiredAngles;

/// Below this many frames the 360° viewer has nothing to turn (the server asks for at least 8).
const min360Frames = 8;

class QualityTip {
  const QualityTip(this.points, this.text);
  final int points;
  final String text;
}

class ListingQuality {
  const ListingQuality(this.score, this.tips);

  /// 0–100.
  final int score;

  /// Biggest gain first.
  final List<QualityTip> tips;

  String get verdict => score >= 85
      ? tr('Өте жақсы')
      : score >= 60
          ? tr('Жақсы')
          : tr('Толықтыруға болады');
}

ListingQuality listingQuality(Listing l) {
  final tips = <QualityTip>[];
  // A scan's top and sole photos are frames of the turn too: told about once, above.
  final frameUrls = {for (final f in l.frames) f.originalUrl};
  final noShoe = [
    for (final m in l.photos)
      if (m.noShoe && !frameUrls.contains(m.originalUrl))
        tr(requiredAngles[m.angle] ?? optionalAngles[m.angle] ?? m.angle)
  ];
  if (noShoe.isNotEmpty) {
    tips.add(QualityTip(
        5,
        trf('Мына фотоларды қайта түсіріңіз: {0}. Оларда аяқкиім табылмады, сондықтан фоны алынбайды. Аяқкиімнен ерекшеленетін біркелкі фонда түсіріңіз.',
            [noShoe.join(', ')])));
  }
  final angles = {for (final m in l.photos) m.angle};
  final extra = ['sole', 'top', 'detail', 'label'].where((a) => !angles.contains(a)).length;
  if (extra > 0) {
    tips.add(QualityTip((15 * extra / 4).round(),
        tr('Табанын, үстінен, жақыннан (тігіс, логотип) және өлшем жапсырмасын түсіріңіз: тозуы, сапасы мен өлшемі көрінеді.')));
  }
  if ((l.description ?? '').trim().length < 80) {
    tips.add(QualityTip(15, tr('Сипаттамаға 2–3 сөйлем жазыңыз: материалы, қалай отырады, неге сатылады.')));
  }
  if ((l.brand ?? '').trim().isEmpty) {
    tips.add(QualityTip(10, tr('Брендін көрсетіңіз: іздеуде сол бойынша табылады.')));
  }
  if ((l.modelName ?? '').trim().isEmpty) {
    tips.add(QualityTip(5, tr('Модель атауын жазыңыз: нақты модельді іздейтіндер табады.')));
  }
  if (l.authenticity != 'documented' && l.authenticity != 'verified') {
    tips.add(QualityTip(15, tr('Түпнұсқалығын дәлелдеңіз: чек, қорап жапсырмасы не бирка фотосы.')));
  }
  final worn = l.condition.startsWith('used') || l.condition == 'defective';
  if (worn && (l.defects ?? '').trim().isEmpty) {
    tips.add(QualityTip(10, tr('Киілгенін не ақауын сипаттаңыз: сұрақ азаяды, қайтару сирейді.')));
  }
  if (!l.sizes.any((s) => s.available)) {
    tips.add(QualityTip(5, tr('Қалдықты жаңартыңыз: қазір сатылымда бірде-бір өлшем жоқ.')));
  }
  tips.sort((a, b) => b.points.compareTo(a.points));
  return ListingQuality(math.max(0, 100 - tips.fold(0, (sum, t) => sum + t.points)), tips);
}
