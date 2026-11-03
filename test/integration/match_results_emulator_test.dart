// Runs only against the Firestore emulator (never production):
//   firebase emulators:exec --only firestore --project demo-parchis \
//     "dart test test/integration"
@Tags(['emulator'])
library;

import 'dart:io';

import 'package:google_cloud_firestore/google_cloud_firestore.dart';
import 'package:parchis_server/match_results.dart';
import 'package:test/test.dart';

void main() {
  final emulator = Platform.environment['FIRESTORE_EMULATOR_HOST'];
  if (emulator == null) {
    test('Firestore emulator tests', () {},
        skip: 'FIRESTORE_EMULATOR_HOST not set');
    return;
  }

  final db = Firestore(settings: const Settings(projectId: 'demo-parchis'));
  var n = 0;
  String uid() => 'u${DateTime.now().microsecondsSinceEpoch}_${n++}';

  Future<Map<String, dynamic>> profile(String id) async =>
      (await db.collection('users').doc(id).get()).data()!;

  test('a match result is applied exactly once', () async {
    final id = uid();
    await db.collection('users').doc(id).set({'xp': 90, 'level': 1});
    final result = MatchResult(
      uid: id,
      matchId: 'room_1',
      position: 0,
      totalPlayers: 4,
      captures: 2,
    );

    expect(await recordMatchResult(db, result), isTrue);
    expect(await recordMatchResult(db, result), isFalse);

    final p = await profile(id);
    expect(p['xp'], 190);
    expect(p['level'], levelForXp(190));
    expect(p['wins'], 1);
    expect(p['matches_played'], 1);
    expect(p['tokens_capture'], 2);
    expect(p['active_match_id'], isNull);
  });

  test('concurrent duplicate results still count once', () async {
    final id = uid();
    final result = MatchResult(
      uid: id,
      matchId: 'room_2',
      position: 1,
      totalPlayers: 2,
      captures: 0,
    );
    await Future.wait([
      for (var i = 0; i < 5; i++) recordMatchResult(db, result),
    ]);
    final p = await profile(id);
    expect(p['xp'], 10);
    expect(p['matches_played'], 1);
  });

  test('a surrender counts as played without XP', () async {
    final id = uid();
    await recordMatchResult(
      db,
      MatchResult(uid: id, matchId: 'room_3', totalPlayers: 3, captures: 1),
    );
    final p = await profile(id);
    expect(p['xp'], 0);
    expect(p['matches_played'], 1);
    expect(p.containsKey('wins'), isFalse);
  });
}
