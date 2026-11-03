/// Validation of offline XP receipts sent to `POST /xp_sync`.
///
/// Offline games never reach the server, so their results are inherently
/// client-reported. What the server can do is bound them: each receipt is
/// counted once ever (ids are stored), XP per receipt and per day is capped,
/// and match stats per day are capped. Online results are decided by the
/// server itself (see match_results.dart), so online receipts are ignored.
library;

/// Hard mode, 1st of 4, offline: 100 * 1.5 * 0.50.
const maxOfflineXpPerReceipt = 75;

/// Sum of the client's per-difficulty daily caps (150 + 300 + 500).
const maxOfflineXpPerDay = 950;
const maxOfflineMatchesPerDay = 100;
const maxCapturesPerMatch = 20;
const maxReceiptsPerRequest = 20;
const maxReceiptAge = Duration(days: 7);

/// Per-account usage for the current UTC day, as stored on the profile.
class DailyUsage {
  const DailyUsage({this.xp = 0, this.matches = 0});
  final int xp;
  final int matches;
}

class ReceiptBatch {
  final acceptedIds = <String>[];
  final rejected = <String>[];
  var xp = 0;
  var matches = 0;
  var wins = 0;
  var captures = 0;

  bool get isEmpty => acceptedIds.isEmpty;
}

/// `yyyy-mm-dd` of [now] in UTC: the key of the daily counters.
String utcDay(DateTime now) => now.toUtc().toIso8601String().substring(0, 10);

/// Decides which [receipts] count. [alreadyProcessed] holds ids stored by
/// earlier requests; [today] is what this account already used today.
ReceiptBatch validateReceipts(
  List<Object?> receipts, {
  required DateTime now,
  required Set<String> alreadyProcessed,
  required DailyUsage today,
}) {
  final batch = ReceiptBatch();
  final seen = <String>{};

  for (final raw in receipts) {
    if (raw is! Map<String, dynamic>) {
      batch.rejected.add('malformed_receipt');
      continue;
    }
    final id = raw['id'];
    final xp = raw['xp'];
    final timestamp = DateTime.tryParse(raw['timestamp'] as String? ?? '');
    if (id is! String || id.isEmpty || xp is! int) {
      batch.rejected.add('malformed_receipt');
      continue;
    }
    if (!seen.add(id) || alreadyProcessed.contains(id)) {
      batch.rejected.add('$id (duplicate)');
      continue;
    }
    if (raw['is_online'] == true) {
      // Old clients still send these; the server already credited the match.
      batch.rejected.add('$id (online: credited by server)');
      continue;
    }
    if (timestamp == null || now.difference(timestamp) > maxReceiptAge) {
      batch.rejected.add('$id (stale)');
      continue;
    }

    final isMatch = raw['match'] == true;
    final captures = raw['captures'] is int ? raw['captures'] as int : 0;
    if (xp < 0 || xp > maxOfflineXpPerReceipt || (xp == 0 && !isMatch)) {
      batch.rejected.add('$id (xp=$xp)');
      continue;
    }
    if (captures < 0 || captures > maxCapturesPerMatch) {
      batch.rejected.add('$id (captures=$captures)');
      continue;
    }
    if (isMatch && today.matches + batch.matches >= maxOfflineMatchesPerDay) {
      batch.rejected.add('$id (daily match cap)');
      continue;
    }

    // XP beyond the daily cap is dropped, but the receipt still counts so it
    // isn't retried forever.
    final xpRoom = maxOfflineXpPerDay - today.xp - batch.xp;
    final granted = xp.clamp(0, xpRoom < 0 ? 0 : xpRoom);

    batch.acceptedIds.add(id);
    batch.xp += granted;
    if (isMatch) {
      batch.matches++;
      batch.captures += captures;
      if (raw['win'] == true) batch.wins++;
    }
  }
  return batch;
}
