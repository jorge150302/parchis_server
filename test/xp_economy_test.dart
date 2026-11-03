import 'package:google_cloud_firestore/google_cloud_firestore.dart';
import 'package:parchis_server/match_results.dart';
import 'package:parchis_server/xp_receipts.dart';
import 'package:test/test.dart';

final _now = DateTime.utc(2026, 11, 2, 12);

Map<String, Object?> _receipt(
  String id, {
  int xp = 30,
  bool online = false,
  bool match = true,
  bool win = false,
  int captures = 0,
  DateTime? at,
}) =>
    {
      'id': id,
      'xp': xp,
      'is_online': online,
      'match': match,
      'win': win,
      'captures': captures,
      'timestamp': (at ?? _now.subtract(const Duration(minutes: 5)))
          .toIso8601String(),
    };

ReceiptBatch _validate(
  List<Object?> receipts, {
  Set<String> processed = const {},
  DailyUsage today = const DailyUsage(),
}) =>
    validateReceipts(receipts,
        now: _now, alreadyProcessed: processed, today: today);

void main() {
  group('levels', () {
    test('match the client table', () {
      expect(levelForXp(0), 1);
      expect(levelForXp(99), 1);
      expect(levelForXp(100), 2);
      // 8 levels of 100 reach level 9, then 150 per level.
      expect(levelForXp(800), 9);
      expect(levelForXp(949), 9);
      expect(levelForXp(950), 10);
      expect(levelForXp(1 << 30), 100);
    });
  });

  group('onlineMatchXp', () {
    test('uses the medium-difficulty table', () {
      expect(onlineMatchXp(position: 0, totalPlayers: 2), 60);
      expect(onlineMatchXp(position: 1, totalPlayers: 2), 10);
      expect(onlineMatchXp(position: 0, totalPlayers: 3), 80);
      expect(onlineMatchXp(position: 0, totalPlayers: 4), 100);
      expect(onlineMatchXp(position: 3, totalPlayers: 4), 0);
    });

    test('is 0 for impossible ranks or table sizes', () {
      expect(onlineMatchXp(position: 2, totalPlayers: 2), 0);
      expect(onlineMatchXp(position: -1, totalPlayers: 4), 0);
      expect(onlineMatchXp(position: 0, totalPlayers: 5), 0);
    });
  });

  group('MatchResult', () {
    test('winner gets XP, a win and a played match', () {
      final r = MatchResult(
          uid: 'u', matchId: 'm', position: 0, totalPlayers: 4, captures: 3);
      final update = r.profileUpdate(90);
      expect(r.xp, 100);
      expect(update['xp'], 190);
      expect(update['level'], levelForXp(190));
      expect(update.containsKey('wins'), isTrue);
      expect(update['active_match_id'], isNull);
      expect(update.containsKey('active_match_id'), isTrue);
    });

    test('surrender counts as played with no XP and no win', () {
      final r = MatchResult(
          uid: 'u', matchId: 'm', totalPlayers: 2, captures: 1);
      final update = r.profileUpdate(500);
      expect(r.xp, 0);
      expect(update['xp'], 500);
      expect(update.containsKey('wins'), isFalse);
      expect(update['matches_played'], isA<FieldValue>());
    });
  });

  group('validateReceipts', () {
    test('accepts a valid offline match receipt with its stats', () {
      final b = _validate([_receipt('a', xp: 40, win: true, captures: 2)]);
      expect(b.acceptedIds, ['a']);
      expect(b.xp, 40);
      expect(b.matches, 1);
      expect(b.wins, 1);
      expect(b.captures, 2);
    });

    test('rejects ids already processed by an earlier request', () {
      final b = _validate([_receipt('a')], processed: {'a'});
      expect(b.isEmpty, isTrue);
      expect(b.rejected.single, contains('duplicate'));
    });

    test('rejects duplicates inside one request', () {
      final b = _validate([_receipt('a'), _receipt('a')]);
      expect(b.acceptedIds, ['a']);
      expect(b.rejected.single, contains('duplicate'));
    });

    test('ignores online receipts (the server credits those itself)', () {
      final b = _validate([_receipt('a', online: true, xp: 60)]);
      expect(b.isEmpty, isTrue);
      expect(b.rejected.single, contains('online'));
    });

    test('rejects stale, oversized, negative and malformed receipts', () {
      final b = _validate([
        _receipt('old', at: _now.subtract(const Duration(days: 8))),
        _receipt('big', xp: 76),
        _receipt('neg', xp: -5),
        _receipt('cap', captures: 21),
        'not a map',
        {'id': 'noxp'},
      ]);
      expect(b.isEmpty, isTrue);
      expect(b.rejected, hasLength(6));
    });

    test('zero-XP receipts only count when they carry a match', () {
      expect(_validate([_receipt('a', xp: 0)]).matches, 1);
      expect(_validate([_receipt('b', xp: 0, match: false)]).isEmpty, isTrue);
    });

    test('XP beyond the daily cap is dropped but the receipt is consumed', () {
      final b = _validate(
        [_receipt('a', xp: 75), _receipt('b', xp: 75)],
        today: const DailyUsage(xp: maxOfflineXpPerDay - 50),
      );
      expect(b.acceptedIds, ['a', 'b']);
      expect(b.xp, 50);
      expect(b.matches, 2);
    });

    test('match stats stop at the daily match cap', () {
      final b = _validate(
        [_receipt('a'), _receipt('b')],
        today: const DailyUsage(matches: maxOfflineMatchesPerDay - 1),
      );
      expect(b.acceptedIds, ['a']);
      expect(b.rejected.single, contains('daily match cap'));
    });

    test('a replay of 20 max receipts is bounded by the daily cap', () {
      final receipts = [for (var i = 0; i < 20; i++) _receipt('r$i', xp: 75)];
      expect(_validate(receipts).xp, maxOfflineXpPerDay);
    });
  });

  test('utcDay keys counters by UTC date', () {
    expect(utcDay(DateTime.utc(2026, 11, 2, 23, 59)), '2026-11-02');
  });
}
