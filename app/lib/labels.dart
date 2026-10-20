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
