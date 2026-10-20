/// The offline demo: `flutter build apk --dart-define=DEMO=true` answers every request from recorded data
/// (demo/api.json, made by demo/record.py), so the app can be tried on a phone with no server online.
///
/// Browsing, favourites and chat work in memory; anything that would change real data (orders, payments,
/// listings) answers with a plain "not in the demo" message instead.
library;

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'colors.dart';

const demoMode = bool.fromEnvironment('DEMO');

const demoToken = 'demo';

/// The demo person: a buyer who also has a shop, so the seller screens can be seen too.
const _demoShopId = 1;

class DemoClient extends http.BaseClient {
  DemoClient(this._answers);

  static Future<DemoClient> load() async =>
      DemoClient(jsonDecode(await rootBundle.loadString('demo/api.json')) as Map<String, dynamic>);

  final Map<String, dynamic> _answers;
  int _nextMessageId = 100000;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final (status, body) = _answer(request);
    final bytes = body == null ? <int>[] : utf8.encode(jsonEncode(body));
    return http.StreamedResponse(Stream.value(bytes), status,
        headers: {'content-type': 'application/json; charset=utf-8'}, request: request);
  }

  (int, Object?) _answer(http.BaseRequest request) {
    final uri = request.url;
    final path = uri.path.replaceFirst(RegExp(r'^.*/api/v1'), '');
    final method = request.method;
    final body = request is http.Request && request.body.isNotEmpty ? jsonDecode(request.body) : null;
    if (method == 'GET') return _get(path, uri.queryParameters);
    if (path.startsWith('/favorites/')) return _favorite(int.parse(path.split('/').last), method == 'POST');
    if (path == '/notifications/read-all') return (204, null);
    final m = RegExp(r'^/conversations/(\d+)/messages$').firstMatch(path);
    if (m != null && method == 'POST') return _message(m.group(1)!, (body as Map)['body'] as String);
    return (409, _notInDemo);
  }

  static const _notInDemo = {
    'code': 'demo',
    'message_kk': 'Бұл демо нұсқа: тапсырыс, төлем және тауар қосу нақты серверде жұмыс істейді.',
    'message_ru': 'Это демо-версия: заказы, оплата и добавление товаров работают на настоящем сервере.',
    'message_en': 'This is the demo: orders, payments and new listings work on the real server.',
  };

  (int, Object?) _get(String path, Map<String, String> query) {
    if (path == '/me') {
      return (200, {...(_answers['GET /me'] as Map), 'is_seller': true, 'shop_name': 'Qadam Store', 'city': 'Алматы'});
    }
    if (path == '/app-config') return (200, {'payments': true});
    if (path == '/listings') return (200, {'items': _catalog(query)});
    if (path == '/search/suggest') return (200, {'items': _suggest(query['q'] ?? '')});
    if (path == '/sellers/2') return _get('/sellers/$_demoShopId', query);
    final messages = RegExp(r'^/conversations/(\d+)/messages$').firstMatch(path);
    if (messages != null) {
      final thread = _answers['GET $path?after_id=0'] as Map?;
      if (thread == null) return (404, _notFound);
      final after = int.tryParse(query['after_id'] ?? '0') ?? 0;
      return (
        200,
        {
          ...thread,
          'items': [
            for (final m in thread['items'] as List)
              if ((m as Map)['id'] as int > after) m
          ],
        }
      );
    }
    if (RegExp(r'^/listings/\d+$').hasMatch(path) && _answers['GET $path'] is Map) {
      final one = _answers['GET $path'] as Map<String, dynamic>;
      return (200, {...one, 'colors': _colors(one)});
    }
    final keys = [
      'GET $path${query.isEmpty ? '' : '?${_sorted(query)}'}',
      'GET $path',
      if (path == '/me/analytics') 'GET /me/analytics?days=30',
    ];
    for (final k in keys) {
      if (_answers.containsKey(k)) {
        if (path == '/offers' && query['listing_id'] != null) {
          final all = (_answers[k] as Map)['items'] as List;
          return (
            200,
            {
              ...(_answers[k] as Map),
              'items': [
                for (final o in all)
                  if ('${(o as Map)['listing_id']}' == query['listing_id']) o
              ],
            }
          );
        }
        return (200, _answers[k]);
      }
    }
    return (404, _notFound);
  }

  static const _notFound = {
    'code': 'not_found',
    'message_kk': 'Табылмады.',
    'message_ru': 'Не найдено.',
    'message_en': 'Not found.'
  };

  static String _sorted(Map<String, String> q) {
    final keys = q.keys.toList()..sort();
    return keys.map((k) => '${Uri.encodeQueryComponent(k)}=${Uri.encodeQueryComponent(q[k]!)}').join('&');
  }

  List<Map<String, dynamic>> get _all => [
        for (final l in (_answers['GET /listings'] as Map)['items'] as List)
          (_answers['GET /listings/${(l as Map)['id']}'] as Map<String, dynamic>?) ?? l as Map<String, dynamic>,
      ];

  /// The server's colour choice (listing_routes.colorways), worked out from the recorded listings: per other colour
  /// the pair of the same category closest in condition, then in stock, then cheapest; all in colour-name order.
  List<Map<String, dynamic>> _colors(Map<String, dynamic> l) => colorwaysOf(l, _all);

  /// The server's catalog filters, applied to the recorded listings.
  List<Map<String, dynamic>> _catalog(Map<String, String> q) {
    final words = (q['q'] ?? '').toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    final conditions = q['condition']?.split(',').toSet();
    final colors = q['color']?.split(',').map((c) => c.trim()).where((c) => c.isNotEmpty).toSet();
    final minP = int.tryParse(q['min_price_tiyn'] ?? ''), maxP = int.tryParse(q['max_price_tiyn'] ?? '');
    final cm = double.tryParse((q['size_cm'] ?? '').replaceAll(',', '.'));
    var items = _all.where((l) {
      final text = [l['title'], l['brand'], l['model_name'], l['color'], l['category']].join(' ').toLowerCase();
      final price = l['price_tiyn'] as int;
      if (!words.every(text.contains)) return false;
      if (q['category'] != null && l['category'] != q['category']) return false;
      if (q['seller_id'] != null && '${(l['seller'] as Map)['id']}' != q['seller_id']) return false;
      if (q['sale'] == 'true' && l['was_price_tiyn'] == null) return false;
      if (conditions != null && !conditions.contains(l['condition'])) return false;
      if (colors != null &&
          colors.isNotEmpty &&
          !colors.contains(l['color']) &&
          !(colorParts[l['color']] ?? const []).any(colors.contains)) {
        return false;
      }
      if ((minP != null && price < minP) || (maxP != null && price > maxP)) return false;
      if (cm != null &&
          !(l['sizes'] as List).any((s) =>
              (s as Map)['available'] == true &&
              ((double.tryParse('${s['insole_cm']}'.replaceAll(',', '.')) ?? 0) - cm).abs() <= 0.5)) {
        return false;
      }
      return true;
    }).toList();
    switch (q['sort']) {
      case 'price_asc':
        items.sort((a, b) => (a['price_tiyn'] as int).compareTo(b['price_tiyn'] as int));
      case 'price_desc':
        items.sort((a, b) => (b['price_tiyn'] as int).compareTo(a['price_tiyn'] as int));
    }
    final offset = int.tryParse(q['offset'] ?? '') ?? 0;
    final limit = int.tryParse(q['limit'] ?? '') ?? 20;
    return items.skip(offset).take(limit).toList();
  }

  List<Map<String, dynamic>> _suggest(String q) {
    final word = q.toLowerCase().trim();
    if (word.isEmpty) return [];
    final seen = <String>{};
    return [
      for (final l in _all)
        if ((l['title'] as String).toLowerCase().contains(word) && seen.add(l['title'] as String))
          {'text': l['title'], 'kind': 'model', 'count': 1},
    ].take(6).toList();
  }

  (int, Object?) _favorite(int id, bool add) {
    final items = (_answers['GET /favorites'] as Map)['items'] as List;
    items.removeWhere((l) => (l as Map)['id'] == id);
    if (add) {
      final listing = _all.where((l) => l['id'] == id).firstOrNull;
      if (listing != null) items.insert(0, listing);
    }
    return (204, null);
  }

  (int, Object?) _message(String conversationId, String text) {
    final thread = _answers['GET /conversations/$conversationId/messages?after_id=0'] as Map?;
    if (thread == null) return (404, _notFound);
    final message = {
      'id': _nextMessageId++,
      'sender_id': (_answers['GET /me'] as Map)['id'],
      'body': text,
      'photo_url': null,
      'contact_warning': false,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    };
    (thread['items'] as List).add(message);
    return (201, message);
  }
}

