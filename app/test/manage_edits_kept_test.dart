// A seller changing their listing loses nothing when the app is closed before Save: the changes are kept on the
// phone and put back next time, but only on what the seller saw, never over a value changed meanwhile.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vitrina/api.dart';
import 'package:vitrina/screens/manage_listing_screen.dart';
import 'package:vitrina/session.dart';

Map<String, dynamic> _listing(
        {int id = 7,
        int price = 4500000,
        int count42 = 2,
        String status = 'published',
        String? audience = 'unisex',
        Map<String, String> facts = const {},
        bool everOnSale = true}) =>
    {
      'id': id,
      'status': status,
      'title': 'Nike Air Force 1',
      'category': 'sneakers',
      'audience': audience,
      'facts': facts,
      'brand': 'Nike',
      'model_name': 'AF1',
      'color': 'ақ',
      'price_tiyn': price,
      'delivery_price_tiyn': 150000,
      'condition': 'used_good',
      'authenticity': 'unverified',
      'ever_on_sale': everOnSale,
      'showcase_style': 'clean',
      'description': 'Таза',
      'sizes': [
        {'id': 1, 'label': '42', 'insole_cm': '27,0', 'available': count42 > 0, 'quantity': count42},
        {'id': 2, 'label': '43', 'insole_cm': '27,5', 'available': true, 'quantity': 1},
      ],
      'media': [],
      'seller': {'id': 3, 'shop_name': 'Qadam Store', 'city': 'Алматы'},
    };

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

