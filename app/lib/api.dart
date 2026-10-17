import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

/// Base URL of the VITRINA API. The Android emulator reaches the host's localhost at 10.0.2.2.
/// Override with `--dart-define=API_BASE=https://...`.
const apiBase = String.fromEnvironment('API_BASE', defaultValue: 'http://10.0.2.2:8000/api/v1');

/// Error as the API returns it: a stable code plus ready messages in Kazakh and Russian.
class ApiException implements Exception {
  ApiException(this.status, this.code, this.messageKk, [this.detail]);
  final int status;
  final String code;
  final String messageKk;
  final String? detail;

  @override
  String toString() => messageKk;
}

class ShoeSize {
  ShoeSize.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        label = j['label'] as String,
        insoleCm = j['insole_cm'] as String,
        available = j['available'] as bool,
        quantity = j['quantity'] as int?;
  final int id;
  final String label;
  final String insoleCm;
  final bool available;

  /// Stock count; only present on the seller's own listings.
  final int? quantity;
}

/// Catalog refinements beyond text, size and category.
class CatalogFilter {
  const CatalogFilter({this.sort = 'new', this.conditions = const {}, this.minPriceTiyn, this.maxPriceTiyn});
  final String sort; // new | price_asc | price_desc
  final Set<String> conditions;
  final int? minPriceTiyn;
  final int? maxPriceTiyn;

  /// How many refinements differ from the default, for the badge on the filter button.
  int get active =>
      (sort != 'new' ? 1 : 0) +
      (conditions.isNotEmpty ? 1 : 0) +
      (minPriceTiyn != null || maxPriceTiyn != null ? 1 : 0);

  Map<String, String> get query => {
        if (sort != 'new') 'sort': sort,
        if (conditions.isNotEmpty) 'condition': conditions.join(','),
        if (minPriceTiyn != null) 'min_price_tiyn': '$minPriceTiyn',
        if (maxPriceTiyn != null) 'max_price_tiyn': '$maxPriceTiyn',
      };
}

class MediaItem {
  MediaItem.fromJson(Map<String, dynamic> j)
      : originalUrl = j['original_url'] as String,
        processedUrl = j['processed_url'] as String?,
        angle = j['angle'] as String;
  final String originalUrl;
  final String? processedUrl;
  final String angle;

  /// The processed image only changes the background; the original stays available.
  String get url => processedUrl ?? originalUrl;
}

class Listing {
  Listing.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        status = j['status'] as String,
        title = j['title'] as String,
        category = j['category'] as String,
        brand = j['brand'] as String?,
        color = j['color'] as String,
        priceTiyn = j['price_tiyn'] as int,
        deliveryPriceTiyn = j['delivery_price_tiyn'] as int,
        segment = j['segment'] as String?,
        condition = j['condition'] as String,
        authenticity = j['authenticity'] as String,
        defects = j['defects'] as String?,
        description = j['description'] as String?,
        showcaseStyle = j['showcase_style'] as String,
        sizes = [for (final s in j['sizes'] as List) ShoeSize.fromJson(s as Map<String, dynamic>)],
        media = [for (final m in j['media'] as List) MediaItem.fromJson(m as Map<String, dynamic>)],
        shopName = (j['seller'] as Map)['shop_name'] as String?,
        sellerCity = (j['seller'] as Map)['city'] as String?,
        sellerId = (j['seller'] as Map)['id'] as int,
        sellerRating = ((j['seller'] as Map)['rating'] as num?)?.toDouble(),
        sellerReviews = ((j['seller'] as Map)['reviews'] as int?) ?? 0;

  final int id;
  final String status;
  final String title;
  final String category;
  final String? brand;
  final String color;
  final int priceTiyn;
  final int deliveryPriceTiyn;
  final String? segment;
  final String condition;
  final String authenticity;
  final String? defects;
  final String? description;
  final String showcaseStyle;
  final List<ShoeSize> sizes;
  final List<MediaItem> media;
  final String? shopName;
  final String? sellerCity;
  final int sellerId;
  final double? sellerRating;
  final int sellerReviews;

