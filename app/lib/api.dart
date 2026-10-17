import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'i18n.dart';

/// Base URL of the VITRINA API. The Android emulator reaches the host's localhost at 10.0.2.2.
/// Override with `--dart-define=API_BASE=https://...`.
const apiBase = String.fromEnvironment('API_BASE', defaultValue: 'http://10.0.2.2:8000/api/v1');

/// Public page for a listing, as sent to friends: messengers show its photo and price, and it opens the app.
String listingShareUrl(int id, {String base = apiBase}) => '${base.replaceFirst(RegExp(r'/api/v1/?$'), '')}/l/$id';

/// The shop's public page: everything on sale now, for an Instagram bio or a WhatsApp status.
String shopShareUrl(int sellerId, {String base = apiBase}) =>
    '${base.replaceFirst(RegExp(r'/api/v1/?$'), '')}/s/$sellerId';

/// Error as the API returns it: a stable code plus ready messages in Kazakh, Russian and English.
class ApiException implements Exception {
  ApiException(this.status, this.code, this.messageKk, [this.detail, this.messageRu, this.messageEn]) : _local = false;

  /// Raised by the app itself when the server could not be reached or answered something unreadable;
  /// [messageKk] is then a key for [tr], so the text follows the interface language.
  ApiException.local(this.status, this.code, this.messageKk, [this.detail])
      : messageRu = null,
        messageEn = null,
        _local = true;
  final bool _local;
  final int status;
  final String code;
  final String messageKk;
  final String? detail;
  final String? messageRu;
  final String? messageEn;

  /// The server's message in the interface language.
  String get message => _local ? tr(messageKk) : pick(messageKk, messageRu, messageEn);

  /// No answer at all: no network, the server is down, or it did not answer in time.
  bool get offline => code == 'network' || code == 'timeout';

  @override
  String toString() => message;
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

class ListingStats {
  ListingStats.fromJson(Map<String, dynamic> j)
      : views = j['views'] as int,
        favorites = j['favorites'] as int,
        chats = j['chats'] as int,
        orders = j['orders'] as int,
        sold = j['sold'] as int;
  final int views;
  final int favorites;
  final int chats;
  final int orders;
  final int sold;
}

/// The seller's shareable promo video. state: null (never made), rendering, ready or failed.
class Promo {
  Promo.fromJson(Map<String, dynamic> j)
      : state = j['state'] as String?,
        url = j['url'] as String?;
  final String? state;
  final String? url;
}

/// Catalog filters a buyer saved; a new listing that matches them arrives as a notification.
class SavedSearch {
  SavedSearch.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        q = j['q'] as String?,
        category = j['category'] as String?,
        condition = j['condition'] as String?,
        minPriceTiyn = j['min_price_tiyn'] as int?,
        maxPriceTiyn = j['max_price_tiyn'] as int?,
        sizeCm = j['size_cm'] as String?;
  final int id;
  final String? q;
  final String? category;
  final String? condition;
  final int? minPriceTiyn;
  final int? maxPriceTiyn;
  final String? sizeCm;

  /// The same filters as the catalog sends, for saving and comparing.
  static Map<String, Object> body(
          {String? q, String? category, String? sizeCm, CatalogFilter filter = const CatalogFilter()}) =>
      {
        if ((q ?? '').trim().isNotEmpty) 'q': q!.trim(),
        if (category != null) 'category': category,
        if (sizeCm != null) 'size_cm': sizeCm,
        if (filter.conditions.isNotEmpty) 'condition': (filter.conditions.toList()..sort()).join(','),
        if (filter.minPriceTiyn != null) 'min_price_tiyn': filter.minPriceTiyn!,
        if (filter.maxPriceTiyn != null) 'max_price_tiyn': filter.maxPriceTiyn!,
      };

  Map<String, Object> get asBody => body(
      q: q,
      category: category,
      sizeCm: sizeCm,
      filter: CatalogFilter(
          conditions: {...?condition?.split(',').where((c) => c.isNotEmpty)},
          minPriceTiyn: minPriceTiyn,
          maxPriceTiyn: maxPriceTiyn));
}

/// A buyer's price offer on one size; `priceTiyn` is what they pay once it is accepted.
class Offer {
  Offer.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        listingId = j['listing_id'] as int,
        listingTitle = j['listing_title'] as String,
        listingCover = j['listing_cover'] as String?,
        listPriceTiyn = j['list_price_tiyn'] as int,
        sizeId = j['size_id'] as int,
        sizeLabel = j['size_label'] as String,
        amountTiyn = j['amount_tiyn'] as int,
        counterTiyn = j['counter_tiyn'] as int?,
        priceTiyn = j['price_tiyn'] as int,
        status = j['status'] as String,
        expiresAt = DateTime.parse(j['expires_at'] as String);
  final int id;
  final int listingId;
  final String listingTitle;
  final String? listingCover;
  final int listPriceTiyn;
  final int sizeId;
  final String sizeLabel;
  final int amountTiyn;
  final int? counterTiyn;
  final int priceTiyn;
  final String status; // pending | countered | accepted | declined | withdrawn | ordered | expired
  final DateTime expiresAt;
}

/// Why the automatic publish checks held a listing back, and what staff wrote when sending it back.
class Moderation {
  Moderation.fromJson(Map<String, dynamic> j)
      : flags = [for (final f in j['flags'] as List) f as String],
        reasonsKk = [for (final r in j['reasons'] as List) r as String],
        reasonsRu = [for (final r in (j['reasons_ru'] as List?) ?? j['reasons'] as List) r as String],
        reasonsEn = [
          for (final r in (j['reasons_en'] as List?) ?? (j['reasons_ru'] as List?) ?? j['reasons'] as List) r as String
        ],
        note = j['note'] as String?;
  final List<String> flags;
  final List<String> reasonsKk;
  final List<String> reasonsRu;
  final List<String> reasonsEn;
  final String? note;

