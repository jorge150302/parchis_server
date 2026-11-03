import 'dart:convert';
import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:google_cloud_firestore/google_cloud_firestore.dart';
import 'package:parchis_server/firebase_admin.dart';
import 'package:parchis_server/match_results.dart';
import 'package:parchis_server/xp_receipts.dart';

/// Firestore document ids can't contain '/' or be reserved `__x__` names.
final _validReceiptId = RegExp(r'^[A-Za-z0-9_\-]{1,100}$');

Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: HttpStatus.methodNotAllowed, body: 'POST only');
  }

  if (!isAdminConfigured) {
    return Response(
      statusCode: HttpStatus.serviceUnavailable,
      body: jsonEncode({'error': 'Firebase Admin not configured'}),
    );
  }

  // ── 1. Parse request body ─────────────────────────────────────────────────
  Map<String, dynamic> body;
  try {
    final raw = await context.request.body();
    body = jsonDecode(raw) as Map<String, dynamic>;
  } catch (_) {
    return Response(statusCode: HttpStatus.badRequest, body: 'Invalid JSON');
  }

  final idToken = body['id_token'] as String?;
  final rawReceipts = body['receipts'] as List<dynamic>?;

  if (idToken == null || rawReceipts == null || rawReceipts.isEmpty) {
    return Response(
      statusCode: HttpStatus.badRequest,
      body: jsonEncode({'error': 'id_token and receipts are required'}),
    );
  }
  if (rawReceipts.length > maxReceiptsPerRequest) {
    return Response(
      statusCode: HttpStatus.badRequest,
      body: jsonEncode({'error': 'Too many receipts in one request'}),
    );
  }

  // ── 2. Verify Firebase ID token ───────────────────────────────────────────
  final uid = await getUidFromToken(idToken);
  if (uid == null) {
    return Response(
      statusCode: HttpStatus.unauthorized,
      body: jsonEncode({'error': 'Invalid or expired id_token'}),
    );
  }

  final ids = rawReceipts
      .whereType<Map<String, dynamic>>()
      .map((r) => r['id'])
      .whereType<String>()
      .where(_validReceiptId.hasMatch)
      .toSet();
  final receipts = rawReceipts
      .map((r) => r is Map<String, dynamic> && ids.contains(r['id']) ? r : null)
      .toList();

  // ── 3. Validate and apply atomically ──────────────────────────────────────
  // Processed receipt ids live in users/{uid}/xp_receipts so a replayed
  // request (or a client retry after a lost response) is never counted twice.
  final now = DateTime.now();
  final day = utcDay(now);
  ReceiptBatch batch;
  try {
    final db = getAdminFirestore();
    final userRef = db.collection('users').doc(uid);
    batch = await db.runTransaction((txn) async {
      final user = await txn.get(userRef);
      final data = user.data() ?? const <String, dynamic>{};
      final sameDay = data['offline_day'] == day;
      final today = DailyUsage(
        xp: sameDay ? (data['offline_xp_today'] as num?)?.toInt() ?? 0 : 0,
        matches:
            sameDay ? (data['offline_matches_today'] as num?)?.toInt() ?? 0 : 0,
      );

      final processed = <String>{};
      for (final id in ids) {
        final doc = await txn.get(userRef.collection('xp_receipts').doc(id));
        if (doc.exists) processed.add(id);
      }

      final batch = validateReceipts(
        receipts,
        now: now,
        alreadyProcessed: processed,
        today: today,
      );
      if (batch.isEmpty) return batch;

      final newXp = ((data['xp'] as num?)?.toInt() ?? 0) + batch.xp;
      final update = <String, Object?>{
        'xp': newXp,
        'level': levelForXp(newXp),
        'offline_day': day,
        'offline_xp_today': today.xp + batch.xp,
        'offline_matches_today': today.matches + batch.matches,
        'updated_at': Timestamp.now(),
        if (batch.matches > 0)
          'matches_played': FieldValue.increment(batch.matches),
        if (batch.wins > 0) 'wins': FieldValue.increment(batch.wins),
        if (batch.captures > 0)
          'tokens_capture': FieldValue.increment(batch.captures),
      };
      if (user.exists) {
        txn.update(userRef, update);
      } else {
        txn.set(userRef, update, options: const SetOptions.merge());
      }
      for (final id in batch.acceptedIds) {
        txn.set(userRef.collection('xp_receipts').doc(id), {
          'processed_at': Timestamp.now(),
        });
      }
      return batch;
    });
  } catch (e, st) {
    stderr
      ..writeln('[${now.toUtc().toIso8601String()}] ERROR xp_sync $uid: $e')
      ..writeln(st);
    return Response(
      statusCode: HttpStatus.internalServerError,
      body: jsonEncode({'error': 'Firestore update failed'}),
    );
  }

  return Response(
    body: jsonEncode({
      'xp_applied': batch.xp,
      'accepted': batch.acceptedIds.length,
      'rejected': batch.rejected,
      'message':
          batch.isEmpty ? 'No valid XP to apply' : 'XP synced successfully',
    }),
  );
}
