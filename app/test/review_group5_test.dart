// Whole-app review, group 5: the small findings, each one a word, a confirmation or a busy state.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:vitrina/api.dart';
import 'package:vitrina/main.dart';
import 'package:vitrina/screens/analytics_screen.dart';
import 'package:vitrina/screens/chat_screen.dart';
import 'package:vitrina/screens/earnings_screen.dart';
import 'package:vitrina/screens/notifications_screen.dart';
import 'package:vitrina/screens/offers_screen.dart';
import 'package:vitrina/screens/order_screen.dart';
import 'package:vitrina/screens/orders_screen.dart';
import 'package:vitrina/screens/profile_screen.dart';
import 'package:vitrina/screens/promo_codes_screen.dart';
import 'package:vitrina/session.dart';
import 'package:vitrina/widgets/common.dart' show catalogWanted;
import 'package:vitrina/widgets/questions.dart';

import 'widget_test.dart' show jsonResponse, offerJson;

Session _signedIn(MockClient client, {bool seller = false}) =>
    Session(Api(base: 'http://x/api/v1', client: client)..token = 't')
      ..update(Me.fromJson({'id': 2, 'phone': '+77010000002', 'is_seller': seller}));

Map<String, Object?> _order(String status) => {
      'id': 5,
      'status': status,
      'listing_id': 7,
      'buyer_id': 9,
      'seller_id': 2,
      'total_tiyn': 4650000,
      'listing_title': 'Жеңіл жүгіру кроссовкасы',
    };