  List<String> reasons(String lang) => switch (lang) { 'ru' => reasonsRu, 'en' => reasonsEn, _ => reasonsKk };
}

/// Brand, model and category read off look-alike listings already on VITRINA. Any field may be null.
class Suggestion {
  Suggestion.fromJson(Map<String, dynamic> j)
      : category = j['category'] as String?,
        brand = j['brand'] as String?,
        modelName = j['model_name'] as String?;
  final String? category;
  final String? brand;
  final String? modelName;
  bool get isEmpty => category == null && brand == null && modelName == null;
}

class Shop {
  Shop.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        shopName = j['shop_name'] as String? ?? tr('Сатушы'),
        city = j['city'] as String?,
        since = DateTime.parse(j['since'] as String),
        completedSales = j['completed_sales'] as int,
        listings = j['listings'] as int,
        rating = (j['rating'] as num?)?.toDouble(),
        reviews = j['reviews'] as int,
        followers = j['followers'] as int? ?? 0,
        following = j['following'] as bool? ?? false,
        replyBucket = (j['reply_time'] as Map?)?['bucket'] as String?,
        shipBucket = (j['ship_time'] as Map?)?['bucket'] as String?,
        about = j['about'] as String?;
  final int id;
  final String shopName;

  /// The seller's own few lines: shipping, returns, hours. Never contacts; the server refuses those.
  final String? about;
  final String? city;
  final DateTime since;
  final int completedSales;
  final int listings;
  final double? rating;
  final int reviews;
  final int followers;
  final bool following;

  /// How fast the seller usually answers in chat: "hour", "hours", "day" or "days"; null while there is too little to say.
  final String? replyBucket;

  /// How soon the shop usually ships after payment: day | two_days | longer; null until there are 3 orders.
  final String? shipBucket;
}

/// A shop the user follows, as listed on «Жазылымдар».
class FollowedShop {
  FollowedShop.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        shopName = j['shop_name'] as String? ?? tr('Сатушы'),
        city = j['city'] as String?,
        listings = j['listings'] as int,
        rating = (j['rating'] as num?)?.toDouble(),
        awayUntil = j['away_until'] == null ? null : DateTime.parse(j['away_until'] as String);
  final int id;
  final String shopName;
  final String? city;
  final int listings;
  final double? rating;
  final DateTime? awayUntil;
}

class DayStats {
  DayStats.fromJson(Map<String, dynamic> j)
      : date = DateTime.parse(j['date'] as String),
        views = j['views'] as int,
        orders = j['orders'] as int,
        soldTiyn = j['sold_tiyn'] as int;
  final DateTime date;
  final int views;
  final int orders;
  final int soldTiyn;
}

class TopListing {
  TopListing.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        title = j['title'] as String,
        status = j['status'] as String,
        views = j['views'] as int,
        orders = j['orders'] as int;
  final int id;
  final String title;
  final String status;
  final int views;
  final int orders;
}

/// The seller's last days: views, orders and sales per day (Almaty calendar), and the most viewed listings.
class Analytics {
  Analytics.fromJson(Map<String, dynamic> j)
      : days = [for (final d in j['days'] as List) DayStats.fromJson(d as Map<String, dynamic>)],
        views = (j['totals'] as Map)['views'] as int,
        orders = (j['totals'] as Map)['orders'] as int,
        soldTiyn = (j['totals'] as Map)['sold_tiyn'] as int,
        conversion = ((j['totals'] as Map)['conversion'] as num?)?.toDouble(),
        top = [for (final t in j['top'] as List) TopListing.fromJson(t as Map<String, dynamic>)];
  final List<DayStats> days;
  final int views;
  final int orders;
  final int soldTiyn;
  final double? conversion;
  final List<TopListing> top;
}

class Earnings {
  Earnings.fromJson(Map<String, dynamic> j)
      : heldTiyn = j['held_tiyn'] as int,
        payableTiyn = j['payable_tiyn'] as int,
        feesTiyn = j['fees_tiyn'] as int,
        items = [for (final i in j['items'] as List) EarningItem.fromJson(i as Map<String, dynamic>)];
  final int heldTiyn;
  final int payableTiyn;
  final int feesTiyn;
  final List<EarningItem> items;
}

class EarningItem {
  EarningItem.fromJson(Map<String, dynamic> j)
      : orderId = j['order_id'] as int,
        kind = j['kind'] as String,
        at = DateTime.parse(j['at'] as String),
        listingTitle = j['listing_title'] as String,
        netTiyn = j['net_tiyn'] as int,
        feeTiyn = j['fee_tiyn'] as int;
  final int orderId;
  final String kind; // completion | partial_refund | refund_full
  final DateTime at;
  final String listingTitle;
  final int netTiyn;
  final int feeTiyn;
}

/// Where a seller's money goes: holder, Kazakh IBAN and IIN/BIN.
class PayoutAccount {
  PayoutAccount.fromJson(Map<String, dynamic> j)
      : holderName = j['holder_name'] as String,
        iban = j['iban'] as String,
        ibanMasked = j['iban_masked'] as String,
        taxId = j['tax_id'] as String;
  final String holderName;
  final String iban;
  final String ibanMasked;
  final String taxId;
}

class Payouts {
  Payouts.fromJson(Map<String, dynamic> j)
      : payableTiyn = j['payable_tiyn'] as int,
        minTiyn = j['min_tiyn'] as int,
        hasAccount = j['has_account'] as bool,
        open = j['open'] as bool,
        items = [for (final i in j['items'] as List) PayoutInfo.fromJson(i as Map<String, dynamic>)];
  final int payableTiyn;
  final int minTiyn;
  final bool hasAccount;
  final bool open;
  final List<PayoutInfo> items;
}

class PayoutInfo {
  PayoutInfo.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        amountTiyn = j['amount_tiyn'] as int,
        status = j['status'] as String,
        ibanMasked = j['iban_masked'] as String,
        createdAt = DateTime.parse(j['created_at'] as String),
        bankRef = j['bank_ref'] as String?,
        reason = j['reason'] as String?;
  final int id;
  final int amountTiyn;
  final String status; // requested | paid | rejected
  final String ibanMasked;
  final DateTime createdAt;
  final String? bankRef;
  final String? reason;
}

/// About when a pair would arrive: the seller's usual shipping time plus transit between the cities.
class DeliveryEstimate {
  DeliveryEstimate.fromJson(Map<String, dynamic> j)
      : city = j['city'] as String,
        fromCity = j['from_city'] as String,
        earliest = DateTime.parse(j['earliest'] as String),
        latest = DateTime.parse(j['latest'] as String);
  final String city;
  final String fromCity;
  final DateTime earliest;
  final DateTime latest;
}

/// Catalog refinements beyond text, size and category.
class CatalogFilter {
  const CatalogFilter({this.sort = 'new', this.conditions = const {}, this.minPriceTiyn, this.maxPriceTiyn, this.city});
  final String sort; // new | price_asc | price_desc
  final String? city; // the seller's city: nearby pairs come sooner and cost less to send
  final Set<String> conditions;
  final int? minPriceTiyn;
  final int? maxPriceTiyn;