/// What the phone keeps for listing [id], if anything.
Future<Map<String, dynamic>?> _kept(WidgetTester tester, [int id = 7]) async {
  final prefs = (await tester.runAsync(SharedPreferences.getInstance))!;
  final raw = prefs.getString(Session.listingEditsKey);
  return raw == null ? null : (jsonDecode(raw) as Map<String, dynamic>)['$id'] as Map<String, dynamic>?;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// Opens the manage page for [listing], as [me], over another page. Saves go into [sent].
  Future<List<Map<String, dynamic>>> open(WidgetTester tester, Map<String, dynamic> listing, {int? me = 3}) async {
    final sent = <Map<String, dynamic>>[];
    var now = listing;
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          if (req.method == 'GET') return http.Response('{}', 404);
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          sent.add(body);
          now = {
            ...now,
            if (body['price_tiyn'] != null) 'price_tiyn': body['price_tiyn'],
            if (body['description'] != null) 'description': body['description'],
          };
          return _json(now);
        }));
    final session = Session(api)
      ..me = me == null ? null : Me.fromJson({'id': me, 'phone': '+77010000000', 'is_seller': true});
    tester.view.physicalSize = const Size(400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const SizedBox()); // a page opened before is gone, as after a restart
    await tester.pumpWidget(SessionScope(
        session: session,
        child: MaterialApp(
            home: Scaffold(
                body: Builder(
                    builder: (context) => TextButton(
                        onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => ManageListingScreen(listing: Listing.fromJson(listing)))),
                        child: const Text('open')))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20))); // the kept changes are read
    await tester.pumpAndSettle();
    return sent;
  }

  /// The app goes to the background, where Android may close it.
  Future<void> background(WidgetTester tester) async {
    for (final state in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    for (final state in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump();
  }

  Future<void> more(WidgetTester tester, int size) async {
    await tester.ensureVisible(find.byTooltip('Көбейту').at(size));
    await tester.tap(find.byTooltip('Көбейту').at(size));
    await tester.pump();
  }

  Finder field(String text) => find.widgetWithText(TextFormField, text);

  testWidgets('changes not saved come back after the app was closed, and go once saved', (tester) async {
    await open(tester, _listing());
    expect(find.byKey(const Key('edits-back')), findsNothing);
    await tester.enterText(find.byKey(const Key('price')), '40000');
    await tester.enterText(find.widgetWithText(TextFormField, 'Таза'), 'Таза, қорабымен');
    await more(tester, 0);
    await background(tester);
    expect((await _kept(tester))!['texts'], containsPair('price', ['40000', '45000']));

    final sent = await open(tester, _listing()); // the app opened again
    expect(find.byKey(const Key('edits-back')), findsOneWidget);
    expect(field('40000'), findsOneWidget);
    expect(field('Таза, қорабымен'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    await tester.tap(find.byKey(const Key('save')));
    await tester.pumpAndSettle();
    expect(sent.single['price_tiyn'], 4000000);
    expect(sent.single['description'], 'Таза, қорабымен');
    expect(sent.single['sizes'], [
      {'id': 1, 'quantity': 3, 'was': 2}
    ]);
    expect(find.byKey(const Key('edits-back')), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    expect(await _kept(tester), isNull);
  });

  testWidgets('a change is kept a moment after it is made, without the app going away', (tester) async {
    await open(tester, _listing());
    await tester.enterText(find.byKey(const Key('price')), '40000');
    await tester.pump(const Duration(seconds: 2));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    expect((await _kept(tester))!['texts'], {
      'price': ['40000', '45000']
    });
  });

  testWidgets('a value changed meanwhile is left as the server has it; the rest comes back', (tester) async {
    await open(tester, _listing());
    await tester.enterText(find.byKey(const Key('price')), '40000');
    await tester.enterText(find.widgetWithText(TextFormField, 'Таза'), 'Жаңа сипаттама');
    await more(tester, 0); // 42: 2 -> 3
    await more(tester, 1); // 43: 1 -> 2
    await background(tester);

    // Meanwhile the price was changed on another phone, and a pair of 42 was sold.
    await open(tester, _listing(price: 4200000, count42: 1));
    expect(find.byKey(const Key('edits-back')), findsOneWidget);
    expect(field('42000'), findsOneWidget);
    expect(field('Жаңа сипаттама'), findsOneWidget);
    expect(find.text('1'), findsOneWidget); // 42 as the server has it, after the sale
    expect(find.text('2'), findsOneWidget); // 43 as the seller set it
  });

  testWidgets('the seller can start from what is saved instead', (tester) async {
    await open(tester, _listing());
    await tester.enterText(find.byKey(const Key('price')), '40000');
    await more(tester, 0);
    await background(tester);
    await open(tester, _listing());
    await tester.tap(find.byKey(const Key('drop-edits')));
    await tester.pumpAndSettle();
    expect(find.text('Өзгерістерді алып тастау керек пе?'), findsOneWidget); // asked first: one tap loses nothing
    await tester.tap(find.text('Қалу'));
    await tester.pumpAndSettle();
    expect(field('40000'), findsOneWidget);
    await tester.tap(find.byKey(const Key('drop-edits')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('drop-edits-sure')));
    await tester.pumpAndSettle();
    expect(find.text('Өзгерістер алып тасталды.'), findsOneWidget);
    expect(field('45000'), findsOneWidget);
    expect(find.text('2'), findsOneWidget); // the 42s back at the saved count
    expect(find.text('3'), findsNothing);
    expect(find.byKey(const Key('edits-back')), findsNothing);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    expect(await _kept(tester), isNull);
    await tester.pageBack(); // nothing to ask about any more
    await tester.pumpAndSettle();
    expect(find.byType(ManageListingScreen), findsNothing);
  });

  testWidgets('leaving without the changes on purpose does not offer them again', (tester) async {
    await open(tester, _listing());
    await tester.enterText(find.byKey(const Key('price')), '40000');
    await tester.pump(const Duration(seconds: 2));
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('discard')));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    expect(await _kept(tester), isNull);
    await open(tester, _listing());
    expect(find.byKey(const Key('edits-back')), findsNothing);
    expect(field('45000'), findsOneWidget);
  });

  testWidgets("another person's changes on a shared phone are not shown, and go", (tester) async {
    await open(tester, _listing());
    await tester.enterText(find.byKey(const Key('price')), '40000');
    await background(tester);
    await open(tester, _listing(), me: 9);
    expect(find.byKey(const Key('edits-back')), findsNothing);
    expect(field('45000'), findsOneWidget);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    expect(await _kept(tester), isNull);
  });

  testWidgets('changes kept long ago are stale and dropped', (tester) async {
    final old = DateTime.now().subtract(const Duration(days: 15)).millisecondsSinceEpoch;
    SharedPreferences.setMockInitialValues({
      Session.listingEditsKey: jsonEncode({
        '7': {
          'owner': 3,
          'kept_at': old,
          'texts': {
            'price': ['40000', '45000']
          },
          'choices': {},
          'stock': {},
        }
      })
    });
    await open(tester, _listing());
    expect(field('45000'), findsOneWidget);
    expect(find.byKey(const Key('edits-back')), findsNothing);
  });

  testWidgets('each listing keeps its own changes', (tester) async {
    await open(tester, _listing());
    await tester.enterText(find.byKey(const Key('price')), '40000');
    await background(tester);
    await open(tester, _listing(id: 8));
    expect(find.byKey(const Key('edits-back')), findsNothing);
    await tester.enterText(find.byKey(const Key('price')), '30000');
    await background(tester);
    expect((await _kept(tester, 7))!['texts'], containsPair('price', ['40000', '45000']));
    expect((await _kept(tester, 8))!['texts'], containsPair('price', ['30000', '45000']));
  });

  testWidgets('something unreadable kept by an older version gives the page as saved', (tester) async {
    SharedPreferences.setMockInitialValues({Session.listingEditsKey: '{"7": {"texts": 5}}'});
    await open(tester, _listing());
    expect(field('45000'), findsOneWidget);
    expect(find.byKey(const Key('edits-back')), findsNothing);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    expect(await _kept(tester), isNull);
  });

  /// Puts kept changes for listing 7 on the phone, as an earlier visit by seller 3 would have.
  void seed(Map<String, dynamic> edits, {Object? owner = 3}) => SharedPreferences.setMockInitialValues({
        Session.listingEditsKey: jsonEncode({
          '7': {
            'owner': owner,
            'kept_at': DateTime.now().millisecondsSinceEpoch,
            'texts': {},
            'choices': {},
            'stock': {},
            ...edits,
          }
        })
      });

  testWidgets('a choice comes back too, unless it was changed meanwhile', (tester) async {
    seed({
      'choices': {
        'audience': ['women', null], // listed before whom it is for was asked: it can still be told
        'condition': ['defective', 'new_with_box'], // the server has used_good now
      },
    });
    final sent = await open(tester, _listing(audience: null));
    expect(find.byKey(const Key('edits-back')), findsOneWidget);
    expect(find.text('Әйелдерге'), findsOneWidget);
    expect(find.text('Ақауы бар'), findsNothing);
    expect(find.textContaining('Кейбірі қайтарылмады'), findsOneWidget); // the seller is told one did not come back
    await tester.tap(find.byKey(const Key('save')));
    await tester.pumpAndSettle();
    expect(sent.single['audience'], 'women');
    expect(sent.single.containsKey('condition'), isFalse);
  });

  /// Scrolls down to the facts, below the name fields.
  Future<void> facts(WidgetTester tester) async {
    final page = find.byWidgetPredicate((w) => w is Scrollable && w.axis == Axis.vertical).first;
    await tester.scrollUntilVisible(find.text('Аяқкиім туралы (міндетті емес)'), 300, scrollable: page);
    await tester.drag(page, const Offset(0, -300)); // the facts below their heading
    await tester.pumpAndSettle();
  }

  testWidgets('picked facts come back, a fact taken off too, unless the server has another meanwhile', (tester) async {
    seed({
      'choices': {
        'fact:upper': ['mesh', 'textile'],
        'fact:season': [null, 'summer'], // taken off
        'fact:sole': ['eva', 'rubber'], // the server has none now
      },
    });
    // Never on sale yet: every fact may still change.
    final sent = await open(tester, _listing(facts: {'upper': 'textile', 'season': 'summer'}, everOnSale: false));
    expect(find.byKey(const Key('edits-back')), findsOneWidget);
    await facts(tester);
    expect(find.byKey(const ValueKey('fact-upper-mesh')), findsOneWidget);
    expect(find.byKey(const ValueKey('fact-season-null')), findsOneWidget);
    expect(find.byKey(const ValueKey('fact-sole-null')), findsOneWidget);
    await tester.tap(find.byKey(const Key('save')));
    await tester.pumpAndSettle();
    expect(sent.single['facts'], {'upper': 'mesh'});
  });

  testWidgets('a fact picked on the page is saved; nothing changed sends none', (tester) async {
    final sent = await open(tester, _listing(facts: {'upper': 'textile'}));
    await tester.tap(find.byKey(const Key('save')));
    await tester.pumpAndSettle();
    expect(sent.single.containsKey('facts'), isFalse);
    await facts(tester);
    final country = find.byKey(const ValueKey('fact-country-null'));
    await tester.ensureVisible(country);
    await tester.pumpAndSettle();
    await tester.tap(country);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Қазақстан').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save')));
    await tester.pumpAndSettle();
    expect(sent.last['facts'], {'upper': 'textile', 'country': 'KZ'});
  });

  testWidgets('on sale a picked fact stays as it is; an empty one is picked; a kept change to it is not put back',
      (tester) async {
    seed({
      'choices': {
        'fact:upper': ['leather', 'faux_leather'], // bought and reviewed as faux leather
        'fact:season': ['winter', null],
      },
    });
    final sent = await open(tester, _listing(facts: {'upper': 'faux_leather'}));
    await facts(tester);
    expect(find.text('Таңдалғаны өзгермейді, бос қалғанын толтыруға болады.'), findsOneWidget);
    final upper =
        tester.widget<DropdownButtonFormField<String?>>(find.byKey(const ValueKey('fact-upper-faux_leather')));
    expect(upper.onChanged, isNull); // shown, not offered
    expect(find.byKey(const ValueKey('fact-season-winter')), findsOneWidget); // filling an empty one comes back
    await tester.tap(find.byKey(const Key('save')));
    await tester.pumpAndSettle();
    expect(sent.single['facts'], {'upper': 'faux_leather', 'season': 'winter'});
  });

  testWidgets('a fact this app does not know is kept as it is: the page is not changed, and saving keeps it',
      (tester) async {
    // From a newer server: a fact this app has no field for, and an option it cannot name.
    final sent = await open(tester, _listing(facts: {'upper': 'graphene', 'insole': 'memory_foam'}));
    expect(find.byKey(const Key('edits-back')), findsNothing);
    await tester.tap(find.byKey(const Key('save')));
    await tester.pumpAndSettle();
    expect(sent.single.containsKey('facts'), isFalse); // nothing changed, nothing sent
    await facts(tester);
    await tester.tap(find.byKey(const ValueKey('fact-country-null')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Қазақстан').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save')));
    await tester.pumpAndSettle();
    expect(sent.last['facts'], {'upper': 'graphene', 'insole': 'memory_foam', 'country': 'KZ'});
  });

  testWidgets('dropping kept changes puts the facts back as the server has them', (tester) async {
    seed({
      'choices': {
        'fact:upper': ['mesh', 'textile'],
      },
    });
    await open(tester, _listing(facts: {'upper': 'textile'}, everOnSale: false));
    await tester.tap(find.byKey(const Key('drop-edits')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('drop-edits-sure')));
    await tester.pumpAndSettle();
    await facts(tester);
    expect(find.byKey(const ValueKey('fact-upper-textile')), findsOneWidget);
    expect(find.byKey(const ValueKey('fact-upper-mesh')), findsNothing);
  });

  testWidgets('a worse condition comes back on a listing on sale; a better one cannot be set, so it does not',
      (tester) async {
    seed({
      'choices': {
        'condition': ['defective', 'used_good'],
      },
    });
    await open(tester, _listing());
    expect(find.text('Ақауы бар'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    seed({
      'choices': {
        'condition': ['new_with_box', 'used_good'],
      },
    });
    await open(tester, _listing());
    expect(find.text('Жаңа, қорабымен'), findsNothing);
    expect(find.text('Киілген, жақсы'), findsOneWidget);
  });

  testWidgets('when nothing kept could come back, the seller is told and no note asks to save', (tester) async {
    seed({
      'texts': {
        'price': ['40000', '43000']
      },
    });
    await open(tester, _listing());
    expect(find.byKey(const Key('edits-back')), findsNothing);
    expect(find.text('Өткен жолғы сақталмаған өзгерістер қайтарылмады: тауар осы уақытта өзгерген.'), findsOneWidget);
    expect(field('45000'), findsOneWidget);
  });

  testWidgets('the shoe itself, changed before the listing went on sale, is not put back once it is on sale',
      (tester) async {
    seed({
      'texts': {
        'brand': ['Adidas', 'Nike'],
        'title': ['Nike AF1 ақ', 'Nike Air Force 1'],
      },
    });
    await open(tester, _listing()); // ever_on_sale: brand and model are fixed now
    expect(find.widgetWithText(TextFormField, 'Adidas'), findsNothing);
    expect(field('Nike AF1 ақ'), findsOneWidget);
    expect(find.textContaining('Кейбірі қайтарылмады'), findsOneWidget);
  });

  testWidgets('changes kept with no owner are not shown to whoever opens the page', (tester) async {
    seed({
      'texts': {
        'price': ['40000', '45000']
      },
    }, owner: null);
    await open(tester, _listing());
    expect(field('45000'), findsOneWidget);
    expect(find.byKey(const Key('edits-back')), findsNothing);
  });

  testWidgets('a listing hidden by a moderator gets nothing back, and its kept changes go', (tester) async {
    seed({
      'texts': {
        'price': ['40000', '45000']
      },
    });
    await open(tester, _listing(status: 'hidden'));
    expect(field('45000'), findsOneWidget);
    expect(find.byKey(const Key('edits-back')), findsNothing);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    expect(await _kept(tester), isNull);
  });

  testWidgets('a change made just before the page closes is kept, without waiting', (tester) async {
    await open(tester, _listing());
    await tester.enterText(find.byKey(const Key('price')), '40000');
    await tester.pumpWidget(const SizedBox()); // closed at once, the moment after typing
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    expect((await _kept(tester))!['texts'], containsPair('price', ['40000', '45000']));
  });

  testWidgets('changes for other listings kept long ago go when any listing keeps its own', (tester) async {
    final old = DateTime.now().subtract(const Duration(days: 20)).millisecondsSinceEpoch;
    SharedPreferences.setMockInitialValues({
      Session.listingEditsKey: jsonEncode({
        '5': {'owner': 3, 'kept_at': old, 'texts': {}, 'choices': {}, 'stock': {}},
        '6': 'unreadable',
      })
    });
    await open(tester, _listing());
    await tester.enterText(find.byKey(const Key('price')), '40000');
    await background(tester);
    final prefs = (await tester.runAsync(SharedPreferences.getInstance))!;
    expect((jsonDecode(prefs.getString(Session.listingEditsKey)!) as Map).keys, ['7']);
  });

  testWidgets('dropping the changes puts a choice on screen back too', (tester) async {
    seed({
      'choices': {
        'condition': ['defective', 'used_good'],
      },
    });
    await open(tester, _listing());
    await tester.scrollUntilVisible(find.byKey(const Key('edit-condition')), 300,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(find.text('Ақауы бар'), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const Key('drop-edits')), -300,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byKey(const Key('drop-edits')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('drop-edits-sure')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const Key('edit-condition')), 300,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(find.text('Ақауы бар'), findsNothing);
    expect(find.text('Киілген, жақсы'), findsOneWidget);
  });

  testWidgets('changes put back and then undone by hand leave no note asking to save', (tester) async {
    seed({
      'texts': {
        'price': ['40000', '45000']
      },
    });
    await open(tester, _listing());
    expect(find.byKey(const Key('edits-back')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('price')), '45000');
    await tester.pump();
    expect(find.byKey(const Key('edits-back')), findsNothing);
  });

  testWidgets('with no one signed in nothing is kept', (tester) async {
    await open(tester, _listing(), me: null);
    await tester.enterText(find.byKey(const Key('price')), '40000');
    await background(tester);
    expect(await _kept(tester), isNull);
  });
}
