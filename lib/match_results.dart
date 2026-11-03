import 'package:google_cloud_firestore/google_cloud_firestore.dart';

/// XP needed to go from [level] to the next one. Must match the client's
/// `LevelManager.xpRequiredForLevel`.
int xpForLevel(int level) {
  if (level >= 91) return 1000;
  if (level >= 66) return 600;
  if (level >= 41) return 400;
  if (level >= 21) return 250;
  if (level >= 9) return 150;
  return 100;
}

/// Level reached with [totalXp] (1..100).
int levelForXp(int totalXp) {
  var level = 1;
  var remaining = totalXp;
  while (level < 100) {
    final req = xpForLevel(level);
    if (remaining < req) break;
    remaining -= req;
    level++;
  }
  return level;
}

/// XP for finishing at 0-based [position] out of [totalPlayers] in an online
/// match. Same table as the client's `LevelManager.calculateMatchXP` at
/// medium difficulty (online games have no difficulty setting).
int onlineMatchXp({required int position, required int totalPlayers}) {
  const table = {
    2: [60, 10],
    3: [80, 20, 10],
    4: [100, 40, 15, 0],
  };
  final row = table[totalPlayers];
  if (row == null || position < 0 || position >= row.length) return 0;
  return row[position];
}

/// The outcome of one online match for one account, decided by the server.
class MatchResult {
  MatchResult({
    required this.uid,
    required this.matchId,
    required this.totalPlayers,
    required this.captures,
    this.position,
  });

  final String uid;

  /// Unique per room lifetime; used as the idempotency key.
  final String matchId;

  /// 0-based finishing rank, or `null` for a surrender / abandoned match.
  final int? position;
  final int totalPlayers;
  final int captures;

  int get xp => position == null
      ? 0
      : onlineMatchXp(position: position!, totalPlayers: totalPlayers);

  bool get isWin => position == 0;

  /// Fields to merge into the stored user profile given its current [xp].
  Map<String, Object?> profileUpdate(int currentXp) {
    final newXp = currentXp + xp;
    return {
      'xp': newXp,
      'level': levelForXp(newXp),
      'matches_played': FieldValue.increment(1),
      'tokens_capture': FieldValue.increment(captures),
      if (isWin) 'wins': FieldValue.increment(1),
      'active_match_id': null,
      'updated_at': Timestamp.now(),
    };
  }
}

/// Applies [result] to `users/{uid}` exactly once: the result is stored under
/// `users/{uid}/match_results/{matchId}` in the same transaction, so a retry
/// or a second finish notification for the same match is a no-op.
///
/// Returns `true` if the result was applied, `false` if it already was.
Future<bool> recordMatchResult(Firestore db, MatchResult result) {
  final userRef = db.collection('users').doc(result.uid);
  final resultRef = userRef.collection('match_results').doc(result.matchId);
  return db.runTransaction((txn) async {
    final existing = await txn.get(resultRef);
    if (existing.exists) return false;
    final user = await txn.get(userRef);
    final currentXp = (user.data()?['xp'] as num?)?.toInt() ?? 0;
    final update = result.profileUpdate(currentXp);
    if (user.exists) {
      txn.update(userRef, update);
    } else {
      txn.set(userRef, update, options: SetOptions.merge());
    }
    txn.set(resultRef, {
      'position': result.position,
      'total_players': result.totalPlayers,
      'xp': result.xp,
      'captures': result.captures,
      'created_at': Timestamp.now(),
    });
    return true;
  });
}
