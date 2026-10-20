import 'package:flutter/material.dart';

import '../i18n.dart';
import '../session.dart';
import '../theme.dart';
import '../widgets/common.dart';

// The same clocks the server runs (backend/vitrina_api/services.py and config.py); change both together.
const payWithinMinutes = 30;
const sellerAnswersWithinHours = 48;
const buyerChecksWithinDays = 5;
const sellerShipsWithinDays = 5;

/// The one sentence about where the money waits, shown on the product page, the order and here.
/// A key for [tr]; said the same way everywhere so buyers and sellers read one rule.
const protectionText =
    'Ақшаңыз VITRINA-да сақталады. Сатушы оны сіз тауарды алғаныңызды растағанда не тексеру мерзімі өткенде ғана, комиссия шегерілген соң алады.';

/// Said instead while online payment is off (no payment partner yet): nothing is held, the two sides agree in the chat.
const directDealText =
    'Онлайн төлем әзірге қосылмаған: төлем мен жеткізуді сатушымен чатта келісесіз. Тауарды қолыңызға алғанда төлеген қауіпсіз.';

class _Topic {
  const _Topic(this.icon, this.title, this.body, {this.paid = false});
  final IconData icon;
  final String title;
  final String Function() body;
  // About money VITRINA holds and orders paid in the app: left out while online payment is off.
  final bool paid;
}

// While online payment is off, these come first.
final _directTopics = [
  _Topic(
      Icons.chat_bubble_outline_rounded,
      'Қазір қалай сатып аламын?',
      () => tr(
          'Онлайн төлем әзірге қосылмаған. Тауар бетінде «Сатушыға жазу» басып, өлшемді, бағаны, төлем мен жеткізуді чатта келісіңіз. VITRINA ақшаны ұстамайды және қайтара алмайды.')),
  _Topic(
      Icons.shield_outlined,
      'Алаяқтықтан қалай сақтанамын?',
      () => tr(
          'Тауарды көрмей тұрып толық аударым жасамаңыз: кездескенде не жеткізу қызметі арқылы алғанда төлеген қауіпсіз. Сатушының рейтингі мен пікірлерін, «Құжаты бар» белгісін қараңыз. Күмәнді болса, тауар бетінен шағым жіберіңіз.')),
];

final _topics = [
  _Topic(
      Icons.shield_outlined,
      'Ақшам қалай қорғалады?',
      () => trf(
          'Төлеген ақшаңыз сатушыға бірден өтпейді, VITRINA-да сақталады. Сатушы оны сіз «Алдым, бәрі дұрыс» батырмасын басқанда не тексерудің {0} күні өткенде ғана, комиссия шегерілген соң алады. Бір нәрсе дұрыс болмаса, ақша сізге қайтарылады.',
          [buyerChecksWithinDays]),
      paid: true),
  _Topic(
      Icons.schedule_rounded,
      'Тапсырыс қалай жүреді?',
      () => trf(
          'Тапсырыс жасаған соң {0} минут ішінде төлейсіз, әйтпесе ол жойылып, өлшем басқаларға ашылады. Сатушы {1} сағат ішінде қабылдап, {3} күн ішінде жіберуі керек, әйтпесе ақша өзі қайтарылады. Сәлемдеме қолыңызға тигенде «Тауарды алдым» басыңыз. Тексеруге {2} күн бар: растамасаңыз да, қайтару не дау ашпасаңыз, тапсырыс өзі аяқталып, ақша сатушыға өтеді.',
          [payWithinMinutes, sellerAnswersWithinHours, buyerChecksWithinDays, sellerShipsWithinDays]),
      paid: true),
  _Topic(
      Icons.straighten_rounded,
      'Өлшемі келмесе ше?',
      () => trf(
          'Жеткізілгеннен кейін {0} күн ішінде тапсырыс бетінде «Қайтару» батырмасын басып, себебін жазыңыз. Сатушы мақұлдаса, ақша қайтарылады. Сатушы келіспесе не жауап бермесе, қолдау қызметі шешеді. Келесі жолы қателеспеу үшін профильге табан ұзындығын сантиметрмен енгізіңіз.',
          [buyerChecksWithinDays]),
      paid: true),
  _Topic(
      Icons.report_gmailerrorred_rounded,
      'Тауар сипаттамаға сай болмаса?',
      () => tr(
          'Тапсырыс бетінде «Дау ашу» басып, себебін жазыңыз, фотосын сатушымен чатқа жіберіңіз. Дау шешілгенше ақша ешкімге өтпейді. Қолдау қызметі екі жақтың да түсіндірмесін және чатты қарап, шешім шығарады.'),
      paid: true),
  _Topic(
      Icons.verified_outlined,
      'Түпнұсқа екенін қалай білемін?',
      () => tr(
          '«Құжаты бар» не «Тексерілген» белгісі сатушы чек, қорап жапсырмасы не бирка жіберіп, оны VITRINA қызметкері қарағанын білдіреді. Белгі жоқ тауарда сатушының өз сөзі ғана бар. Күмәндансаңыз, сатып алмай тұрып чатта сұраңыз.')),
  _Topic(
      Icons.threesixty_rounded,
      '360° витрина деген не?',
      () => tr(
          'Сатушы аяқкиімді айналдыра отырып түсірген шын фотолар. Оларды саусақпен бұрап, тігісі мен табанына дейін көресіз. Жасанды интеллект аяқкиімнің пішіні мен түсін өзгертпейді, тек фонды тазартады.')),
  _Topic(
      Icons.chat_bubble_outline_rounded,
      'Неге чаттан шықпау керек?',
      () => tr(
          'Қорғау тек VITRINA ішінде төленген тапсырысқа жұмыс істейді. Сатушы басқа жерге аударым сұраса, бұл қауіп белгісі: келіспеңіз және тауар бетінен шағым жіберіңіз.'),
      paid: true),
];

/// How buying here works, in the buyer's words: the money, the clocks, returns, disputes and the badges.
class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context) => FutureBuilder<bool>(
      future: SessionScope.maybeOf(context)?.api.paymentsOn(),
      builder: (context, payments) => _build(context, payments.data ?? true));

  Widget _build(BuildContext context, bool payments) {
    final theme = Theme.of(context);
    final topics = payments ? _topics : [..._directTopics, ..._topics.where((t) => !t.paid)];
    return Scaffold(
      appBar: AppBar(title: Text(tr('Қалай жұмыс істейді'))),
      body: ListView(padding: contentPadding(context, const EdgeInsets.fromLTRB(16, 4, 16, 32)), children: [
        for (final (i, t) in topics.indexed)
          Card(
            margin: const EdgeInsets.only(bottom: 10),
            clipBehavior: Clip.antiAlias,
            child: ExpansionTile(
              key: Key('help-$i'),
              initiallyExpanded: i == 0,
              shape: const Border(),
              leading: Icon(t.icon, color: Brand.accent),
              title: Text(tr(t.title), style: weight(theme.textTheme.titleSmall!, 650)),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              children: [Text(t.body(), style: theme.textTheme.bodyMedium?.copyWith(height: 1.45))],
            ),
          ),
        const SizedBox(height: 8),
        Text(
          tr('Бұл ережелер алдын ала нұсқа: төлем серіктесі қосылып, заңгер тексергеннен кейін нақтыланады.'),
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ]),
    );
  }
}