  /// 360° frames in upload order: real photos only, nothing generated in between.
  List<MediaItem> get frames => media.where((m) => m.angle == 'frame').toList();
  List<MediaItem> get photos => media.where((m) => m.angle != 'frame').toList();
  String? get coverUrl => (photos.isNotEmpty ? photos : media).firstOrNull?.url;
}

class OrderInfo {
  OrderInfo.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        status = j['status'] as String,
        listingId = j['listing_id'] as int,
        buyerId = j['buyer_id'] as int,
        sellerId = j['seller_id'] as int,
        totalTiyn = j['total_tiyn'] as int,
        trackingNumber = j['tracking_number'] as String?,
        listingTitle = j['listing_title'] as String?,
        reviewed = (j['reviewed'] as bool?) ?? false,
        listingCover = j['listing_cover'] as String?,
        sizeLabel = j['size_label'] as String?,
        sizeCm = j['size_cm'] as String?,
        history = [
          for (final h in (j['history'] as List?) ?? const [])
            (status: (h as Map)['status'] as String, at: DateTime.parse(h['at'] as String).toLocal()),
        ];
  final int id;
  final String status;
  final int listingId;
  final int buyerId;
  final int sellerId;
  final int totalTiyn;
  final String? trackingNumber;
  final String? listingTitle;
  final bool reviewed;
  final String? listingCover;
  final String? sizeLabel;
  final String? sizeCm;
  final List<({String status, DateTime at})> history;
}

class Me {
  Me.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        phone = j['phone'] as String,
        displayName = j['display_name'] as String?,
        city = j['city'] as String?,
        isSeller = j['is_seller'] as bool,
        shopName = j['shop_name'] as String?;
  final int id;
  final String phone;
  final String? displayName;
  final String? city;
  final bool isSeller;
  final String? shopName;
}

class ChatMessage {
  ChatMessage.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        senderId = j['sender_id'] as int,
        body = j['body'] as String,
        contactWarning = j['contact_warning'] as bool,
        createdAt = DateTime.parse(j['created_at'] as String).toLocal();
  final int id;
  final int senderId;
  final String body;
  final bool contactWarning;
  final DateTime createdAt;
}

class Conversation {
  Conversation.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        listingId = j['listing_id'] as int,
        listingTitle = j['listing_title'] as String,
        listingCover = j['listing_cover'] as String?,
        priceTiyn = j['price_tiyn'] as int,
        role = j['role'] as String,
        otherName = j['other_name'] as String,
        lastMessage =
            j['last_message'] == null ? null : ChatMessage.fromJson(j['last_message'] as Map<String, dynamic>),
        unread = j['unread'] as int;
  final int id;
  final int listingId;
  final String listingTitle;
  final String? listingCover;
  final int priceTiyn;
  final String role;
  final String otherName;
  final ChatMessage? lastMessage;
  final int unread;
}

class Review {
  Review.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        rating = j['rating'] as int,
        text = j['text'] as String?,
        sellerReply = j['seller_reply'] as String?,
        buyerName = j['buyer_name'] as String,
        createdAt = DateTime.parse(j['created_at'] as String).toLocal();
  final int id;
  final int rating;
  final String? text;
  final String? sellerReply;
  final String buyerName;
  final DateTime createdAt;
}

class AppNotification {
  AppNotification.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        kind = j['kind'] as String,
        text = j['text'] as String,
        orderId = j['order_id'] as int?,
        conversationId = j['conversation_id'] as int?,
        read = j['read'] as bool,
        createdAt = DateTime.parse(j['created_at'] as String).toLocal();
  final int id;
  final String kind;
  final String text;
  final int? orderId;
  final int? conversationId;
  final bool read;
  final DateTime createdAt;
}

class Api {
  Api({http.Client? client, this.base = apiBase}) : _client = client ?? http.Client();
  final http.Client _client;
  final String base;
  String? token;