void main() {
  testWidgets('an older chat says its day in the list, today\'s its clock', (tester) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day, 9, 5);
    Map<String, Object?> conv(int id, DateTime at) => {
          'id': id,
          'listing_id': 7,
          'listing_title': 'Shoe $id',
          'listing_cover': null,
          'price_tiyn': 4500000,
          'role': 'buyer',
          'other_name': 'Айгүл',
          'last_message': {
            'id': id,
            'sender_id': 3,
            'body': 'Сәлем',
            'photo_url': null,
            'contact_warning': false,
            'created_at': at.toUtc().toIso8601String(),
          },
          'unread': 0,
        };
    final session = _signedIn(MockClient((req) async => jsonResponse({
          'items': [conv(1, today), conv(2, DateTime(2026, 3, 4, 18, 30))]
        })));
    await tester.pumpWidget(SessionScope(session: session, child: const MaterialApp(home: ChatsScreen())));
    await tester.pumpAndSettle();
    expect(find.text('09:05'), findsOneWidget);
    expect(find.text('04.03'), findsOneWidget, reason: 'not «18:30», read as today');
  });

  testWidgets('a seller\'s delivered order says the buyer is checking it, not «awaits your confirmation»',
      (tester) async {
    final session = _signedIn(
        MockClient((req) async => jsonResponse({
              'items': [_order('DELIVERED_PENDING_CONFIRMATION')]
            })),
        seller: true);
    await tester.pumpWidget(SessionScope(session: session, child: const MaterialApp(home: OrdersScreen())));
    await tester.pumpAndSettle();
    expect(find.textContaining('Жеткізілді, растауыңызды күтеді'), findsOneWidget); // the buyer's tab
    await tester.tap(find.text('Сатқаным'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Жеткізілді, сатып алушы тексеріп жатыр'), findsOneWidget);
  });

  testWidgets('no orders yet: one button back to the shoes', (tester) async {
    final session = _signedIn(MockClient((req) async => jsonResponse({'items': []})));
    await tester.pumpWidget(SessionScope(session: session, child: const MaterialApp(home: OrdersScreen())));
    await tester.pumpAndSettle();
    final before = catalogWanted.value;
    await tester.tap(find.byKey(const Key('browse-shoes')));
    await tester.pump();
    expect(catalogWanted.value, before + 1);
  });

  group('questions', () {
    Future<List<String>> pumpSheet(WidgetTester tester) async {
      final deletes = <String>[];
      final session = _signedIn(MockClient((req) async {
        if (req.method == 'DELETE') {
          deletes.add(req.url.path);
          return jsonResponse({});
        }
        return jsonResponse({
          'items': [
            {'id': 4, 'text': 'Өлшемі кішілеу ме?', 'answer': null, 'asked_at': '2026-10-24T10:00:00Z', 'mine': true},
          ],
          'unanswered': null,
        });
      }));
      await tester.pumpWidget(SessionScope(
          session: session,
          child: const MaterialApp(
              home: Scaffold(
                  body: SingleChildScrollView(child: QuestionsSection(listingId: 7, sellerId: 3, inSheet: true))))));
      await tester.pumpAndSettle();
      return deletes;
    }

    testWidgets('a buyer takes back her own unanswered question, after saying yes', (tester) async {
      final deletes = await pumpSheet(tester);
      await tester.tap(find.byKey(const Key('take-back-4')));
      await tester.pumpAndSettle();
      expect(find.text('Сұрағыңызды қайтарып алу керек пе?'), findsOneWidget);
      await tester.tap(find.text('Болдырмау'));
      await tester.pumpAndSettle();
      expect(deletes, isEmpty);
      await tester.tap(find.byKey(const Key('take-back-4')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-action')));
      await tester.pumpAndSettle();
      expect(deletes, ['/api/v1/questions/4']);
    });

    testWidgets('a question too short says how long it must be', (tester) async {
      await pumpSheet(tester);
      await tester.tap(find.byKey(const Key('ask-question')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('question-text')), 'Иә');
      await tester.pump();
      expect(find.text('Кемінде 5 әріп жазыңыз'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('question-text')), 'Қорабы бар ма?');
      await tester.pump();
      expect(find.text('Кемінде 5 әріп жазыңыз'), findsNothing);
    });
  });

  testWidgets('a payout is sent once: the button waits, then says it went', (tester) async {
    var posts = 0;
    final session = _signedIn(MockClient((req) async {
      if (req.method == 'POST' && req.url.path.endsWith('/payouts')) {
        posts++;
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return jsonResponse({
          'id': 1,
          'amount_tiyn': 500000,
          'status': 'requested',
          'iban_masked': 'KZ86 •••• 0100',
          'created_at': '2026-10-25T10:00:00Z',
        });
      }
      if (req.url.path.endsWith('/me/payouts')) {
        return jsonResponse({
          'payable_tiyn': 500000,
          'min_tiyn': 100000,
          'has_account': true,
          'iban_masked': 'KZ86 •••• 0100',
          'ready_at': null,
          'open': false,
          'items': [],
        });
      }
      return jsonResponse({'held_tiyn': 0, 'payable_tiyn': 500000, 'fees_tiyn': 0, 'items': []});
    }), seller: true);
    await tester.pumpWidget(SessionScope(session: session, child: const MaterialApp(home: EarningsScreen())));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('payout')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('payout-confirm')));
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.widget<FilledButton>(find.byKey(const Key('payout'))).onPressed, isNull);
    expect(find.descendant(of: find.byKey(const Key('payout')), matching: find.byType(CircularProgressIndicator)),
        findsOneWidget);
    await tester.pumpAndSettle();
    expect(posts, 1);
    expect(find.text('Сұрау жіберілді. Аударылғанда хабарлама келеді.'), findsOneWidget);
  });

  testWidgets('a promo code is copied with one tap', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final session = _signedIn(
        MockClient((req) async => jsonResponse({
              'items': [
                {
                  'id': 1,
                  'code': 'QADAM10',
                  'percent': 10,
                  'amount_tiyn': null,
                  'min_price_tiyn': 0,
                  'max_uses': null,
                  'ends_on': null,
                  'uses': 0,
                  'active': true,
                }
              ]
            })),
        seller: true);
    await tester.pumpWidget(SessionScope(session: session, child: const MaterialApp(home: PromoCodesScreen())));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('copy-QADAM10')));
    await tester.pumpAndSettle();
    expect(copied, 'QADAM10');
    expect(find.text('Көшірілді: QADAM10'), findsOneWidget);
  });

  testWidgets('the analytics page says what «Конверсия» means', (tester) async {
    final session = _signedIn(
        MockClient((req) async => jsonResponse({
              'totals': {'views': 10, 'orders': 1, 'conversion': 0.1, 'sold_tiyn': 0},
              'days': [
                {'date': '2026-10-25', 'views': 10, 'orders': 1, 'sold_tiyn': 0}
              ],
              'top': []
            })),
        seller: true);
    await tester.pumpWidget(SessionScope(session: session, child: const MaterialApp(home: AnalyticsScreen())));
    await tester.pumpAndSettle();
    expect(find.text('Конверсия: қаралымның неше пайызы тапсырысқа айналды.'), findsOneWidget);
  });

  testWidgets('signing out asks first', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final session = _signedIn(MockClient((req) async => jsonResponse({'items': []})));
    await tester.pumpWidget(SessionScope(session: session, child: const MaterialApp(home: ProfileScreen())));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Шығу'), 200);
    await tester.tap(find.text('Шығу'));
    await tester.pumpAndSettle();
    expect(find.text('Аккаунттан шығу керек пе?'), findsOneWidget);
    await tester.tap(find.text('Болдырмау'));
    await tester.pumpAndSettle();
    expect(session.signedIn, isTrue);
  });

  testWidgets('pulling the notifications down reads them again', (tester) async {
    var reads = 0;
    final session = _signedIn(MockClient((req) async {
      if (req.url.path.endsWith('/notifications') && req.method == 'GET') reads++;
      return jsonResponse({'items': [], 'unread': 0});
    }));
    await tester.pumpWidget(SessionScope(session: session, child: const MaterialApp(home: NotificationsScreen())));
    await tester.pumpAndSettle();
    expect(reads, 1);
    await tester.fling(find.text('Хабарландыру жоқ.'), const Offset(0, 400), 1000);
    await tester.pumpAndSettle();
    expect(reads, 2);
  });

  testWidgets('declining an offer asks first, and sends once said yes', (tester) async {
    final posts = <String>[];
    final session = Session(Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          if (req.method == 'POST') {
            posts.add(req.url.path);
            return jsonResponse(offerJson(status: 'declined'));
          }
          return jsonResponse({
            'items': [offerJson()],
            'next_before': null
          });
        }))
      ..token = 't')
      ..update(Me.fromJson({'id': 3, 'phone': '+77010000003', 'is_seller': true}));
    await tester.pumpWidget(SessionScope(session: session, child: const MaterialApp(home: OffersScreen(seller: true))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Бас тарту'));
    await tester.pumpAndSettle();
    expect(find.text('Ұсыныстан бас тарту керек пе?'), findsOneWidget);
    await tester.tap(find.text('Болдырмау'));
    await tester.pumpAndSettle();
    expect(posts, isEmpty);
    await tester.tap(find.text('Бас тарту'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-action')));
    await tester.pumpAndSettle();
    expect(posts, hasLength(1));
    expect(posts.single, endsWith('/decline'));
  });

  testWidgets('a refund on its way says where the money goes', (tester) async {
    final session = _signedIn(MockClient((req) async => jsonResponse({
          ..._order('REFUND_PENDING'),
          'buyer_id': 2,
          'seller_id': 3,
          'history': [],
        })));
    tester.view.physicalSize = const Size(500, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(SessionScope(session: session, child: const MaterialApp(home: OrderScreen(orderId: 5))));
    await tester.pumpAndSettle();
    expect(find.text('Ақша қайтарылуда'), findsOneWidget);
    expect(find.textContaining('Ақша төлеген картаңызға қайтарылады.'), findsOneWidget);
  });

  testWidgets('the seller of a refunded order is not told about «your card»', (tester) async {
    final session = _signedIn(MockClient((req) async => jsonResponse({..._order('REFUND_PENDING'), 'history': []})));
    tester.view.physicalSize = const Size(500, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(SessionScope(session: session, child: const MaterialApp(home: OrderScreen(orderId: 5))));
    await tester.pumpAndSettle();
    expect(find.textContaining('картаңызға'), findsNothing);
    expect(find.text('Ақша сатып алушыға қайтарылып жатыр.'), findsOneWidget);
  });

  testWidgets('taking back an offer on the listing page asks first, with the step named on the button', (tester) async {
    final posts = <String>[];
    final session = _signedIn(MockClient((req) async {
      posts.add(req.url.path);
      return jsonResponse(offerJson(status: 'withdrawn'));
    }));
    await tester.pumpWidget(SessionScope(
        session: session,
        child:
            MaterialApp(home: Scaffold(body: OfferStatusCard(offer: Offer.fromJson(offerJson()), onChanged: (_) {})))));
    await tester.tap(find.text('Ұсынысты қайтару'));
    await tester.pumpAndSettle();
    expect(find.text('Ұсынысты қайтару керек пе?'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('confirm-action')), matching: find.text('Ұсынысты қайтару')),
        findsOneWidget);
    await tester.tap(find.text('Болдырмау'));
    await tester.pumpAndSettle();
    expect(posts, isEmpty);
    await tester.tap(find.text('Ұсынысты қайтару'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-action')));
    await tester.pumpAndSettle();
    expect(posts, hasLength(1));
    expect(posts.single, endsWith('/withdraw'));
  });

  testWidgets('an ended sign-in is said in words, and «Аяқкиім қарау» brings the catalog back', (tester) async {
    SharedPreferences.setMockInitialValues({});
    forgetLastTab();
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async => req.url.path == '/api/v1/me'
            ? http.Response('{"detail":"expired"}', 401, headers: {'content-type': 'application/json'})
            : jsonResponse({'items': []})))
      ..token = 't';
    final session = Session(api);
    await tester.pumpWidget(SessionScope(session: session, child: const MaterialApp(home: HomeShell())));
    await tester.runAsync(() => session.reloadMe());
    await tester.pumpAndSettle();
    expect(find.text('Кіру мерзімі бітті. Қайта кіріңіз.'), findsOneWidget);
    expect(session.signedIn, isFalse);
    await tester.tap(find.byKey(const Key('tab-orders')));
    await tester.pumpAndSettle();
    expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 3);
    catalogWanted.value++;
    await tester.pumpAndSettle();
    expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 0);
    await tester.pumpWidget(const SizedBox()); // stops the polling timer
  });
}