  /// How many refinements differ from the default, for the badge on the filter button.
  int get active =>
      (sort != 'new' ? 1 : 0) +
      (conditions.isNotEmpty ? 1 : 0) +
      (minPriceTiyn != null || maxPriceTiyn != null ? 1 : 0) +
      (city != null ? 1 : 0);

  Map<String, String> get query => {
        if (sort != 'new') 'sort': sort,
        if (conditions.isNotEmpty) 'condition': conditions.join(','),
        if (minPriceTiyn != null) 'min_price_tiyn': '$minPriceTiyn',
        if (maxPriceTiyn != null) 'max_price_tiyn': '$maxPriceTiyn',
        if (city != null) 'city': city!,
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
        wasPriceTiyn = j['was_price_tiyn'] as int?,
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
        sellerAwayUntil = (j['seller'] as Map)['away_until'] == null
            ? null
            : DateTime.parse((j['seller'] as Map)['away_until'] as String),
        sellerRating = ((j['seller'] as Map)['rating'] as num?)?.toDouble(),
        sellerReviews = ((j['seller'] as Map)['reviews'] as int?) ?? 0,
        stats = j['stats'] == null ? null : ListingStats.fromJson(j['stats'] as Map<String, dynamic>),
        promo = j['promo'] == null ? null : Promo.fromJson(j['promo'] as Map<String, dynamic>),
        moderation = j['moderation'] == null ? null : Moderation.fromJson(j['moderation'] as Map<String, dynamic>),
        sizeFit = j['size_fit'] == null ? null : SizeFit.fromJson(j['size_fit'] as Map<String, dynamic>),
        stockAlerts = {for (final id in (j['stock_alerts'] as List?) ?? const []) id as int},
        soldRecently = ((j['popularity'] as Map?)?['sold_30d'] as int?) ?? 0,
        savedBy = ((j['popularity'] as Map?)?['favorites'] as int?) ?? 0,
        modelName = j['model_name'] as String?,
        everOnSale = (j['ever_on_sale'] as bool?) ?? false;

  final int id;
  final String status;

  /// Owner view only: once on sale the shoe itself (brand, model, category, photos) is fixed for good.
  final bool everOnSale;
  final String title;
  final String category;
  final String? brand;
  final String? modelName;
  final String color;
  final int priceTiyn;

  /// The price before the seller's recent cut, shown crossed out; null when there is no sale.
  final int? wasPriceTiyn;
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

  /// Set while the seller is on holiday: no orders or offers until then.
  final DateTime? sellerAwayUntil;

  /// What buyers of this model said about the size; only on the product page, and only with enough answers.
  final SizeFit? sizeFit;

  /// Sold-out sizes the signed-in buyer asked to hear about when they are back.
  final Set<int> stockAlerts;

  /// Pairs bought in the last 30 days and people who saved it; 0 when the server says nothing worth showing.
  final int soldRecently;
  final int savedBy;
  final double? sellerRating;
  final int sellerReviews;

  /// Only on the seller's own listings.
  final ListingStats? stats;
  final Promo? promo;
  final Moderation? moderation;

  /// 360° frames in upload order: real photos only, nothing generated in between.
  List<MediaItem> get frames => media.where((m) => m.angle == 'frame').toList();
  List<MediaItem> get photos => media.where((m) => m.angle != 'frame').toList();
  String? get coverUrl => (photos.isNotEmpty ? photos : media).firstOrNull?.url;
}

/// Where an order goes. The seller gets it only after the buyer pays.
class Delivery {
  const Delivery(
      {required this.recipientName,
      required this.recipientPhone,
      required this.city,
      required this.address,
      this.note});
  Delivery.fromJson(Map<String, dynamic> j)
      : recipientName = j['recipient_name'] as String,
        recipientPhone = j['recipient_phone'] as String,
        city = j['city'] as String,
        address = j['address'] as String,
        note = j['note'] as String?;
  final String recipientName;
  final String recipientPhone;
  final String city;
  final String address;
  final String? note;

