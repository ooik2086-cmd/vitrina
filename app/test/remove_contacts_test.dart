import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vitrina/api.dart';
import 'package:vitrina/i18n.dart';
import 'package:vitrina/widgets/common.dart';

ApiException refusal(String? detail) =>
    ApiException(422, 'contacts_not_allowed', 'Телефон, сілтеме, почта, @атау не мессенджер жазуға болмайды.', detail);

void main() {
  test('a refusal names its pieces; another error or none name nothing', () {
    expect(refusedContacts(refusal('WhatsApp: +7 701 555 12 34», «qadam@mail.ru')),
        ['WhatsApp: +7 701 555 12 34', 'qadam@mail.ru']);
    expect(refusedContacts(refusal(null)), isEmpty);
    expect(refusedContacts(ApiException(422, 'validation', 'Қате.', 'title is too short')), isEmpty);
    expect(refusedContacts(Exception('offline')), isEmpty);
  });

  test('one tap is offered only when every named piece stands whole in the words', () {
    expect(removableContacts(refusal('WhatsApp: +7 701 555 12 34'), 'Иә.\nWhatsApp:  +7 701\n555 12 34'),
        ['WhatsApp: +7 701 555 12 34'],
        reason: 'spaces and line breaks stand for a space');
    expect(removableContacts(refusal('https://aaaaaaaa…'), 'https://aaaaaaaaaaaa'), isEmpty, reason: 'cut short');
    expect(removableContacts(refusal('WhatsApp», «Instagram'), 'WhatsApp, Insta'), isEmpty, reason: 'one is missing');
    expect(removableContacts(refusal('WhatsApp'), 'Whatsapp'), isEmpty, reason: 'not as written');
    expect(removableContacts(refusal('ватсап'), 'ватсапқа'), isEmpty, reason: 'part of a word');
    expect(removableContacts(refusal('Insta'), 'MyInsta'), isEmpty, reason: 'the end of a word');
  });

  test('taking the pieces out changes only where they stood', () {
    final cases = {
      ('Иә, бар. WhatsApp: +7 701 555 12 34', ['WhatsApp: +7 701 555 12 34']): 'Иә, бар.',
      ('Жазыңыз: qadam@mail.ru. Қайтару 3 күн.', ['qadam@mail.ru']): 'Жазыңыз. Қайтару 3 күн.',
      ('Instagram, qadam@mail.ru, сурет көп', ['Instagram', 'qadam@mail.ru']): 'сурет көп',
      ('Иә, бар (8 701 123 45 67)', ['8 701 123 45 67']): 'Иә, бар',
      ('Жеткізу 1-3 күн\nTelegram: qadam', ['Telegram: qadam']): 'Жеткізу 1-3 күн',
      ('Жұмыс уақыты:\n9:00-18:00 , әр күні\n\nInstagram', ['Instagram']): 'Жұмыс уақыты:\n9:00-18:00 , әр күні',
      ('Иә\nInstagram\nҚайтару бар', ['Instagram']): 'Иә\nҚайтару бар',
      ('qadam@mail.ru не qadam', ['qadam', 'qadam@mail.ru']): 'не',
      ('Жазыңыз «WhatsApp» арқылы', ['WhatsApp']): 'Жазыңыз арқылы',
      ('WhatsApp:\n+7 701 555 12 34\nҚайтару бар', ['WhatsApp: +7 701 555 12 34']): 'Қайтару бар',
    };
    for (final MapEntry(key: (text, pieces), value: want) in cases.entries) {
      expect(withoutPieces(text, pieces), want, reason: text);
    }
  });

  test('under the field: only the line naming the pieces while one tap can take them out, else the whole refusal', () {
    final error = refusal('WhatsApp');
    expect(refusalText(error, 'Иә. WhatsApp'), 'Мынаны алып тастаңыз: «WhatsApp»');
    expect(refusalText(error, 'Иә. Whatsapp'),
        'Мынаны алып тастаңыз: «WhatsApp»\nТелефон, сілтеме, почта, @атау не мессенджер жазуға болмайды.');
    final split = refusal('WhatsApp: +7 701 555 12 34');
    expect(refusalText(split, 'WhatsApp:\n+7 701 555 12 34'), 'Мынаны алып тастаңыз: «WhatsApp: +7 701 555 12 34»',
        reason: 'a piece written over two lines is named whole');
    expect(refusalText(Exception('offline'), 'Иә'), 'Бір нәрсе дұрыс болмады. Қайта көріңіз.');
  });

  test('in English the pieces are quoted the English way', () {
    addTearDown(() => appLanguage.value = 'kk');
    appLanguage.value = 'en';
    expect(refusal('WhatsApp», «qadam@mail.ru').foundLine, isNot(contains('», «')));
    expect(refusal('WhatsApp», «qadam@mail.ru').foundLine, contains('WhatsApp”, “qadam@mail.ru'));
  });

  Future<List<bool>> tapOn(WidgetTester tester, String text, String found, {bool showRule = false}) async {
    final controller = TextEditingController(text: text);
    addTearDown(controller.dispose);
    final heard = <bool>[];
    Object? error = refusal(found);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: StatefulBuilder(
                builder: (context, setState) => Column(children: [
                      Text(controller.text, key: const Key('words')),
                      RemoveContactsButton(
                          error: error,
                          controller: controller,
                          showRule: showRule,
                          onRemoved: (clean) => setState(() {
                                heard.add(clean);
                                error = clean ? null : moreContacts();
                              })),
                    ])))));
    return heard;
  }

  testWidgets('one tap takes the pieces out of the field and nothing is sent', (tester) async {
    final heard = await tapOn(tester, 'Иә, бар. WhatsApp: +7 701 555 12 34', 'WhatsApp: +7 701 555 12 34');
    final button = find.byKey(const Key('remove-contacts'));
    expect(button, findsOneWidget);
    expect(find.byKey(const Key('remove-contacts-rule')), findsNothing);
    expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
    await tester.tap(button);
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const Key('words'))).data, 'Иә, бар.');
    expect(heard, [true]);
    expect(button, findsNothing, reason: 'the refusal is answered');
  });

  testWidgets('a contact the server did not name is caught after the tap', (tester) async {
    final heard = await tapOn(
        tester, 'WhatsApp, Instagram, qadam@mail.ru, 8 701 123 45 67 бар', 'WhatsApp», «Instagram», «qadam@mail.ru');
    await tester.tap(find.byKey(const Key('remove-contacts')));
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const Key('words'))).data, '8 701 123 45 67 бар');
    expect(heard, [false], reason: 'the fourth contact is still there');
    expect(find.byKey(const Key('remove-contacts')), findsNothing);
  });

  testWidgets('the rule is said under the button where asked', (tester) async {
    await tapOn(tester, 'Instagram-да бармыз', 'Instagram-да', showRule: true);
    expect(find.text('Телефон, сілтеме, почта, @атау не мессенджер жазуға болмайды.'), findsOneWidget);
  });

  testWidgets('no button when the words no longer hold what was found', (tester) async {
    await tapOn(tester, 'Иә, бар.', 'WhatsApp');
    expect(find.byKey(const Key('remove-contacts')), findsNothing);
  });
}
