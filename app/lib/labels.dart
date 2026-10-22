/// Display text in Kazakh for the API's codes, and money formatting.
library;

import 'i18n.dart';

/// 1 250 000 tiyn -> "12 500 ₸". Amounts stay integers end to end.
/// A calendar day as 24.10, the way people write it in Kazakhstan.
String formatDay(DateTime d) => '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}';

String formatTenge(int tiyn) {
  final tenge = tiyn ~/ 100;
  final rest = tiyn % 100;
  final digits = tenge.toString();
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(' ');
    buf.write(digits[i]);
  }
  if (rest != 0) buf.write(',${rest.toString().padLeft(2, '0')}');
  return '$buf ₸';
}

const categories = {
  'sneakers': 'Кроссовкалар',
  'sport': 'Спорт',
  'casual': 'Күнделікті',
  'classic': 'Туфли, классика',
  'heels': 'Өкшелі аяқкиім',
  'boots': 'Етік, бәтеңке',
  'boots_winter': 'Қысқы етік',
  'sandals': 'Сандалдар',
  'slippers': 'Тәпішке, үй аяқкиімі',
  'work': 'Жұмыс, арнайы аяқкиім',
  'kids': 'Балалар',
  'other': 'Басқа',
};

/// Whom a pair is made for. A unisex pair is shown to men and to women alike.
const audiences = {
  'men': 'Ерлерге',
  'women': 'Әйелдерге',
  'unisex': 'Ерлерге де, әйелдерге де',
  'kids': 'Балаларға',
};

/// The facts a seller picks for a pair from ready options, never types (backend vitrina_core/facts.py, which keeps
/// the same Kazakh names for staff): what it is made of, its season and country, and for some kinds of footwear one or
/// two more. Each with its name.
const factNames = {
  'upper': 'Үсті',
  'lining': 'Іші',
  'sole': 'Табаны',
  'season': 'Маусым',
  'country': 'Елі',
  'shaft': 'Қонышы',
  'warmth': 'Жылуы',
  'heel': 'Өкше',
  'fastening': 'Бекітпесі',
};

const factOptions = <String, Map<String, String>>{
  'upper': {
    'leather': 'Табиғи былғары',
    'faux_leather': 'Жасанды былғары',
    'suede': 'Күдері',
    'nubuck': 'Нубук',
    'patent': 'Лак былғары',
    'textile': 'Тоқыма',
    'mesh': 'Желдетілетін тор',
    'mixed': 'Аралас материал',
    'rubber': 'Резеңке',
    'eva': 'Жеңіл көбік (EVA)',
    'felt': 'Киіз',
  },
  'lining': {
    'leather': 'Табиғи былғары',
    'textile': 'Тоқыма',
    'fur': 'Табиғи мех',
    'faux_fur': 'Жасанды мех',
    'wool': 'Жүн',
    'felt': 'Киіз',
    'none': 'Астары жоқ',
  },
  'sole': {
    'rubber': 'Резеңке',
    'eva': 'Жеңіл көбік (EVA)',
    'pu': 'Полиуретан',
    'tpr': 'Термопластик (TPR)',
    'leather': 'Былғары',
  },
  'season': {
    'summer': 'Жаз',
    'demi': 'Көктем-күз',
    'winter': 'Қыс',
    'all': 'Жыл бойы',
  },
  'country': {
    'KZ': 'Қазақстан',
    'TR': 'Түркия',
    'CN': 'Қытай',
    'RU': 'Ресей',
    'KG': 'Қырғызстан',
    'UZ': 'Өзбекстан',
    'BY': 'Беларусь',
    'VN': 'Вьетнам',
    'IN': 'Үндістан',
    'ID': 'Индонезия',
    'IT': 'Италия',
  },
  'shaft': {
    'ankle': 'Тобыққа дейін',
    'mid_calf': 'Балтырдың ортасына дейін',
    'knee': 'Тізеге дейін',
    'over_knee': 'Тізеден жоғары',
  },
  'warmth': {
    'none': 'Жылусыз',
    'light': 'Аздап жылы',
    'winter': 'Қысқы',
  },
  'heel': {
    'flat': 'Өкшесіз',
    'low': 'Аласа (3 см-ге дейін)',
    'mid': 'Орташа (3–7 см)',
    'high': 'Биік (7 см-ден жоғары)',
  },
  'fastening': {
    'buckle': 'Тоға',
    'velcro': 'Жабысқақ (липучка)',
    'elastic': 'Резеңке бау',
    'laces': 'Бау',
    'none': 'Бекітпесіз',
  },
};

/// Every pair has these; the kind of footwear adds its own (a winter boot is warm by its kind: no warmth to ask).
const commonFacts = ['upper', 'lining', 'sole', 'season', 'country'];
const factsByCategory = {
  'boots': ['shaft', 'warmth'],
  'boots_winter': ['shaft'],
  'classic': ['heel'],
  'heels': ['heel'],
  'sandals': ['fastening'],
  'kids': ['warmth', 'fastening'],
};

/// The facts asked for this kind of footwear, in the order a buyer reads them.
List<String> factKeys(String? category) => [...commonFacts, ...?factsByCategory[category]];

/// The facts as they would be saved for this kind of footwear: those it has, and any this app does not know (a newer
/// server's, kept for the server to judge, never dropped unseen).
Map<String, String> factsFor(String? category, Map<String, String> facts) => {
      for (final MapEntry(:key, :value) in facts.entries)
        if (factKeys(category).contains(key) || !factOptions.containsKey(key)) key: value
    };

/// A picked fact in the interface language, or null for one not known to this app (a newer server's).
String? factText(String key, String option) => switch (factOptions[key]?[option]) {
      final text? => tr(text),
      null => null,
    };

// Segment, condition and authenticity are separate facts; the UI never merges them into one "quality" badge.
const segments = {
  'economy': 'Эконом',
  'mid': 'Орта',
  'premium': 'Премиум',
  'luxury': 'Люкс',
};

const conditions = {
  'new_with_box': 'Жаңа, қорабымен',
  'new_no_box': 'Жаңа, қорабсыз',
  'unworn_stored': 'Киілмеген, сақталған',
  'used_excellent': 'Киілген, өте жақсы',
  'used_good': 'Киілген, жақсы',
  'defective': 'Ақауы бар',
};

const authenticity = {
  'unverified': 'Тексерілмеген',
  'seller_evidence': 'Сатушы дәлел берді',
  'documented': 'Құжаты бар',
  'verified': 'Тексерілген',
};

const orderStatuses = {
  'CREATED': 'Жасалды',
  'PAYMENT_PENDING': 'Төлем күтілуде',
  'PAID': 'Төленді, ақша қорғауда',
  'SELLER_ACCEPTED': 'Сатушы қабылдады',
  'PREPARING': 'Дайындалуда',
  'SHIPPED': 'Жіберілді',
  'IN_TRANSIT': 'Жолда',
  'DELIVERED_PENDING_CONFIRMATION': 'Жеткізілді, растауыңызды күтеді',
  'COMPLETED': 'Аяқталды',
  'DISPUTED': 'Дау ашылды',
  'RETURN_REQUESTED': 'Қайтару сұралды',
  'REFUND_PENDING': 'Ақша қайтарылуда',
  'REFUNDED': 'Ақша қайтарылды',
  'CANCELLED': 'Бас тартылды',
};

String label(Map<String, String> table, String? code) => code == null ? '—' : tr(table[code] ?? code);

/// How a size felt, as a buyer picks it in a review.
const fits = {'small': 'Кішілеу', 'true': 'Өлшеміне сай', 'large': 'Үлкендеу'};