  Map<String, dynamic> toJson() => {
        'recipient_name': recipientName,
        'recipient_phone': recipientPhone,
        'city': city,
        'address': address,
        if (note != null && note!.isNotEmpty) 'note': note,
      };
}

/// A listing's proof of authenticity as its seller sees it; the photos are never shown to buyers.
/// Someone this user blocked.
class BlockedUser {
  BlockedUser.fromJson(Map<String, dynamic> j)
      : userId = j['user_id'] as int,
        name = j['name'] as String,
        since = DateTime.parse(j['since'] as String).toLocal();
  final int userId;
  final String name;
  final DateTime since;
}

/// A public question on a listing and the seller's answer.
class Question {
  Question.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        text = j['text'] as String,
        answer = j['answer'] as String?,
        askedAt = DateTime.parse(j['asked_at'] as String).toLocal(),
        mine = j['mine'] as bool;
  final int id;
  final String text;
  final String? answer;
  final DateTime askedAt;
  final bool mine;
}

/// A seller's discount code, as the seller sees it.
class PromoCode {
  PromoCode.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        code = j['code'] as String,
        percent = j['percent'] as int?,
        amountTiyn = j['amount_tiyn'] as int?,
        minPriceTiyn = j['min_price_tiyn'] as int,
        maxUses = j['max_uses'] as int?,
        endsOn = j['ends_on'] == null ? null : DateTime.parse(j['ends_on'] as String),
        uses = j['uses'] as int,
        active = j['active'] as bool;
  final int id;
  final String code;
  final int? percent;
  final int? amountTiyn;
  final int minPriceTiyn;
  final int? maxUses;
  final DateTime? endsOn;
  final int uses;
  final bool active;
}

/// What the buyer pays with a code, before ordering.
class PromoPreview {
  PromoPreview.fromJson(Map<String, dynamic> j)
      : code = j['code'] as String,
        discountTiyn = j['discount_tiyn'] as int,
        itemPriceTiyn = j['item_price_tiyn'] as int,
        totalTiyn = j['total_tiyn'] as int;
  final String code;
  final int discountTiyn;
  final int itemPriceTiyn;
  final int totalTiyn;
}

class Proofs {
  Proofs.fromJson(Map<String, dynamic> j)
      : authenticity = j['authenticity'] as String,
        note = j['note'] as String?,
        items = [
          for (final p in j['proofs'] as List) (id: (p as Map)['id'] as int, url: p['url'] as String),
        ];
  final String authenticity;

  /// Why staff did not accept the proof, when they did not.
  final String? note;
  final List<({int id, String url})> items;
}

/// A brand or model on sale now that starts with what the buyer is typing.
class SearchSuggestion {
  SearchSuggestion.fromJson(Map<String, dynamic> j)
      : text = j['text'] as String,
        kind = j['kind'] as String,
        count = j['count'] as int;
  final String text;
  final String kind; // "brand" or "model"
  final int count;
}

class OrderInfo {
  OrderInfo.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        status = j['status'] as String,
        listingId = j['listing_id'] as int,
        buyerId = j['buyer_id'] as int,
        sellerId = j['seller_id'] as int,
        totalTiyn = j['total_tiyn'] as int,
        itemPriceTiyn = (j['item_price_tiyn'] as int?) ?? j['total_tiyn'] as int,
        deliveryPriceTiyn = (j['delivery_price_tiyn'] as int?) ?? 0,
        sellerName = j['seller_name'] as String?,
        createdAt = j['created_at'] == null ? null : DateTime.parse(j['created_at'] as String).toLocal(),
        trackingNumber = j['tracking_number'] as String?,
        promoCode = j['promo_code'] as String?,
        promoDiscountTiyn = (j['promo_discount_tiyn'] as int?) ?? 0,
        listingTitle = j['listing_title'] as String?,
        reviewed = (j['reviewed'] as bool?) ?? false,
        listingCover = j['listing_cover'] as String?,
        sizeLabel = j['size_label'] as String?,
        sizeCm = j['size_cm'] as String?,
        delivery = j['delivery'] == null ? null : Delivery.fromJson(j['delivery'] as Map<String, dynamic>),
        deadline = j['deadline'] == null ? null : DateTime.parse(j['deadline'] as String).toLocal(),
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
  final int itemPriceTiyn;
  final int deliveryPriceTiyn;
  final String? sellerName;
  final DateTime? createdAt;
  final String? trackingNumber;
  final String? promoCode;
  final int promoDiscountTiyn;
  final String? listingTitle;
  final bool reviewed;
  final String? listingCover;
  final String? sizeLabel;
  final String? sizeCm;

  /// Null for the seller until the order is paid.
  final Delivery? delivery;

  /// When the order cancels itself (unpaid) or refunds itself (seller silent), if nobody acts first.
  final DateTime? deadline;
  final List<({String status, DateTime at})> history;
}

class Me {
  Me.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        phone = j['phone'] as String,
        displayName = j['display_name'] as String?,
        city = j['city'] as String?,
        isSeller = j['is_seller'] as bool,
        shopName = j['shop_name'] as String?,
        awayUntil = j['away_until'] == null ? null : DateTime.parse(j['away_until'] as String),
        lastDelivery =
            j['last_delivery'] == null ? null : Delivery.fromJson(j['last_delivery'] as Map<String, dynamic>),
        shopAbout = j['shop_about'] as String?;
  final int id;
  final String? shopAbout;
  final String phone;
  final String? displayName;
  final String? city;
  final bool isSeller;
  final String? shopName;

  /// Last day of the seller's holiday, while it lasts.
  final DateTime? awayUntil;

  /// The address of the last order, to fill the next one in.
  final Delivery? lastDelivery;
}

class ChatMessage {
  ChatMessage.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        senderId = j['sender_id'] as int,
        body = j['body'] as String,
        photoUrl = j['photo_url'] as String?,
        contactWarning = j['contact_warning'] as bool,
        createdAt = DateTime.parse(j['created_at'] as String).toLocal();
  final int id;
  final int senderId;
  final String body;
  final String? photoUrl;
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
        unread = j['unread'] as int,
        sellerAwayUntil = j['seller_away_until'] == null ? null : DateTime.parse(j['seller_away_until'] as String);
  final int id;
  final int listingId;
  final String listingTitle;
  final String? listingCover;
  final int priceTiyn;
  final String role;
  final String otherName;
  final ChatMessage? lastMessage;
  final int unread;

