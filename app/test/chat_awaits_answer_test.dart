// A buyer who wrote and got no answer still waits after the seller opened the chat and the unread number went. The
// seller's to-do card counts those chats first and the chat list says which ones they are.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vitrina/api.dart';
import 'package:vitrina/screens/chat_screen.dart';
import 'package:vitrina/session.dart';
import 'package:vitrina/widgets/todo_card.dart';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

Map<String, Object?> _conv(int id, String body, {bool awaits = false, int unread = 0, String role = 'seller'}) => {
      'id': id,
      'listing_id': 7,
      'listing_title': 'Nike Air Force 1',
      'listing_cover': null,
      'price_tiyn': 4500000,
      'role': role,
      'other_name': 'Айгүл',
      'last_message': {
        'id': id * 10,
        'sender_id': 2,
        'body': body,
        'photo_url': null,
        'contact_warning': false,
        'created_at': '2026-10-21T10:00:00+00:00',
      },
      'unread': unread,
      if (awaits) 'awaits_answer': true,
    };

void main() {
  testWidgets('the to-do card puts buyers waiting for an answer first and opens the chat list', (tester) async {
    var todoCalls = 0;
    var waiting = 2;
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          if (req.url.path.endsWith('/me/todo')) {
            todoCalls++;
            return _json({'to_accept': 1, 'questions': 1, 'chats_to_answer': waiting, 'unread_messages': 0});
          }
          return _json({
            'items': [_conv(1, 'Өлшемі сай ма?', awaits: true), _conv(2, 'Рақмет', awaits: true)]
          });
        }))
      ..token = 't';
    await tester
        .pumpWidget(SessionScope(session: Session(api), child: const MaterialApp(home: Scaffold(body: TodoCard()))));
    await tester.pumpAndSettle();
    final line = find.byKey(const Key('todo-chats_to_answer'));
    expect(line, findsOneWidget);
    expect(find.descendant(of: line, matching: find.text('2')), findsOneWidget);
    expect(find.descendant(of: line, matching: find.text('Жауап күтетін сатып алушы')), findsOneWidget);
    // First of the lines: while online payment is off, the chat is where a sale is agreed.
    expect(tester.getTopLeft(line).dy, lessThan(tester.getTopLeft(find.byKey(const Key('todo-to_accept'))).dy));

    await tester.tap(line);
    await tester.pumpAndSettle();
    expect(tester.widget<ChatsScreen>(find.byType(ChatsScreen)).waitingFirst, isTrue);
    expect(find.byKey(const Key('chat-awaits-1')), findsOneWidget);

    // Back on the profile the card asks again, so an answered chat leaves it.
    waiting = 0;
    final before = todoCalls;
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(todoCalls, before + 1);
    expect(line, findsNothing);
  });

  testWidgets('the chat list marks only the chats waiting on the seller, read or not', (tester) async {
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async => _json({
              'items': [
                _conv(1, 'Өлшемі сай ма?', awaits: true), // opened, not answered
                _conv(2, 'Бар ма?', awaits: true, unread: 1),
                _conv(3, 'Иә, сай'), // the seller answered last
                _conv(4, 'Жіберілді ме?', role: 'buyer'), // a chat where this person buys
              ]
            })))
      ..token = 't';
    await tester.pumpWidget(SessionScope(session: Session(api), child: const MaterialApp(home: ChatsScreen())));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chat-awaits-1')), findsOneWidget);
    expect(find.byKey(const Key('chat-awaits-2')), findsOneWidget);
    expect(find.text('Жауап күтеді'), findsNWidgets(2)); // not on the answered chat nor the one this person buys in
    // The buyer's words keep a line of their own under the mark.
    expect(find.text('Өлшемі сай ма?'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Өлшемі сай ма?')).dy,
        greaterThan(tester.getBottomLeft(find.byKey(const Key('chat-awaits-1'))).dy - 1));
  });

  testWidgets('opened from the to-do card, the chats waiting for an answer come first', (tester) async {
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async => _json({
              'items': [
                _conv(3, 'Иә, сай'),
                _conv(1, 'Өлшемі сай ма?', awaits: true),
                _conv(4, 'Жіберілді ме?', role: 'buyer'),
                _conv(2, 'Бар ма?', awaits: true),
              ]
            })))
      ..token = 't';
    await tester.pumpWidget(
        SessionScope(session: Session(api), child: const MaterialApp(home: ChatsScreen(waitingFirst: true))));
    await tester.pumpAndSettle();
    final order = ['Өлшемі сай ма?', 'Бар ма?', 'Иә, сай', 'Жіберілді ме?']
        .map((t) => tester.getTopLeft(find.text(t)).dy)
        .toList();
    expect(order, [...order]..sort()); // waiting first, each group in the server's order
  });

  testWidgets('a closed chat makes every chat list read itself again', (tester) async {
    var lists = 0;
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          if (req.url.path.endsWith('/conversations')) {
            lists++;
            return _json({
              'items': [_conv(1, 'Өлшемі сай ма?', awaits: lists == 1)]
            });
          }
          return _json({'conversation': _conv(1, 'Өлшемі сай ма?'), 'items': []});
        }))
      ..token = 't';
    // The Chat tab's list, alive behind another screen, and a chat opened from somewhere else (the to-do card).
    await tester.pumpWidget(SessionScope(
        session: Session(api),
        child: const MaterialApp(home: Stack(children: [ChatsScreen(), ChatScreen(conversationId: 1)]))));
    await tester.pump();
    await tester.pump();
    expect(lists, 1);
    expect(find.byKey(const Key('chat-awaits-1')), findsOneWidget);
    await tester.pumpWidget(
        SessionScope(session: Session(api), child: const MaterialApp(home: Stack(children: [ChatsScreen()]))));
    await tester.pump();
    await tester.pump();
    expect(lists, 2);
    expect(find.byKey(const Key('chat-awaits-1')), findsNothing); // answered meanwhile: the mark is gone
  });

  test('an older server without the flag reads as nothing waiting', () {
    final c = Conversation.fromJson(_conv(3, 'Сәлем'));
    expect(c.awaitsAnswer, isFalse);
  });
}
