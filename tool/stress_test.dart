// Concurrency stress test: many simultaneous rooms played to the end by bots,
// with hostile/buggy client behaviour mixed in, checking that rooms never
// bleed into each other and the server survives.
//
// Run against a server started WITHOUT service_account.json:
//   PARCHIS_DEV_AUTH_BYPASS=true PORT=8099 dart build/bin/server.dart
//   dart run tool/stress_test.dart ws://localhost:8099/ws [minutes] [--quick]
//
// --quick (for CI): only private test-mode rooms, whose tokens start next to
// the goal, so games end in seconds. Needs PARCHIS_ALLOW_TEST_MODE=true.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

final _rng = Random(7);
final _violations = <String>[];
void _violation(String msg) {
  _violations.add(msg);
  print('❌ $msg');
}

class Bot {
  Bot(this.url, this.clientId, {this.chaos = false});

  final String url;
  final String clientId;
  final bool chaos;
  WebSocket? _ws;
  String? roomCode;
  Map<String, dynamic>? lastState;
  bool finished = false;
  bool gameOver = false;
  final errors = <String>[];
  final _created = Completer<String>();
  final _joined = Completer<void>();
  Set<String> seenPlayerIds = {};
  int statesSeen = 0;
  String _progressKey = '';
  DateTime lastProgress = DateTime.now();
  int tokensFinished = 0;
  int pongs = 0;
  bool _reconnecting = false;

  Future<void> connect() async {
    _ws = await WebSocket.connect(url);
    _ws!.listen(_onMessage, onDone: () {}, onError: (_) {});
  }

  void send(String event, [Map<String, dynamic>? data, String? asClientId]) {
    _ws?.add(jsonEncode({
      'event': event,
      'clientId': asClientId ?? clientId,
      'level': 1,
      'data': data,
    }));
  }

  void sendRaw(String raw) => _ws?.add(raw);

  Future<String> createGame(int maxPlayers, {bool testMode = false}) {
    send('create_game', {
      'name': clientId,
      'maxPlayers': maxPlayers,
      if (testMode) 'testMode': true,
    });
    return _created.future;
  }

  Future<void> joinGame(String code) {
    send('join_game', {'name': clientId, 'roomCode': code});
    return _joined.future;
  }

  void findMatch(int maxPlayers) =>
      send('find_match', {'name': clientId, 'maxPlayers': maxPlayers});

  /// Drops the socket mid-game and comes back as the same device.
  Future<void> dropAndReconnect(Duration away) async {
    _reconnecting = true;
    await _ws?.close();
    await Future<void>.delayed(away);
    await connect();
    send('request_sync');
    _reconnecting = false;
  }

  void _onMessage(dynamic raw) {
    final msg = jsonDecode(raw as String) as Map<String, dynamic>;
    final event = msg['event'];
    final data = (msg['data'] ?? <String, dynamic>{}) as Map<String, dynamic>;
    switch (event) {
      case 'pong':
        pongs++;
      case 'game_created':
        roomCode = data['roomCode'] as String;
        if (!_created.isCompleted) _created.complete(roomCode);
        if (!_joined.isCompleted) _joined.complete();
      case 'game_joined':
        if (data['roomCode'] != null) roomCode = data['roomCode'] as String;
        if (!_joined.isCompleted) _joined.complete();
      case 'error':
        errors.add('${data['code']}');
      case 'you_finished':
        finished = true;
      case 'game_state':
        _onState(data);
      case 'dice_result':
        final current = lastState?['currentPlayerId'];
        if (current != null && data['playerId'] != current) {
          _violation('$clientId: dice_result for ${data['playerId']} but '
              'current player is $current (room $roomCode)');
        }
    }
  }

  void _onState(Map<String, dynamic> s) {
    statesSeen++;
    final code = s['roomCode'] as String;
    roomCode ??= code;
    if (code != roomCode) {
      _violation('$clientId got game_state of room $code but is in $roomCode');
    }
    final players = (s['players'] as List).cast<Map<String, dynamic>>();
    final ids = players.map((p) => p['id'] as String).toSet();
    if (!ids.contains(clientId)) {
      _violation('$clientId got game_state of $code without itself: $ids');
    }
    seenPlayerIds.addAll(ids);
    final boardSize = s['boardSize'] as int;
    for (final p in players) {
      for (final t in (p['tokens'] as List).cast<Map<String, dynamic>>()) {
        final pos = t['position'] as int;
        if (pos < -1 || pos > boardSize) {
          _violation('room $code token of ${p['id']} at impossible $pos');
        }
      }
    }
    lastState = s;
    // Progress = any token moved or the turn passed; a room whose key stops
    // changing while not finished is stuck, not just slow.
    final key = '${s['currentPlayerId']}|' +
        players.map((p) => (p['tokens'] as List).map((t) => t['position']).join(',')).join(';');
    if (key != _progressKey) {
      _progressKey = key;
      lastProgress = DateTime.now();
    }
    tokensFinished = players.fold<int>(0, (n, p) =>
        n + (p['tokens'] as List).where((t) => t['isFinished'] == true).length);
    if (s['phase'] == 'finished') gameOver = true;
    if (s['currentPlayerId'] != clientId || _reconnecting) return;

    final me = players.firstWhere((p) => p['id'] == clientId);
    final phase = s['phase'];
    if (phase == 'rolling') {
      send('roll_dice');
      // Double-tap: the second roll must be ignored by the server.
      if (chaos && _rng.nextDouble() < 0.3) send('roll_dice');
    } else if (phase == 'choosing_token') {
      // Try every token; the server accepts the first legal one and must
      // drop the rest (phase is already `moving`).
      for (final t in (me['tokens'] as List).cast<Map<String, dynamic>>()) {
        if (t['isFinished'] != true) send('move_token', {'tokenId': t['id']});
      }
      if (chaos && _rng.nextDouble() < 0.3) send('move_token', {'tokenId': 99});
    }
  }