  /// The seller's last holiday day while it lasts.
  final DateTime? sellerAwayUntil;
}

/// How buyers said a model's size felt, from their reviews.
class SizeFit {
  SizeFit.fromJson(Map<String, dynamic> j)
      : answers = j['answers'] as int,
        small = j['small'] as int,
        trueToSize = j['true'] as int,
        large = j['large'] as int;
  final int answers;
  final int small;
  final int trueToSize;
  final int large;

  /// "small", "large" or "true": a side wins only with at least 40% of answers and more than the other side.
  String get verdict {
    if (small * 5 >= answers * 2 && small > large) return 'small';
    if (large * 5 >= answers * 2 && large > small) return 'large';
    return 'true';
  }
}

class Review {
  Review.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        rating = j['rating'] as int,
        text = j['text'] as String?,
        sellerReply = j['seller_reply'] as String?,
        photos = [for (final p in (j['photos'] as List?) ?? const []) p as String],
        fit = j['fit'] as String?,
        buyerName = j['buyer_name'] as String,
        createdAt = DateTime.parse(j['created_at'] as String).toLocal();
  final int id;
  final int rating;
  final String? text;
  final String? sellerReply;

  /// The buyer's own photos of the pair that arrived.
  final List<String> photos;

  /// "small", "true" or "large" when the buyer said how the size felt.
  final String? fit;
  final String buyerName;
  final DateTime createdAt;
}

class AppNotification {
  AppNotification.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        kind = j['kind'] as String,
        text = j['text'] as String,
        textRu = j['text_ru'] as String?,
        textEn = j['text_en'] as String?,
        orderId = j['order_id'] as int?,
        conversationId = j['conversation_id'] as int?,
        listingId = j['listing_id'] as int?,
        read = j['read'] as bool,
        createdAt = DateTime.parse(j['created_at'] as String).toLocal();
  final int id;
  final String kind;
  final String text;
  final String? textRu;
  final String? textEn;

  /// The notice in the interface language.
  String get shown => pick(text, textRu, textEn);
  final int? orderId;
  final int? conversationId;
  final int? listingId;
  final bool read;
  final DateTime createdAt;
}

class Api {
  Api({http.Client? client, this.base = apiBase}) : _client = client ?? http.Client();
  final http.Client _client;
  final String base;
  String? token;

  /// How long one request may take before the app gives up and says so; uploads carry photos and get longer.
  static const timeout = Duration(seconds: 20);
  static const uploadTimeout = Duration(seconds: 60);

  static const _offlineText = 'Байланыс жоқ. Интернетті тексеріп, қайталап көріңіз.';
  static const _brokenText = 'Сервер уақытша жауап бермей тұр. Біраз кейін қайталап көріңіз.';

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
    return _decode(await _fetch(req));
  }

  /// Sends one request and reads the whole answer within [limit]. A dropped connection, an unreachable host or a
  /// request that hangs all end as an [ApiException] with a message for people, never as a raw socket error.
  Future<http.Response> _fetch(http.BaseRequest req, {Duration limit = timeout}) async {
    try {
      return await (() async => http.Response.fromStream(await _client.send(req)))().timeout(limit);
    } on TimeoutException {
      throw ApiException.local(0, 'timeout', _offlineText);
    } on ApiException {
      rethrow;
    } on Exception {
      // http.ClientException, SocketException on mobile, XMLHttpRequest errors on the web.
      throw ApiException.local(0, 'network', _offlineText);
    }
  }

  Future<dynamic> _upload(http.MultipartRequest req) async => _decode(await _fetch(req, limit: uploadTimeout));

  /// A file the server streams back (CSV, PDF): its bytes, or the server's error.
  Future<List<int>> _bytes(String path, {Map<String, String>? query}) async {
    final req = http.Request('GET', Uri.parse('$base$path').replace(queryParameters: query))
      ..headers.addAll({if (token != null) 'Authorization': 'Bearer $token'});
    final res = await _fetch(req, limit: uploadTimeout);
    if (res.statusCode >= 400) _decode(res); // throws the server's error
    return res.bodyBytes;
  }

