import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vitrina/color_guess.dart';
import 'package:vitrina/colors.dart';
import 'package:vitrina/en.dart';
import 'package:vitrina/ru.dart';

/// A 96 px picture: [background] all over, with the shoe drawn on it by [shoe] (null where there is none).
Uint8List picture(List<int> background, List<int>? Function(int x, int y) shoe, {int w = 96, int h = 96}) {
  final out = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final c = shoe(x, y) ?? background;
      out.setAll((y * w + x) * 4, [...c.take(3), c.length > 3 ? c[3] : 255]);
    }
  }
  return out;
}

/// The shoe as a block in the middle, [sole] the lowest part of it.
List<int>? Function(int, int) block(List<int> upper, {List<int>? sole, double soleShare = 0, int size = 60}) {
  final from = (96 - size) ~/ 2;
  return (x, y) {
    if (x < from || x >= from + size || y < from || y >= from + size) return null;
    return sole != null && y >= from + size * (1 - soleShare) ? sole : upper;
  };
}

void main() {
  const paper = [246, 244, 238];
  const white = [250, 250, 250];

  test('one colour over most of the shoe is named by the nearest listed colour', () {
    String? on(List<int> c, [List<int> bg = paper]) => guessFromPixels(picture(bg, block(c)), 96, 96);
    expect(on([47, 111, 214]), 'көк');
    expect(on([60, 120, 200]), 'көк'); // a lighter blue in daylight is still blue, not light blue
    expect(on([142, 201, 240]), 'көгілдір');
    expect(on([31, 42, 85]), 'қою көк');
    expect(on([210, 59, 59]), 'қызыл');
    expect(on([123, 30, 51]), 'бордо');
    expect(on([242, 167, 192]), 'қызғылт');
    expect(on([214, 178, 178]), 'қызғылт'); // a dusty pale pink, not red
    expect(on([62, 142, 90]), 'жасыл');
    expect(on([109, 76, 61]), 'қоңыр');
    expect(on([242, 207, 59]), 'сары');
    expect(on([126, 87, 194]), 'күлгін');
    expect(on([62, 142, 90], [30, 30, 30]), 'жасыл'); // on a dark floor too
  });

  test('a shoe of no particular hue is black, grey, silver or white by how light it is', () {
    String? on(List<int> c, [List<int> bg = paper]) => guessFromPixels(picture(bg, block(c)), 96, 96);
    expect(on([27, 27, 31]), 'қара');
    expect(on([128, 128, 132]), 'сұр');
    expect(on([150, 150, 154]), 'сұр');
    expect(on([200, 200, 204]), 'ақ'); // a white shoe in room light; silver is a shine, never guessed
    expect(on([252, 252, 252], [120, 120, 120]), 'ақ'); // a white shoe on a grey floor
  });

  test('a black upper on a white sole is a black shoe; half and half is black-and-white', () {
    expect(guessFromPixels(picture(paper, block([27, 27, 31], sole: white, soleShare: 0.3)), 96, 96), 'қара');
    expect(
        guessFromPixels(picture([120, 160, 120], block([27, 27, 31], sole: white, soleShare: 0.5)), 96, 96), 'қара-ақ');
  });

  test('a many-coloured pair gets no guess, rather than one named by its few plain parts', () {
    final mixed = picture(paper, (x, y) {
      if (x < 18 || x >= 78 || y < 18 || y >= 78) return null;
      if (y >= 72) return white; // the sole
      return [
        [210, 59, 59],
        [47, 111, 214],
        [62, 142, 90]
      ][(x - 18) ~/ 20];
    });
    expect(guessFromPixels(mixed, 96, 96), isNull);
  });

  test('a see-through background is left out: the shoe alone decides', () {
    expect(guessFromPixels(picture([0, 0, 0, 0], block([47, 111, 214])), 96, 96), 'көк');
  });

  test('no guess when there is hardly any shoe, or no picture at all', () {
    expect(guessFromPixels(picture(paper, block([47, 111, 214], size: 10)), 96, 96), isNull);
    expect(guessFromPixels(picture(paper, (_, __) => null), 96, 96), isNull);
    expect(guessFromPixels(Uint8List(0), 0, 0), isNull);
    expect(guessFromPixels(Uint8List(10), 96, 96), isNull); // fewer bytes than the size says
  });

  test('every guess can be asked: each listed colour has its question, translated', () {
    expect(colorQuestions.keys.toSet(), shoeColors.keys.toSet());
    for (final q in [...colorQuestions.values, 'Иә', 'Жоқ, басқа түс']) {
      expect(en[q], isNotNull, reason: q);
      expect(ru[q], isNotNull, reason: q);
    }
  });

  testWidgets('real photos: black, blue and pink pairs are named so, a broken file gives no guess', (tester) async {
    Future<String?> guess(String name) => guessShoeColor(File('demo/media/1/$name.jpg').readAsBytesSync());
    final got = await tester.runAsync(() async => [
          await guess('016661e935234c30b8b0b3632783adde'),
          await guess('05ec87c0b020cff8c3d86738b0b7edb6'),
          await guess('07992a536638a99986f39bb59fc48ba8'),
          await guess('1d907ad5338200725ab54b7125736f09'),
          await guess('1b3b2efb9ca638b707837c452fa6cc1f'),
          await guess('21683f814d6aac24549a93afa3a7d387'),
          await guessShoeColor(Uint8List.fromList('jpeg bytes'.codeUnits)),
        ]);
    expect(got, ['қара', 'қара', 'көк', 'көк', 'қызғылт', 'қызғылт', null]);
  });

  group('the colour question', () {
    final form = GlobalKey<FormState>();
    var answers = 0;

    /// The field on a form, as the editor has it; [guess] can arrive later, by pumping again with [later].
    Future<TextEditingController> field(WidgetTester tester,
        {String text = '', String? guess = 'көк', TextEditingController? keep, Key? key}) async {
      final c = keep ?? TextEditingController(text: text);
      if (keep == null) addTearDown(c.dispose);
      answers = 0;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Form(
                  key: form,
                  child: ListView(children: [
                    ColorField(key: key ?? UniqueKey(), controller: c, guess: guess, onAnswered: () => answers++)
                  ])))));
      return c;
    }

    testWidgets('one tap on Иә sets the colour from the photo', (tester) async {
      final semantics = tester.ensureSemantics();
      final c = await field(tester);
      expect(find.text('Көк пе?'), findsOneWidget);
      expect(find.byKey(const Key('color-көк')), findsNothing); // one question, not the whole list
      expect(tester.getSize(find.byKey(const Key('color-yes'))).height, greaterThanOrEqualTo(48));
      expect(find.bySemanticsLabel('Иә, көк'), findsOneWidget); // heard with the colour it sets
      await tester.tap(find.byKey(const Key('color-yes')));
      await tester.pump();
      expect(c.text, 'көк');
      expect(answers, 1);
      expect(find.byKey(const Key('color-guess')), findsNothing);
      expect(find.descendant(of: find.byKey(const Key('color-picked')), matching: find.text('көк')), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('no: the whole list, and the question is not asked again', (tester) async {
      final c = await field(tester);
      await tester.tap(find.byKey(const Key('color-no')));
      await tester.pump();
      expect(answers, 1);
      expect(find.byKey(const Key('color-guess')), findsNothing);
      await tester.tap(find.byKey(const Key('color-қызыл')));
      await tester.pump();
      expect(c.text, 'қызыл');
      await tester.tap(find.byKey(const Key('color-change')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('color-other')));
      await tester.pump();
      expect(c.text, ''); // nothing typed yet: the colour is empty again, and still not asked
      expect(find.byKey(const Key('color-guess')), findsNothing);
      expect(find.byKey(const Key('color-other-text')), findsOneWidget);
    });

    testWidgets('unanswered, the form does not go on', (tester) async {
      await field(tester, text: 'ақ');
      expect(form.currentState!.validate(), isFalse); // a copied colour is never saved unseen
      await tester.pump();
      expect(find.text('Түсін таңдаңыз'), findsOneWidget);
      await tester.tap(find.byKey(const Key('color-no')));
      await tester.pump();
      expect(form.currentState!.validate(), isTrue);
    });

    testWidgets('a colour already set: no opens the list with it picked; the same colour is not asked about',
        (tester) async {
      final c = await field(tester, text: 'ақ');
      expect(find.text('Көк пе?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('color-no')));
      await tester.pump();
      expect(c.text, 'ақ');
      expect(tester.widget<ChoiceChip>(find.byKey(const Key('color-ақ'))).selected, isTrue);
      expect(find.byKey(const Key('color-көк')), findsOneWidget);

      await field(tester, text: 'көк');
      expect(find.byKey(const Key('color-guess')), findsNothing); // the photo agrees: nothing to ask
    });

    testWidgets('a guess arriving once the list shows is not asked: a tap meant for a colour stays one',
        (tester) async {
      const key = Key('field');
      final c = await field(tester, guess: null, key: key);
      await field(tester, keep: c, key: key); // the same field, the guess now there
      expect(find.byKey(const Key('color-guess')), findsNothing);
      expect(find.byKey(const Key('color-көк')), findsOneWidget);
    });

    testWidgets('without a guess the list shows as before', (tester) async {
      await field(tester, guess: null);
      expect(find.byKey(const Key('color-guess')), findsNothing);
      expect(find.byKey(const Key('color-көк')), findsOneWidget);
    });
  });
}