  /// Out-of-turn noise from a player who is not on turn.
  void misbehave(List<Bot> roomMates) {
    if (_reconnecting || gameOver) return;
    final s = lastState;
    if (s == null || s['currentPlayerId'] == clientId) return;
    switch (_rng.nextInt(5)) {
      case 0:
        send('roll_dice');
      case 1:
        send('move_token', {'tokenId': 0});
      case 2:
        send('skip_turn');
      case 3:
        sendRaw('this is not json {');
        sendRaw('{"event": 5}');
      case 4:
        // Spoof the current player from this channel.
        final victim = s['currentPlayerId'] as String;
        send('roll_dice', null, victim);
        send('surrender', null, victim);
    }
  }

  Future<void> close() async => _ws?.close();
}

Future<void> main(List<String> args) async {
  final quick = args.contains('--quick');
  final positional = args.where((a) => !a.startsWith('--')).toList();
  final url = positional.isNotEmpty ? positional.first : 'ws://localhost:8099/ws';
  final timeLimit =
      Duration(minutes: positional.length > 1 ? int.parse(positional[1]) : 10);
  final sw = Stopwatch()..start();
  var n = 0;
  String id() => 'bot${n++}';

  // --- Private rooms: 4x 2p, 4x 3p, 4x 4p, all created at the same time ---
  final roomSizes = quick
      ? [2, 2, 2, 3, 3, 4, 4, 4]
      : [2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4];
  final privateRooms = <List<Bot>>[];
  for (final size in roomSizes) {
    privateRooms.add([
      for (var i = 0; i < size; i++) Bot(url, id(), chaos: _rng.nextBool()),
    ]);
  }
  final allPrivate = privateRooms.expand((r) => r).toList();
  await Future.wait(allPrivate.map((b) => b.connect()));
  final codes = await Future.wait(
      [for (var i = 0; i < roomSizes.length; i++) privateRooms[i][0].createGame(roomSizes[i], testMode: quick)]);
  if (codes.toSet().length != codes.length) {
    _violation('duplicate room codes from concurrent create_game: $codes');
  }
  await Future.wait([
    for (var i = 0; i < privateRooms.length; i++)
      for (final b in privateRooms[i].skip(1)) b.joinGame(codes[i]),
  ]);
  print('✅ ${privateRooms.length} private rooms created concurrently: $codes');

  // --- Matchmaking: 16 bots want 2p, 8 bots want 4p, all at once ---
  // Public rooms can't use test mode, so --quick skips matchmaking.
  final mm2 = [for (var i = 0; i < (quick ? 0 : 16); i++) Bot(url, id(), chaos: true)];
  final mm4 = [for (var i = 0; i < (quick ? 0 : 8); i++) Bot(url, id(), chaos: true)];
  final mm = [...mm2, ...mm4];
  await Future.wait(mm.map((b) => b.connect()));
  for (final b in mm2) {
    b.findMatch(2);
  }
  for (final b in mm4) {
    b.findMatch(4);
  }

  final all = [...allPrivate, ...mm];
  print('🎲 ${all.length} bots playing…');

  // Group bots by the room the server put them in (after matchmaking settles).
  await Future<void>.delayed(const Duration(seconds: 3));
  Map<String, List<Bot>> byRoom() {
    final m = <String, List<Bot>>{};
    for (final b in all) {
      if (b.roomCode != null) (m[b.roomCode!] ??= []).add(b);
    }
    return m;
  }

  final rooms = byRoom();
  final unseated = all.where((b) => b.roomCode == null).map((b) => b.clientId);
  if (unseated.isNotEmpty) _violation('bots never seated: $unseated');
  for (final e in rooms.entries) {
    final size = e.value.first.lastState?['maxPlayers'];
    if (e.value.length != size) {
      _violation('room ${e.key} has ${e.value.length} bots but maxPlayers $size');
    }
  }
  print('✅ matchmaking seated ${mm.length} bots into '
      '${rooms.length - privateRooms.length} public rooms');

  // Chaos loop: out-of-turn noise + one mid-game disconnect per 4 rooms.
  final dropped = <Bot>{};
  var tick = 0;
  final chaosTimer = Timer.periodic(const Duration(milliseconds: 400), (_) {
    tick++;
    for (final b in all.where((b) => b.chaos)) {
      if (_rng.nextDouble() < 0.15) b.misbehave(all);
    }
    if (tick == (quick ? 3 : 25)) {
      for (final r in rooms.values.toList().asMap().entries.where((e) => e.key.isEven)) {
        final victim = r.value.last;
        dropped.add(victim);
        unawaited(victim.dropAndReconnect(const Duration(seconds: 4)));
      }
      print('🔌 dropped & reconnecting ${dropped.length} bots mid-game');
    }
  });

  // Wait until every room reaches `finished` or time runs out.
  while (sw.elapsed < timeLimit) {
    await Future<void>.delayed(const Duration(seconds: 5));
    final open = byRoom().entries.where((e) => !e.value.any((b) => b.gameOver)).length;
    print('  ${sw.elapsed.inSeconds}s: ${rooms.length - open}/${rooms.length} rooms finished');
    if (open == 0) break;
  }
  chaosTimer.cancel();

  // --- Final invariants ---
  final finalRooms = byRoom();
  final memberOf = <String, String>{};
  for (final e in finalRooms.entries) {
    final expected = e.value.map((b) => b.clientId).toSet();
    for (final b in e.value) {
      final foreign = b.seenPlayerIds.difference(expected);
      if (foreign.isNotEmpty) {
        _violation('room ${e.key}: ${b.clientId} saw foreign players $foreign');
      }
      final prev = memberOf[b.clientId];
      if (prev != null && prev != e.key) {
        _violation('${b.clientId} is in two rooms: $prev and ${e.key}');
      }
      memberOf[b.clientId] = e.key;
    }
  }
  for (final b in dropped) {
    if (b.errors.contains('MATCH_NOT_FOUND') || b.errors.contains('CANNOT_REJOIN')) {
      _violation('${b.clientId} could not resume after reconnect: ${b.errors}');
    }
  }
  final unfinished = finalRooms.entries.where((e) => !e.value.any((b) => b.gameOver));
  final now = DateTime.now();
  for (final e in unfinished) {
    final last = e.value.map((b) => b.lastProgress).reduce((a, b) => a.isAfter(b) ? a : b);
    final idle = now.difference(last).inSeconds;
    final done = e.value.first.tokensFinished;
    final total = e.value.length * 2;
    if (idle > 60) {
      _violation('room ${e.key} STUCK: no movement for ${idle}s '
          '(phase ${e.value.first.lastState?['phase']}, $done/$total tokens home)');
    } else {
      print('⏳ room ${e.key} still playing (${e.value.length}p, $done/$total tokens home, '
          'last move ${idle}s ago) — slow, not stuck');
    }
  }
  final mismatches = all.fold<int>(0, (s, b) => s + b.errors.where((c) => c == 'CLIENT_MISMATCH').length);

  // Server still alive and responsive?
  final probe = Bot(url, 'probe');
  await probe.connect();
  probe.send('ping');
  await Future<void>.delayed(const Duration(seconds: 1));
  if (probe.pongs == 0) _violation('server stopped answering ping');
  final http = await HttpClient().getUrl(Uri.parse(url.replaceFirst('ws', 'http').replaceFirst('/ws', '/')));
  final res = await http.close();
  if (res.statusCode != 200) _violation('GET / returned ${res.statusCode}');

  await Future.wait([...all, probe].map((b) => b.close()));

  // Leak check: once every bot is gone, the server must release all rooms,
  // sockets and timers (90 s reconnection grace + cleanup, so allow 4 min).
  final healthUrl = Uri.parse(
      url.replaceFirst('ws', 'http').replaceFirst(RegExp(r'/ws$'), '/health'));
  Map<String, dynamic> health = {};
  final leakDeadline = DateTime.now().add(const Duration(minutes: 4));
  while (DateTime.now().isBefore(leakDeadline)) {
    final req = await HttpClient().getUrl(healthUrl);
    final body = await (await req.close()).transform(utf8.decoder).join();
    health = jsonDecode(body) as Map<String, dynamic>;
    if (health['rooms'] == 0 &&
        health['connections'] == 0 &&
        health['reconnectionTimers'] == 0) {
      break;
    }
    await Future<void>.delayed(const Duration(seconds: 10));
  }
  print('health after cleanup: $health');
  if (health['rooms'] != 0 ||
      health['connections'] != 0 ||
      health['reconnectionTimers'] != 0) {
    _violation('server did not release resources after 4 min: $health');
  }
  print('\n===== RESULT (${sw.elapsed.inSeconds}s) =====');
  print('rooms: ${finalRooms.length}, bots: ${all.length}, '
      'game_states: ${all.fold<int>(0, (s, b) => s + b.statesSeen)}');
  print('spoof attempts rejected (CLIENT_MISMATCH): $mismatches');
  print('reconnected mid-game: ${dropped.length}');
  print(_violations.isEmpty ? '✅ NO VIOLATIONS' : '❌ ${_violations.length} VIOLATIONS');
  exit(_violations.isEmpty ? 0 : 1);
}