const _newConditions = {'new_with_box', 'new_no_box', 'unworn_stored'};

/// The same choice as the server's colorways() (backend ColorwayTests), over recorded listings; checked on the demo
/// data in widget_test.dart.
List<Map<String, dynamic>> colorwaysOf(Map<String, dynamic> l, Iterable<Map<String, dynamic>> all) {
  String same(Object? t) =>
      '${t ?? ''}'.replaceAll('ё', 'е').replaceAll('Ё', 'Е').trim().split(RegExp(r'\s+')).join(' ').toLowerCase();
  final model = same(l['model_name']);
  if (model.isEmpty) return const [];
  bool inStock(Map o) => (o['sizes'] as List).any((s) => (s as Map)['available'] == true);
  final isNew = _newConditions.contains(l['condition']);
  // As the server's rank: condition group, then in stock, then price, then id.
  List<num> rank(Map o) => [
        _newConditions.contains(o['condition']) == isNew ? 0 : 1,
        inStock(o) ? 0 : 1,
        o['price_tiyn'] as int,
        o['id'] as int,
      ];
  int byRank(Map a, Map b) {
    final ra = rank(a), rb = rank(b);
    for (var i = 0; i < ra.length; i++) {
      if (ra[i] != rb[i]) return ra[i].compareTo(rb[i]);
    }
    return 0;
  }

  final best = <String, Map<String, dynamic>>{};
  for (final o in all) {
    final color = same(o['color']);
    if (o['id'] == l['id'] ||
        o['status'] != 'published' ||
        o['category'] != l['category'] ||
        same(o['model_name']) != model ||
        same(o['brand']) != same(l['brand']) ||
        (o['seller'] as Map)['id'] != (l['seller'] as Map)['id'] ||
        color.isEmpty ||
        color == same(l['color'])) {
      continue;
    }
    final was = best[color];
    if (was == null || byRank(o, was) < 0) best[color] = o;
  }
  if (best.isEmpty) return const [];
  final kept = best.values.toList()..sort(byRank);
  Map<String, dynamic> out(Map<String, dynamic> o) {
    final media = (o['media'] as List).cast<Map>();
    final photos = media.where((m) => m['angle'] != 'frame').toList();
    final cover = (photos.isNotEmpty ? photos : media).firstOrNull;
    return {
      'id': o['id'],
      'color': o['color'],
      'price_tiyn': o['price_tiyn'],
      'current': o['id'] == l['id'],
      'in_stock': inStock(o),
      'thumb_url': cover == null ? null : cover['thumb_url'] ?? cover['processed_url'] ?? cover['original_url'],
      'cutout': cover?['processed_url'] != null,
    };
  }

  final shown = [l, ...kept.take(11)]..sort((a, b) => same(a['color']).compareTo(same(b['color'])));
  return [for (final o in shown) out(o)];
}
