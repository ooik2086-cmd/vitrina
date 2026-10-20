import 'package:flutter/painting.dart';

import 'net_image_web.dart' if (dart.library.io) 'net_image_io.dart' as impl;

/// A photo from the network, kept on the phone once fetched: listing photos and 360° frames never change at their
/// address, so opening the app again costs no mobile data for what was already seen. Signed links (receipts, dispute
/// evidence; they carry a query) and the web build fetch as [NetworkImage] does, with nothing kept.
/// [keep] false is for what is someone's own and not for show: chat photos, dispute evidence, authenticity proofs.
/// Some of those still have plain addresses (files from before private storage), and none should outlive a sign-out.
NetworkImage netImage(String url, {bool keep = true}) =>
    keep && cacheable(url) ? impl.keptImage(url) : NetworkImage(url);

/// Only plain public addresses: a link with a query is signed, private and short-lived. Public photos are stored
/// under random key names (backend storage.new_key) and never rewritten, so a kept copy cannot go stale; production
/// refuses photo addresses from anywhere else (VITRINA_ALLOW_EXTERNAL_MEDIA is for development only).
bool cacheable(String url) {
  final uri = Uri.tryParse(url);
  return uri != null && (uri.scheme == 'https' || uri.scheme == 'http') && !uri.hasQuery && !uri.hasFragment;
}