  static dynamic _decode(http.Response res) {
    Object? data;
    try {
      data = res.bodyBytes.isEmpty ? null : jsonDecode(utf8.decode(res.bodyBytes));
    } on FormatException {
      // A proxy's HTML page or a bare "Internal Server Error": nothing the screens can show as it is.
      throw ApiException.local(res.statusCode, 'unavailable', _brokenText);
    }
    if (res.statusCode >= 400) {
      final m = data is Map ? data : const {};
      if (m['message_kk'] is! String) {
        final detail = m['detail'] is String ? m['detail'] as String : null;
        throw res.statusCode >= 500
            ? ApiException.local(res.statusCode, (m['code'] as String?) ?? 'unavailable', _brokenText, detail)
            : ApiException.local(res.statusCode, (m['code'] as String?) ?? 'error', 'Қате.', detail);
      }
      throw ApiException(res.statusCode, (m['code'] ?? 'error') as String, m['message_kk'] as String,
          m['detail'] as String?, m['message_ru'] as String?, m['message_en'] as String?);
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

  Future<Me> setAway(DateTime? until) async => Me.fromJson(await _send('PUT', '/me/away', body: {
        'until': until == null
            ? null
            : '${until.year}-${until.month.toString().padLeft(2, '0')}-${until.day.toString().padLeft(2, '0')}'
      }) as Map<String, dynamic>);

  /// Optional alert kinds and whether each is on.
  Future<Map<String, bool>> notificationSettings() async {
    final r = await _send('GET', '/me/notification-settings') as Map;
    return {for (final i in r['items'] as List) (i as Map)['kind'] as String: i['on'] as bool};
  }

  Future<Map<String, bool>> setNotificationSetting(String kind, bool on) async {
    final r = await _send('PUT', '/me/notification-settings', body: {kind: on}) as Map;
    return {for (final i in r['items'] as List) (i as Map)['kind'] as String: i['on'] as bool};
  }

  /// Deletes the account for good; refused while an order is still open.
  Future<void> deleteAccount() => _send('DELETE', '/me');

  /// The same percent off every listing on sale; returns how many changed.
  Future<int> startShopSale(int percent) async =>
      ((await _send('POST', '/me/shop-sale', body: {'percent': percent}) as Map)['changed'] as int);

  /// Puts back the crossed-out price everywhere it still shows; returns how many changed.
  Future<int> endShopSale() async => ((await _send('DELETE', '/me/shop-sale') as Map)['changed'] as int);

  /// Null or blank clears it.
  Future<Me> setShopAbout(String? text) async =>
      Me.fromJson(await _send('PUT', '/me/shop-about', body: {'text': text}) as Map<String, dynamic>);

  Future<Me> becomeSeller(String shopName, String city) async => Me.fromJson(
      await _send('POST', '/me/seller', body: {'shop_name': shopName, 'city': city}) as Map<String, dynamic>);

  // selling
  /// Uploads one photo; the server strips metadata and returns the URL to reference in a listing.
  Future<String> uploadPhoto(List<int> bytes, String filename) async {
    final req = http.MultipartRequest('POST', Uri.parse('$base/media'))
      ..headers.addAll({'Accept': 'application/json', if (token != null) 'Authorization': 'Bearer $token'})
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    final data = await _upload(req);
    return (data as Map)['url'] as String;
  }

  /// Listings that look like the photo, most similar first. The photo is not stored on the server.
  Future<List<Listing>> searchByImage(List<int> bytes, String filename) async {
    final req = http.MultipartRequest('POST', Uri.parse('$base/search/image'))
      ..headers['Accept'] = 'application/json'
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    final data = await _upload(req) as Map;
    return [for (final j in data['items'] as List) Listing.fromJson(j as Map<String, dynamic>)];
  }

  Future<Listing> createListing(Map<String, dynamic> body) async =>
      Listing.fromJson(await _send('POST', '/listings', body: body) as Map<String, dynamic>);

  Future<Listing> publishListing(int id) async =>
      Listing.fromJson(await _send('POST', '/listings/$id/publish') as Map<String, dynamic>);

  /// Photos are `{'url': ..., 'angle': ...}`. [photos] replaces the whole set and only works before the listing
  /// was ever on sale; [addPhotos] and [addSizes] work on any listing the seller still controls.
  Future<Listing> editListing(int id,
          {int? priceTiyn,
          int? deliveryPriceTiyn,
          String? description,
          String? defects,
          Map<int, int>? stock,
          String? title,
          String? brand,
          String? modelName,
          String? color,
          String? category,
          String? condition,
          List<Map<String, String>>? photos,
          List<Map<String, String>>? addPhotos,
          List<Map<String, Object>>? addSizes}) async =>
      Listing.fromJson(await _send('PATCH', '/listings/$id', body: {
        if (priceTiyn != null) 'price_tiyn': priceTiyn,
        if (deliveryPriceTiyn != null) 'delivery_price_tiyn': deliveryPriceTiyn,
        if (description != null) 'description': description,
        if (defects != null) 'defects': defects,
        if (stock != null)
          'sizes': [
            for (final e in stock.entries) {'id': e.key, 'quantity': e.value}
          ],
        if (title != null) 'title': title,
        if (brand != null) 'brand': brand,
        if (modelName != null) 'model_name': modelName,
        if (color != null) 'color': color,
        if (category != null) 'category': category,
        if (condition != null) 'condition': condition,
        if (photos != null) 'photos': photos,
        if (addPhotos != null) 'add_photos': addPhotos,
        if (addSizes != null) 'add_sizes': addSizes,
      }) as Map<String, dynamic>);

  Future<Suggestion> suggestDetails(String photoUrl) async => Suggestion.fromJson(
      await _send('POST', '/listings/suggest', body: {'photo_url': photoUrl}) as Map<String, dynamic>);

  /// Starts rendering the promo video; poll [listing] until promo.state is no longer "rendering".
  Future<Listing> makePromo(int id, String lang) async =>
      Listing.fromJson(await _send('POST', '/listings/$id/promo', body: {'lang': lang}) as Map<String, dynamic>);

  Future<Listing> pauseListing(int id) async =>
      Listing.fromJson(await _send('POST', '/listings/$id/pause') as Map<String, dynamic>);

  Future<Analytics> analytics({int days = 14}) async =>
      Analytics.fromJson(await _send('GET', '/me/analytics', query: {'days': '$days'}) as Map<String, dynamic>);

  /// Counts of what waits on the signed-in person; seller keys appear only for sellers.
  Future<Map<String, int>> todo() async =>
      (await _send('GET', '/me/todo') as Map).map((k, v) => MapEntry(k as String, v as int));

  /// Null estimate when the city is unknown; [cities] are the ones an estimate can be made for.
  Future<(DeliveryEstimate?, List<String>)> deliveryEstimate(int listingId, {String? city}) async {
    final r = await _send('GET', '/listings/$listingId/delivery-estimate', query: city == null ? null : {'city': city})
        as Map<String, dynamic>;
    final e = r['estimate'];
    return (
      e == null ? null : DeliveryEstimate.fromJson(e as Map<String, dynamic>),
      [for (final c in r['cities'] as List) c as String],
    );
  }

  Future<Payouts> payouts() async => Payouts.fromJson(await _send('GET', '/me/payouts') as Map<String, dynamic>);

  Future<PayoutAccount?> payoutAccount() async {
    final a = (await _send('GET', '/me/payout-account') as Map)['account'];
    return a == null ? null : PayoutAccount.fromJson(a as Map<String, dynamic>);
  }

  Future<PayoutAccount> setPayoutAccount(
          {required String holderName, required String iban, required String taxId}) async =>
      PayoutAccount.fromJson(
          (await _send('PUT', '/me/payout-account', body: {'holder_name': holderName, 'iban': iban, 'tax_id': taxId})
              as Map)['account'] as Map<String, dynamic>);

  /// Asks for everything owed; support sends it by bank transfer.
  Future<PayoutInfo> requestPayout() async =>
      PayoutInfo.fromJson(await _send('POST', '/me/payouts', body: const {}) as Map<String, dynamic>);

  Future<Earnings> earnings() async => Earnings.fromJson(await _send('GET', '/me/earnings') as Map<String, dynamic>);

  Future<List<Listing>> myListings() async {
    final r = await _send('GET', '/me/listings') as Map;
    return [for (final j in r['items'] as List) Listing.fromJson(j as Map<String, dynamic>)];
  }

  // catalog
  Future<List<Listing>> search(
      {String? q,
      String? sizeCm,
      String? category,
      CatalogFilter filter = const CatalogFilter(),
      int? sellerId,
      bool sale = false,
      int offset = 0,
      int limit = 20}) async {
    final r = await _send('GET', '/listings', query: {
      if (sale) 'sale': 'true',
      if (offset > 0) 'offset': '$offset',
      if (limit != 20) 'limit': '$limit',
      if (q != null && q.isNotEmpty) 'q': q,
      if (sizeCm != null && sizeCm.isNotEmpty) 'size_cm': sizeCm,
      if (category != null) 'category': category,
      if (sellerId != null) 'seller_id': '$sellerId',
      ...filter.query,
    }) as Map;
    lastDidYouMean = r['did_you_mean'] as String?;
    return [for (final j in r['items'] as List) Listing.fromJson(j as Map<String, dynamic>)];
  }

  /// After a text search that found nothing: the nearest spelling that finds something, if any.
  String? lastDidYouMean;

  Future<List<Listing>> similar(int id) async {
    final r = await _send('GET', '/listings/$id/similar') as Map;
    return [for (final j in r['items'] as List) Listing.fromJson(j as Map<String, dynamic>)];
  }

  /// Asks to be told (or stops asking) when a sold-out size can be ordered again.
  Future<void> setStockAlert(int listingId, int sizeId, bool on) =>
      _send(on ? 'PUT' : 'DELETE', '/listings/$listingId/sizes/$sizeId/alert');

  Future<List<SearchSuggestion>> suggest(String q) async {
    final r = await _send('GET', '/search/suggest?q=${Uri.encodeQueryComponent(q)}') as Map;
    return [for (final j in r['items'] as List) SearchSuggestion.fromJson(j as Map<String, dynamic>)];
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
  Future<OrderInfo> createOrder(int listingId, int sizeId, String idempotencyKey,
          {required Delivery delivery, int? offerId, String? promoCode}) async =>
      OrderInfo.fromJson(await _send('POST', '/orders', body: {
        'listing_id': listingId,
        'size_id': sizeId,
        'delivery': delivery.toJson(),
        if (offerId != null) 'offer_id': offerId,
        if (promoCode != null) 'promo_code': promoCode,
      }, headers: {
        'Idempotency-Key': idempotencyKey
      }) as Map<String, dynamic>);

  Future<SavedSearch> saveSearch(Map<String, Object> body) async =>
      SavedSearch.fromJson(await _send('POST', '/saved-searches', body: body) as Map<String, dynamic>);

  Future<List<SavedSearch>> savedSearches() async {
    final r = await _send('GET', '/saved-searches') as Map;
    return [for (final j in r['items'] as List) SavedSearch.fromJson(j as Map<String, dynamic>)];
  }

  Future<void> deleteSavedSearch(int id) => _send('DELETE', '/saved-searches/$id');

  Future<Offer> makeOffer(int listingId, int sizeId, int amountTiyn) async => Offer.fromJson(
      await _send('POST', '/listings/$listingId/offers', body: {'size_id': sizeId, 'amount_tiyn': amountTiyn})
          as Map<String, dynamic>);

  Future<List<Offer>> offers({String role = 'buyer', int? listingId}) async {
    final r =
        await _send('GET', '/offers', query: {'role': role, if (listingId != null) 'listing_id': '$listingId'}) as Map;
    return [for (final j in r['items'] as List) Offer.fromJson(j as Map<String, dynamic>)];
  }

  /// accept | decline | withdraw
  Future<Offer> answerOffer(int id, String action) async =>
      Offer.fromJson(await _send('POST', '/offers/$id/$action') as Map<String, dynamic>);

  Future<Offer> counterOffer(int id, int amountTiyn) async => Offer.fromJson(
      await _send('POST', '/offers/$id/counter', body: {'amount_tiyn': amountTiyn}) as Map<String, dynamic>);

  Future<List<OrderInfo>> orders({String role = 'buyer'}) async {
    final r = await _send('GET', '/orders', query: {'role': role}) as Map;
    return [for (final j in r['items'] as List) OrderInfo.fromJson(j as Map<String, dynamic>)];
  }

  Future<OrderInfo> order(int id) async =>
      OrderInfo.fromJson(await _send('GET', '/orders/$id') as Map<String, dynamic>);

  /// Starts a payment with the provider. Only the provider's signed webhook marks the order paid.
  Future<void> startPayment(int id) => _send('POST', '/orders/$id/pay');

  /// The buyer has the parcel in hand: starts the inspection window, after which the seller is paid.
  Future<OrderInfo> markReceived(int id) => action(id, 'received');

  Future<OrderInfo> action(int id, String action, {String? reason, String? trackingNumber}) async =>
      OrderInfo.fromJson(await _send('POST', '/orders/$id/$action', body: {
        if (reason != null) 'reason': reason,
        if (trackingNumber != null) 'tracking_number': trackingNumber,
      }) as Map<String, dynamic>);

  // chat
  Future<Conversation> openConversation(int listingId) async => Conversation.fromJson(
      await _send('POST', '/conversations', body: {'listing_id': listingId}) as Map<String, dynamic>);

  /// The chat about an order, opened from either side.
  Future<Conversation> orderConversation(int orderId) async =>
      Conversation.fromJson(await _send('POST', '/orders/$orderId/conversation') as Map<String, dynamic>);

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

  /// A photo in the chat, with an optional caption. Cleaned of metadata on the server like any upload.
  Future<ChatMessage> sendChatPhoto(int conversationId, List<int> bytes, String filename, {String caption = ''}) async {
    final req = http.MultipartRequest('POST', Uri.parse('$base/conversations/$conversationId/photos'))
      ..headers.addAll({'Accept': 'application/json', if (token != null) 'Authorization': 'Bearer $token'})
      ..fields['caption'] = caption
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    return ChatMessage.fromJson(await _upload(req) as Map<String, dynamic>);
  }

  // reviews
  Future<Review> review(int orderId, int rating, String? text, {List<String> photos = const [], String? fit}) async =>
      Review.fromJson(await _send('POST', '/orders/$orderId/review', body: {
        'rating': rating,
        if (text != null && text.isNotEmpty) 'text': text,
        if (photos.isNotEmpty) 'photos': photos,
        if (fit != null) 'fit': fit,
      }) as Map<String, dynamic>);

  Future<String> uploadReviewPhoto(int orderId, List<int> bytes, String filename) async {
    final req = http.MultipartRequest('POST', Uri.parse('$base/orders/$orderId/review/photos'))
      ..headers.addAll({'Accept': 'application/json', if (token != null) 'Authorization': 'Bearer $token'})
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    return (await _upload(req) as Map)['url'] as String;
  }

  /// Answered questions for everyone; the asker's own and, for the seller, all of them. [unanswered] is the
  /// seller's to-do count, null for anyone else.
  Future<({List<Question> items, int? unanswered})> questions(int listingId) async {
    final r = await _send('GET', '/listings/$listingId/questions') as Map;
    return (
      items: [for (final j in r['items'] as List) Question.fromJson(j as Map<String, dynamic>)],
      unanswered: r['unanswered'] as int?,
    );
  }

  Future<Question> askQuestion(int listingId, String text) async => Question.fromJson(
      await _send('POST', '/listings/$listingId/questions', body: {'text': text}) as Map<String, dynamic>);

  Future<Question> answerQuestion(int id, String text) async =>
      Question.fromJson(await _send('POST', '/questions/$id/answer', body: {'text': text}) as Map<String, dynamic>);

  Future<void> hideQuestion(int id) => _send('DELETE', '/questions/$id');

  /// Blocks the other side of a chat: no messages, offers, questions or orders between the two.
  Future<void> blockInChat(int conversationId) => _send('POST', '/conversations/$conversationId/block');

  Future<List<BlockedUser>> blockedUsers() async {
    final r = await _send('GET', '/me/blocks') as Map;
    return [for (final j in r['items'] as List) BlockedUser.fromJson(j as Map<String, dynamic>)];
  }

  Future<void> unblock(int userId) => _send('DELETE', '/me/blocks/$userId');

  Future<PromoPreview> checkPromo(int listingId, String code) async => PromoPreview.fromJson(
      await _send('GET', '/listings/$listingId/promo', query: {'code': code}) as Map<String, dynamic>);

  Future<List<PromoCode>> promoCodes() async {
    final r = await _send('GET', '/me/promo-codes') as Map;
    return [for (final j in r['items'] as List) PromoCode.fromJson(j as Map<String, dynamic>)];
  }

  Future<PromoCode> createPromoCode(Map<String, Object> body) async =>
      PromoCode.fromJson(await _send('POST', '/me/promo-codes', body: body) as Map<String, dynamic>);

  Future<void> endPromoCode(int id) => _send('DELETE', '/me/promo-codes/$id');

  /// The seller's orders of the last [days] days as a spreadsheet file (semicolon CSV with a BOM).
  Future<List<int>> salesCsv({int days = 90}) => _bytes('/me/sales.csv', query: {'days': '$days'});

  /// The A6 packing slip for a paid order, as PDF bytes; only the seller can get it.
  Future<List<int>> packingSlip(int orderId) => _bytes('/orders/$orderId/slip.pdf');

  Future<Proofs> proofs(int listingId) async =>
      Proofs.fromJson(await _send('GET', '/listings/$listingId/proofs') as Map<String, dynamic>);

  Future<Proofs> addProof(int listingId, List<int> bytes, String filename) async {
    final req = http.MultipartRequest('POST', Uri.parse('$base/listings/$listingId/proofs'))
      ..headers.addAll({'Accept': 'application/json', if (token != null) 'Authorization': 'Bearer $token'})
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    return Proofs.fromJson(await _upload(req) as Map<String, dynamic>);
  }

  Future<Proofs> deleteProof(int listingId, int proofId) async =>
      Proofs.fromJson(await _send('DELETE', '/listings/$listingId/proofs/$proofId') as Map<String, dynamic>);

  Future<void> reportListing(int id, String reason, {String? text}) => _send('POST', '/listings/$id/report',
      body: {'reason': reason, if (text != null && text.isNotEmpty) 'text': text});

  Future<Shop> shop(int sellerId) async =>
      Shop.fromJson(await _send('GET', '/sellers/$sellerId') as Map<String, dynamic>);

  /// Follows or unfollows a shop; returns whether the user follows it now and its follower count.
  Future<(bool, int)> setFollowing(int sellerId, bool follow) async {
    final r = await _send(follow ? 'PUT' : 'DELETE', '/sellers/$sellerId/follow') as Map;
    return (r['following'] as bool, r['followers'] as int);
  }

  Future<List<FollowedShop>> following() async {
    final r = await _send('GET', '/me/following') as Map;
    return [for (final j in r['items'] as List) FollowedShop.fromJson(j as Map<String, dynamic>)];
  }

  Future<Review> replyToReview(int reviewId, String text) async =>
      Review.fromJson(await _send('POST', '/reviews/$reviewId/reply', body: {'text': text}) as Map<String, dynamic>);

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
