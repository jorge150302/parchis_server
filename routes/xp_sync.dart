import 'dart:convert';
import 'dart:io';

import 'package:dart_firebase_admin/firestore.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:parchis_server/firebase_admin.dart';

const int _maxOnlineXpPerReceipt = 100;
// hard mode 1st place offline: 100 * 1.5 * 0.50 = 75
const int _maxOfflineXpPerReceipt = 75;
const int _maxReceiptsPerRequest = 20;
const Duration _maxReceiptAge = Duration(days: 7);

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

  // ── 2. Verify Firebase ID token ───────────────────────────────────────────
  final uid = await getUidFromToken(idToken);
  if (uid == null) {
    return Response(
      statusCode: HttpStatus.unauthorized,
      body: jsonEncode({'error': 'Invalid or expired id_token'}),
    );
  }

  // ── 3. Validate receipts ──────────────────────────────────────────────────
  if (rawReceipts.length > _maxReceiptsPerRequest) {
    return Response(
      statusCode: HttpStatus.badRequest,
      body: jsonEncode({'error': 'Too many receipts in one request'}),
    );
  }

  var validatedXp = 0;
  final rejectedIds = <String>[];
  final seenIds = <String>{};

  for (final raw in rawReceipts) {
    try {
      final r = raw as Map<String, dynamic>;
      final receiptId = r['id'] as String? ?? '';
      final xp = r['xp'] as int? ?? 0;
      final isOnline = r['is_online'] as bool? ?? false;
      final timestamp = DateTime.tryParse(r['timestamp'] as String? ?? '');

      if (receiptId.isNotEmpty && !seenIds.add(receiptId)) {
        rejectedIds.add('$receiptId (duplicate)');
        continue;
      }

      final age = timestamp == null
          ? null
          : DateTime.now().difference(timestamp);
      if (age == null || age > _maxReceiptAge) {
        rejectedIds.add('$receiptId (stale)');
        continue;
      }

      final maxAllowed = isOnline ? _maxOnlineXpPerReceipt : _maxOfflineXpPerReceipt;
      if (xp <= 0 || xp > maxAllowed) {
        rejectedIds.add('$receiptId (xp=$xp exceeds max=$maxAllowed)');
        continue;
      }

      validatedXp += xp;
    } catch (_) {
      rejectedIds.add('malformed_receipt');
    }
  }

  if (validatedXp <= 0) {
    return Response(
      statusCode: HttpStatus.ok,
      body: jsonEncode({
        'xp_applied': 0,
        'rejected': rejectedIds,
        'message': 'No valid XP to apply',
      }),
    );
  }

  // ── 4. Atomically update Firestore ────────────────────────────────────────
  try {
    final db = getAdminFirestore();
    final userRef = db.collection('users').doc(uid);

    await db.runTransaction((Transaction txn) async {
      final snap = await txn.get(userRef);
      final data = snap.data();
      final currentXp = (data?['xp'] as num?)?.toInt() ?? 0;
      final newXp = currentXp + validatedXp;
      final updated = {
        'xp': newXp,
        'level': _computeLevel(newXp),
        'updated_at': Timestamp.now(),
      };
      if (snap.exists) {
        txn.update(userRef, updated);
      } else {
        txn.set(userRef, updated);
      }
    });
  } catch (e) {
    return Response(
      statusCode: HttpStatus.internalServerError,
      body: jsonEncode({'error': 'Firestore update failed', 'detail': e.toString()}),
    );
  }

  return Response(
    statusCode: HttpStatus.ok,
    body: jsonEncode({
      'xp_applied': validatedXp,
      'rejected': rejectedIds,
      'message': 'XP synced successfully',
    }),
  );
}

int _computeLevel(int totalXp) {
  int level = 1;
  int remaining = totalXp;
  while (level < 100) {
    final req = _xpForLevel(level);
    if (remaining < req) break;
    remaining -= req;
    level++;
  }
  return level;
}

int _xpForLevel(int level) {
  if (level >= 91) return 1000;
  if (level >= 66) return 600;
  if (level >= 41) return 400;
  if (level >= 21) return 250;
  if (level >= 9) return 150;
  return 100;
}
