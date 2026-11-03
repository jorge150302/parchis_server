/// Catalog and ownership of cosmetic items (dice skins, boards).
///
/// This is the seed for paid items: today every catalog item is free and
/// owned by default. A purchase provider (Google Play billing, verified
/// server-side) only needs to call [EntitlementService.grant] after verifying
/// a purchase, and [EntitlementService.revoke] on a refund.
library;

import 'package:google_cloud_firestore/google_cloud_firestore.dart';

enum ItemType { dice, board }

class CatalogItem {
  const CatalogItem(this.id, this.type, {this.free = false, this.priceCents});

  final String id;
  final ItemType type;

  /// Owned by every account without a grant.
  final bool free;

  /// Unused until payments exist; kept so prices live with the catalog.
  final int? priceCents;
}

const defaultDiceSkin = 'dice_classic';
const defaultBoard = 'board_classic';

const defaultCatalog = <CatalogItem>[
  CatalogItem(defaultDiceSkin, ItemType.dice, free: true),
  CatalogItem(defaultBoard, ItemType.board, free: true),
];

/// Where grants are stored. Only the server writes it.
abstract class EntitlementStore {
  Future<Set<String>> owned(String uid);
  Future<void> grant(String uid, String itemId, {required String source});
  Future<void> revoke(String uid, String itemId);
}

/// `users/{uid}/inventory/{itemId}`; clients may read it, never write it
/// (see firebase/firestore.rules).
class FirestoreEntitlementStore implements EntitlementStore {
  FirestoreEntitlementStore(this._db);
  final Firestore _db;

  CollectionReference<Map<String, dynamic>> _inventory(String uid) =>
      _db.collection('users').doc(uid).collection('inventory');

  @override
  Future<Set<String>> owned(String uid) async =>
      (await _inventory(uid).get()).docs.map((d) => d.id).toSet();

  @override
  Future<void> grant(String uid, String itemId, {required String source}) =>
      _inventory(uid)
          .doc(itemId)
          .set({'source': source, 'granted_at': Timestamp.now()});

  @override
  Future<void> revoke(String uid, String itemId) =>
      _inventory(uid).doc(itemId).delete();
}

/// In-memory store for tests and for servers without Firebase.
class MemoryEntitlementStore implements EntitlementStore {
  final _owned = <String, Set<String>>{};

  @override
  Future<Set<String>> owned(String uid) async => {...?_owned[uid]};

  @override
  Future<void> grant(String uid, String itemId, {required String source}) async =>
      (_owned[uid] ??= {}).add(itemId);

  @override
  Future<void> revoke(String uid, String itemId) async =>
      _owned[uid]?.remove(itemId);
}

class EntitlementService {
  EntitlementService(this._store, {List<CatalogItem> catalog = defaultCatalog})
      : _catalog = {for (final item in catalog) item.id: item};

  final EntitlementStore _store;
  final Map<String, CatalogItem> _catalog;

  CatalogItem? item(String id) => _catalog[id];

  /// Whether [uid] may use [itemId]. Free items are owned by everyone,
  /// including guests (`uid == null`); unknown items by no one.
  Future<bool> owns(String? uid, String itemId) async {
    final item = _catalog[itemId];
    if (item == null) return false;
    if (item.free) return true;
    if (uid == null) return false;
    return (await _store.owned(uid)).contains(itemId);
  }

  /// The dice skin [uid] will actually play with: the [requested] one if they
  /// own it, otherwise the default.
  Future<String> resolveDiceSkin(String? uid, Object? requested) async {
    if (requested is! String) return defaultDiceSkin;
    final item = _catalog[requested];
    if (item == null || item.type != ItemType.dice) return defaultDiceSkin;
    return await owns(uid, requested) ? requested : defaultDiceSkin;
  }

  /// Gives [uid] an item, e.g. after a verified purchase ([source]
  /// 'purchase:<orderId>') or a promotion. Throws on unknown items.
  Future<void> grant(String uid, String itemId, {required String source}) {
    if (!_catalog.containsKey(itemId)) {
      throw ArgumentError.value(itemId, 'itemId', 'not in the catalog');
    }
    return _store.grant(uid, itemId, source: source);
  }

  /// Takes an item back, e.g. after a refund.
  Future<void> revoke(String uid, String itemId) => _store.revoke(uid, itemId);
}