  Future<dynamic> _send(String method, String path,
      {Object? body, Map<String, String>? query, Map<String, String>? headers}) async {
    final uri = Uri.parse('$base$path').replace(queryParameters: query);
    final req = http.Request(method, uri)
      ..headers.addAll({
        'Accept': 'application/json',
        if (body != null) 'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
        ...?headers,
      });
    if (body != null) req.body = jsonEncode(body);
    return _decode(await http.Response.fromStream(await _client.send(req)));
  }

  static dynamic _decode(http.Response res) {
    final data = res.bodyBytes.isEmpty ? null : jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode >= 400) {
      final m = data is Map ? data : const {};
      throw ApiException(res.statusCode, (m['code'] ?? 'error') as String, (m['message_kk'] ?? 'Қате.') as String,
          m['detail'] as String?);
    }
    return data;
  }

  // auth
  /// Returns the code itself only while the server runs without a real SMS provider.
  Future<String?> requestOtp(String phone) async =>
      (await _send('POST', '/auth/otp', body: {'phone': phone}) as Map)['dev_code'] as String?;

  Future<Me> verifyOtp(String phone, String code) async {
    final r = await _send('POST', '/auth/verify', body: {'phone': phone, 'code': code}) as Map<String, dynamic>;
    token = r['token'] as String;
    return Me.fromJson(r['user'] as Map<String, dynamic>);
  }

  Future<Me> me() async => Me.fromJson(await _send('GET', '/me') as Map<String, dynamic>);

  Future<Me> becomeSeller(String shopName, String city) async => Me.fromJson(
      await _send('POST', '/me/seller', body: {'shop_name': shopName, 'city': city}) as Map<String, dynamic>);

  // selling
  /// Uploads one photo; the server strips metadata and returns the URL to reference in a listing.
  Future<String> uploadPhoto(List<int> bytes, String filename) async {
    final req = http.MultipartRequest('POST', Uri.parse('$base/media'))
      ..headers.addAll({'Accept': 'application/json', if (token != null) 'Authorization': 'Bearer $token'})
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    final data = _decode(await http.Response.fromStream(await _client.send(req)));
    return (data as Map)['url'] as String;
  }

  Future<Listing> createListing(Map<String, dynamic> body) async =>
      Listing.fromJson(await _send('POST', '/listings', body: body) as Map<String, dynamic>);

  Future<Listing> publishListing(int id) async =>
      Listing.fromJson(await _send('POST', '/listings/$id/publish') as Map<String, dynamic>);

  Future<Listing> editListing(int id,
          {int? priceTiyn, int? deliveryPriceTiyn, String? description, String? defects, Map<int, int>? stock}) async =>
      Listing.fromJson(await _send('PATCH', '/listings/$id', body: {
        if (priceTiyn != null) 'price_tiyn': priceTiyn,
        if (deliveryPriceTiyn != null) 'delivery_price_tiyn': deliveryPriceTiyn,
        if (description != null) 'description': description,
        if (defects != null) 'defects': defects,
        if (stock != null) 'sizes': [for (final e in stock.entries) {'id': e.key, 'quantity': e.value}],
      }) as Map<String, dynamic>);

  Future<Listing> pauseListing(int id) async =>
      Listing.fromJson(await _send('POST', '/listings/$id/pause') as Map<String, dynamic>);

  Future<List<Listing>> myListings() async {
    final r = await _send('GET', '/me/listings') as Map;
    return [for (final j in r['items'] as List) Listing.fromJson(j as Map<String, dynamic>)];
  }

  // catalog
  Future<List<Listing>> search(
      {String? q, String? sizeCm, String? category, CatalogFilter filter = const CatalogFilter()}) async {
    final r = await _send('GET', '/listings', query: {
      if (q != null && q.isNotEmpty) 'q': q,
      if (sizeCm != null && sizeCm.isNotEmpty) 'size_cm': sizeCm,
      if (category != null) 'category': category,
      ...filter.query,
    }) as Map;
    return [for (final j in r['items'] as List) Listing.fromJson(j as Map<String, dynamic>)];
  }

  Future<Listing> listing(int id) async =>
      Listing.fromJson(await _send('GET', '/listings/$id') as Map<String, dynamic>);

  Future<List<Listing>> favorites() async {
    final r = await _send('GET', '/favorites') as Map;
    return [for (final j in r['items'] as List) Listing.fromJson(j as Map<String, dynamic>)];
  }

  Future<void> setFavorite(int listingId, bool on) => _send(on ? 'POST' : 'DELETE', '/favorites/$listingId');

  // orders
  /// [idempotencyKey] must stay the same when the same tap is retried, so a lost response never creates two orders.
  Future<OrderInfo> createOrder(int listingId, int sizeId, String idempotencyKey) async =>
      OrderInfo.fromJson(await _send('POST', '/orders',
          body: {'listing_id': listingId, 'size_id': sizeId},
          headers: {'Idempotency-Key': idempotencyKey}) as Map<String, dynamic>);

  Future<List<OrderInfo>> orders({String role = 'buyer'}) async {
    final r = await _send('GET', '/orders', query: {'role': role}) as Map;
    return [for (final j in r['items'] as List) OrderInfo.fromJson(j as Map<String, dynamic>)];
  }

  Future<OrderInfo> order(int id) async =>
      OrderInfo.fromJson(await _send('GET', '/orders/$id') as Map<String, dynamic>);

  /// Starts a payment with the provider. Only the provider's signed webhook marks the order paid.
  Future<void> startPayment(int id) => _send('POST', '/orders/$id/pay');

  Future<OrderInfo> action(int id, String action, {String? reason, String? trackingNumber}) async =>
      OrderInfo.fromJson(await _send('POST', '/orders/$id/$action', body: {
        if (reason != null) 'reason': reason,
        if (trackingNumber != null) 'tracking_number': trackingNumber,
      }) as Map<String, dynamic>);

  // chat
  Future<Conversation> openConversation(int listingId) async => Conversation.fromJson(
      await _send('POST', '/conversations', body: {'listing_id': listingId}) as Map<String, dynamic>);

  Future<List<Conversation>> conversations() async {
    final r = await _send('GET', '/conversations') as Map;
    return [for (final j in r['items'] as List) Conversation.fromJson(j as Map<String, dynamic>)];
  }

  Future<(Conversation, List<ChatMessage>)> messages(int conversationId, {int afterId = 0}) async {
    final r = await _send('GET', '/conversations/$conversationId/messages', query: {'after_id': '$afterId'}) as Map;
    return (
      Conversation.fromJson(r['conversation'] as Map<String, dynamic>),
      [for (final j in r['items'] as List) ChatMessage.fromJson(j as Map<String, dynamic>)],
    );
  }

  Future<ChatMessage> sendMessage(int conversationId, String body) async => ChatMessage.fromJson(
      await _send('POST', '/conversations/$conversationId/messages', body: {'body': body}) as Map<String, dynamic>);

  // reviews
  Future<Review> review(int orderId, int rating, String? text) async =>
      Review.fromJson(await _send('POST', '/orders/$orderId/review',
          body: {'rating': rating, if (text != null && text.isNotEmpty) 'text': text}) as Map<String, dynamic>);

  Future<List<Review>> sellerReviews(int sellerId) async {
    final r = await _send('GET', '/sellers/$sellerId/reviews') as Map;
    return [for (final j in r['items'] as List) Review.fromJson(j as Map<String, dynamic>)];
  }

  // notifications
  Future<(int, List<AppNotification>)> notifications() async {
    final r = await _send('GET', '/notifications') as Map;
    return (
      r['unread'] as int,
      [for (final j in r['items'] as List) AppNotification.fromJson(j as Map<String, dynamic>)]
    );
  }

  Future<void> readAllNotifications() => _send('POST', '/notifications/read-all');
}

String newIdempotencyKey() {
  final r = Random.secure();
  return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}
