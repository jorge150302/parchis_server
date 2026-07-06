import 'dart:async';
import 'dart:convert';

import 'package:dart_firebase_admin/firestore.dart' show FieldValue;
import 'package:dart_frog/dart_frog.dart';
import 'package:dart_frog_web_socket/dart_frog_web_socket.dart';
import 'package:parchis_server/firebase_admin.dart';
import 'package:parchis_server/game_engine.dart';
import 'package:parchis_server/logic/board_generator.dart';
import 'package:parchis_server/logic/board_presets.dart';
import 'package:parchis_server/models/board_action.dart';
import 'package:parchis_server/models/player.dart';

// --- Clases de Soporte ---

class GameRoom {
  GameRoom(this.code, this.engine, this.maxPlayers, {this.isPublic = false, this.testMode = false});

  final String code;
  final GameEngine engine;
  final int maxPlayers;
  bool isPublic;
  final bool testMode;
  final Map<String, WebSocketChannel> clients = {}; // clientId → channel
  final Map<String, String> playerUids = {};        // clientId → Firebase UID
  bool hadMultipleHumans = false;

  Timer? turnTimer;
  Timer? maxDurationTimer;
  Timer? zombieCleanupTimer;
  int remainingSeconds = 20;
  int? forcedDice; // debug only: consumed on next roll

  void broadcast(Map<String, dynamic> event) {
    final message = jsonEncode(event);
    for (final channel in clients.values) {
      channel.sink.add(message);
    }
  }

  void stopTimer() {
    turnTimer?.cancel();
    turnTimer = null;
  }

  void startMaxDurationTimer(void Function() onExpired) {
    maxDurationTimer?.cancel();
    maxDurationTimer = Timer(const Duration(minutes: 90), onExpired);
  }

  void stopAll() {
    turnTimer?.cancel();
    maxDurationTimer?.cancel();
    zombieCleanupTimer?.cancel();
  }

  void startTimer(void Function() onTimeout) {
    stopTimer();

    final currentPlayer = engine.currentPlayer;

    if (currentPlayer.isAI || currentPlayer.isAutoPlaying) {
      turnTimer = Timer(const Duration(seconds: 3), onTimeout);
      return;
    }

    remainingSeconds = 20;
    _broadcastTimer();

    turnTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      remainingSeconds--;
      if (remainingSeconds <= 0) {
        stopTimer();
        onTimeout();
      } else {
        _broadcastTimer();
      }
    });
  }

  void _broadcastTimer() {
    broadcast({
      'event': 'timer_update',
      'data': {'seconds': remainingSeconds},
    });
  }
}

// --- Estado Global del Servidor ---

final Map<String, GameRoom> _rooms = {};
final Map<WebSocketChannel, String> _channelToPlayer = {};
final Map<WebSocketChannel, String> _channelToRoom = {};
final Map<String, Timer> _reconnectionTimers = {};
final Map<String, Map<String, dynamic>> _userDatabase = {};
final List<Map<String, dynamic>> _playerReports = [];
// UID → roomCode — updated synchronously so multi-device checks are race-free.
final Map<String, String> _activeUids = {};
// UID → clientId — enforces single session per account.
// clientId is a persistent device UUID (SharedPreferences), stable across reconnects.
// Different devices have different clientIds, so reconnects from the same device are never blocked.
final Map<String, String> _uidSessions = {};

// --- Firestore helpers ---

Future<void> _setActiveMatch(String uid, String roomCode) async {
  if (!isAdminConfigured) return;
  try {
    await getAdminFirestore()
        .collection('users')
        .doc(uid)
        .update({'active_match_id': roomCode});
  } catch (_) {}
}

Future<void> _clearActiveMatch(String uid) async {
  _activeUids.remove(uid);
  if (!isAdminConfigured) return;
  try {
    await getAdminFirestore()
        .collection('users')
        .doc(uid)
        .update({'active_match_id': null});
  } catch (_) {}
}

/// Records an abandoned match (grace period expiry) — increments matches_played.
Future<void> _recordMatchAbandoned(String uid) async {
  _activeUids.remove(uid);
  if (!isAdminConfigured) return;
  try {
    await getAdminFirestore().collection('users').doc(uid).update({
      'matches_played': const FieldValue.increment(1),
      'active_match_id': null,
    });
  } catch (_) {}
}

/// Resolves the Firebase UID from [idToken], stores it in the room, and writes
/// active_match_id to Firestore. Safe to call with a null token (no-op).
Future<void> _storeUidAndSetActiveMatch(
  GameRoom room,
  String clientId,
  String? idToken,
  String roomCode,
) async {
  final uid = await getUidFromToken(idToken);
  if (uid == null) return;
  room.playerUids[clientId] = uid;
  if (room.playerUids.length > 1) room.hadMultipleHumans = true;
  _activeUids[uid] = roomCode; // update from __pending__ to real room code
  await _setActiveMatch(uid, roomCode);
}

/// Sends `you_finished` to the player's channel and clears their active_match_id.
/// Safe to call multiple times — removes the UID on first call so subsequent
/// calls are no-ops.
void _notifyAndClearPlayerFinish(String roomCode, Player player, {bool silent = false, String? reason}) {
  final room = _rooms[roomCode];
  if (room == null) return;
  final rank = room.engine.finishedPlayers.indexOf(player) + 1;
  final channel = room.clients[player.id];
  channel?.sink.add(jsonEncode({
    'event': 'you_finished',
    'data': {
      'position': rank,
      'totalPlayers': room.engine.players.length,
      'silent': silent,
      'reason': reason,
    },
  }));
  final uid = room.playerUids.remove(player.id);
  if (uid != null) unawaited(_clearActiveMatch(uid));
}

/// Closes and removes a room if no human players remain (all AI or finished).
void _checkAndCleanupRoom(String roomCode) {
  final room = _rooms[roomCode];
  if (room == null) return;

  // Don't kill if the game is already in the final spectator window.
  if (room.engine.phase == GamePhase.finished) return;

  final humansRemaining = room.playerUids.keys.toList();

  // Last human standing victory: if only one human remains in a match that started with multiple,
  // and that human hasn't finished yet, award them the win automatically.
  if (humansRemaining.length == 1 && room.hadMultipleHumans) {
    final lastPlayerId = humansRemaining.first;
    final player = room.engine.players.firstWhere((p) => p.id == lastPlayerId);
    
    if (!player.isFinished) {
      // Mark as winner silently on the server state
      for (final t in player.tokens) {
        t.position = -1;
        t.isFinished = true;
      }
      
      // Ensure they are in the winners list for correct rank and state
      if (!room.engine.finisherIds.contains(player.id)) {
        room.engine.finisherIds.add(player.id);
      }
      
      _notifyAndClearPlayerFinish(roomCode, player, silent: true, reason: 'abandonment');
      room.engine.phase = GamePhase.finished;
      _broadcastGameState(roomCode);
      
      // Schedule cleanup
      Timer(const Duration(seconds: 30), () => _rooms.remove(roomCode)?.stopAll());
      return;
    }
  }

  if (humansRemaining.isEmpty) {
    final orphanRoom = _rooms.remove(roomCode);
    if (orphanRoom != null) {
      for (final uid in orphanRoom.playerUids.values) {
        unawaited(_clearActiveMatch(uid));
      }
      orphanRoom.playerUids.clear();
      orphanRoom.stopAll();
    }
  }
}

// --- WebSocket handler ---

Future<Response> onRequest(RequestContext context) async {
  final handler = webSocketHandler((channel, protocol) {

    void handleDisconnect() {
      final roomCode = _channelToRoom[channel];
      final playerId = _channelToPlayer[channel];

      if (roomCode != null && playerId != null) {
        final room = _rooms[roomCode];
        if (room != null) {
          final player = room.engine.players.firstWhere(
            (p) => p.id == playerId,
            orElse: () => Player(id: '', name: ''),
          );
          if (player.id.isNotEmpty) {
            player.isConnected = false;
            player.isAutoPlaying = true;
            _broadcastGameState(roomCode);
          }

          // Pre-game waiting room: destroy immediately — no grace period needed.
          if (room.engine.phase == GamePhase.idle) {
            room.clients.remove(playerId);
            _channelToPlayer.remove(channel);
            _channelToRoom.remove(channel);
            final orphanRoom = _rooms.remove(roomCode);
            if (orphanRoom != null) {
              orphanRoom.broadcast({'event': 'error', 'data': {'code': 'ROOM_CLOSED', 'message': 'Room closed'}});
              final uid = orphanRoom.playerUids.remove(playerId);
              if (uid != null) unawaited(_clearActiveMatch(uid));
              for (final uid2 in orphanRoom.playerUids.values) {
                unawaited(_clearActiveMatch(uid2));
              }
              orphanRoom.playerUids.clear();
              orphanRoom.stopAll();
            }
            return;
          }

          // Grace period: 90 seconds before permanently converting to AI.
          _reconnectionTimers[playerId]?.cancel();
          _reconnectionTimers[playerId] = Timer(const Duration(seconds: 90), () {
            final p = room.engine.players.firstWhere(
              (p) => p.id == playerId,
              orElse: () => Player(id: '', name: ''),
            );
            if (p.id.isNotEmpty) {
              p.isAI = true;
              _broadcastGameState(roomCode);
              // Clear active_match_id and count the abandoned match.
              final uid = room.playerUids.remove(playerId);
              if (uid != null) unawaited(_recordMatchAbandoned(uid));
              _checkAndCleanupRoom(roomCode);
            }
            _reconnectionTimers.remove(playerId);
          });

          room.clients.remove(playerId);

          // Zombie cleanup — remove room if all clients drop for 5 min.
          if (room.clients.isEmpty) {
            room.zombieCleanupTimer?.cancel();
            room.zombieCleanupTimer = Timer(const Duration(minutes: 5), () {
              if (_rooms[roomCode]?.clients.isEmpty ?? false) {
                final orphanRoom = _rooms.remove(roomCode);
                if (orphanRoom != null) {
                  // Clear active_match_id for any remaining players.
                  for (final uid in orphanRoom.playerUids.values) {
                    unawaited(_clearActiveMatch(uid));
                  }
                  orphanRoom.playerUids.clear();
                  orphanRoom.stopAll();
                }
              }
            });
          }
        }
      }
      final disconnectedClientId = _channelToPlayer[channel];
      _channelToPlayer.remove(channel);
      _channelToRoom.remove(channel);
      // Free the session slot so the account can reconnect.
      // Only remove if the stored clientId matches the disconnecting device —
      // prevents a reconnecting device from wiping another device's slot.
      if (disconnectedClientId != null) {
        _uidSessions.removeWhere((_, cId) => cId == disconnectedClientId);
      }
    }

    channel.stream.listen(
      (dynamic message) async {
        try {
          final event = jsonDecode(message as String) as Map<String, dynamic>;
          final eventName = event['event'] as String;
          final data = (event['data'] ?? <String, dynamic>{}) as Map<String, dynamic>;
          final clientId = event['clientId'] as String?;
          final level = event['level'] as int? ?? 1;
          final avatarType = event['avatarType'] as String? ?? 'google';
          final avatarIconId = event['avatarIconId'] as String?;
          final idToken = event['idToken'] as String?;

          if (eventName == 'ping') {
            channel.sink.add(jsonEncode({'event': 'pong'}));
            return;
          }

          if (clientId == null) {
            _sendError(channel, 'clientId requerido.');
            return;
          }

          // --- request_sync: player reconnects after disconnect ---
          if (eventName == 'request_sync') {
            // Single-session check: reject if another device holds this account.
            final syncUid = await getUidFromToken(idToken);
            if (syncUid != null) {
              final existingClientId = _uidSessions[syncUid];
              if (existingClientId != null && existingClientId != clientId) {
                _sendError(channel,
                    'Hay otro dispositivo conectado a esta cuenta.',
                    code: 'SESSION_CONFLICT');
                return;
              }
              _uidSessions[syncUid] = clientId;
            }

            _reconnectionTimers[clientId]?.cancel();
            _reconnectionTimers.remove(clientId);

            GameRoom? userRoom;
            for (final room in _rooms.values) {
              if (room.engine.players.any((p) => p.id == clientId)) {
                userRoom = room;
                break;
              }
            }

            if (userRoom != null) {
              final player = userRoom.engine.players.firstWhere((p) => p.id == clientId);
              if (player.isAI) {
                _sendError(channel, 'No se encontró una partida activa para este ID.',
                    code: 'MATCH_NOT_FOUND');
                return;
              }

              player.isConnected = true;
              player.level = level;

              final oldChannel = userRoom.clients[clientId];
              if (oldChannel != null && oldChannel != channel) {
                _channelToPlayer.remove(oldChannel);
                _channelToRoom.remove(oldChannel);
                try { oldChannel.sink.close(); } catch (_) {}
              }

              userRoom.clients[clientId] = channel;
              _channelToPlayer[channel] = clientId;
              _channelToRoom[channel] = userRoom.code;
              _broadcastGameState(userRoom.code);
              if (userRoom.engine.currentPlayer.id == clientId &&
                  userRoom.engine.phase != GamePhase.idle) {
                userRoom.startTimer(() => _handleTimeout(userRoom!.code));
              }
            } else {
              _sendError(channel, 'No se encontró una partida activa para este ID.',
                  code: 'MATCH_NOT_FOUND');
            }
            return;
          }

          if (eventName == 'report_player') {
            final reportedId = data['reportedId'] as String?;
            final reason = data['reason'] as String?;
            if (reportedId != null && reason != null) {
              _playerReports.add({
                'reporterId': clientId,
                'reportedId': reportedId,
                'reason': reason,
                'timestamp': data['timestamp'] ?? DateTime.now().toIso8601String(),
              });
              channel.sink.add(jsonEncode(
                  {'event': 'report_received', 'data': {'message': 'Reporte registrado.'}}));
            }
            return;
          }

          if (eventName == 'delete_user_data') {
            _userDatabase.remove(data['playerId'] ?? clientId);
            channel.sink.add(jsonEncode(
                {'event': 'user_data_deleted', 'data': {'message': 'Datos eliminados.'}}));
            return;
          }

          // --- register_session: called on lobby entry to enforce single-device-per-account ---
          if (eventName == 'register_session') {
            final uid = await getUidFromToken(idToken);
            if (uid != null) {
              final existingClientId = _uidSessions[uid];
              if (existingClientId != null && existingClientId != clientId) {
                _sendError(channel,
                    'Hay otro dispositivo conectado a esta cuenta.',
                    code: 'SESSION_CONFLICT');
                return;
              }
              _uidSessions[uid] = clientId;
            }
            return;
          }

          if (eventName == 'find_match' || eventName == 'create_game' || eventName == 'join_game') {
            final uid = await getUidFromToken(idToken);
            if (uid != null) {
              // Single-session enforcement: reject second device.
              final existingClientId = _uidSessions[uid];
              if (existingClientId != null && existingClientId != clientId) {
                _sendError(channel,
                    'Hay otro dispositivo conectado a esta cuenta.',
                    code: 'SESSION_CONFLICT');
                return;
              }
              // Register this device as the active session for this account.
              _uidSessions[uid] = clientId;

              // Block if already in a room.
              if (_activeUids.containsKey(uid)) {
                final roomCode = _activeUids[uid];
                final roomStillActive = roomCode != '__pending__' &&
                    _rooms.containsKey(roomCode) &&
                    _rooms[roomCode]!.playerUids.values.contains(uid);
                if (roomStillActive) {
                  channel.sink.add(jsonEncode({
                    'event': 'error',
                    'data': {
                      'code': 'ALREADY_IN_GAME',
                      'message': 'Ya estás en una partida activa.',
                      'roomCode': roomCode,
                    },
                  }));
                  return;
                }
                _activeUids.remove(uid);
              }
              _activeUids[uid] = '__pending__';
            }
          }

          if (eventName == 'find_match') {
            if (!await verifyIdToken(idToken)) {
              _sendError(channel, 'Auth required.', code: 'UNAUTHORIZED');
              return;
            }
            final targetMaxPlayers = (data['maxPlayers'] as int?) ?? 2;
            GameRoom? foundRoom;
            for (final room in _rooms.values) {
              if (room.isPublic &&
                  room.maxPlayers == targetMaxPlayers &&
                  room.engine.players.length < room.maxPlayers &&
                  room.engine.phase == GamePhase.idle &&
                  room.clients.length == room.engine.players.length) {
                foundRoom = room;
                break;
              }
            }
            if (foundRoom != null) {
              _joinToRoom(channel, foundRoom, clientId, data['name'] as String?,
                  level, avatarType, avatarIconId, idToken);
            } else {
              _sendError(channel, 'No hay salas.', code: 'MATCH_NOT_FOUND');
            }
            return;
          }

          if (eventName == 'create_game') {
            if (!await verifyIdToken(idToken)) {
              _sendError(channel, 'Auth required.', code: 'UNAUTHORIZED');
              return;
            }
            _createAndJoinRoom(
              channel, clientId, data['name'] as String?,
              (data['maxPlayers'] as int?) ?? 2,
              (data['isPublic'] as bool?) ?? false,
              level, avatarType, avatarIconId, idToken,
              testMode: (data['testMode'] as bool?) ?? false,
            );
          }

          if (eventName == 'join_game') {
            if (!await verifyIdToken(idToken)) {
              _sendError(channel, 'Auth required.', code: 'UNAUTHORIZED');
              return;
            }
            final room = _rooms[data['roomCode'] ?? ''];
            if (room != null) {
              _joinToRoom(channel, room, clientId, data['name'] as String?,
                  level, avatarType, avatarIconId, idToken);
            } else {
              _sendError(channel, 'La sala no existe.');
            }
          }

          if (eventName == 'debug_set_dice') {
            final roomCode = _channelToRoom[channel];
            final room = roomCode != null ? _rooms[roomCode] : null;
            if (room != null && room.testMode) {
              room.forcedDice = data['value'] as int?;
            }
            return;
          }

          if (eventName == 'roll_dice') {
            _updatePlayerLevel(clientId, level);
            _handleRollDice(channel);
          }

          if (eventName == 'move_token') {
            _updatePlayerLevel(clientId, level);
            final tokenId = data['tokenId'] as int?;
            if (tokenId != null) unawaited(_handleMoveToken(channel, tokenId));
          }

          if (eventName == 'skip_turn') {
            _updatePlayerLevel(clientId, level);
            final roomCode = _channelToRoom[channel];
            if (roomCode != null) _moveToNextTurnWithSkips(roomCode);
          }

          if (eventName == 'chat_message') {
            final roomCode = _channelToRoom[channel];
            if (roomCode != null) {
              final room = _rooms[roomCode];
              if (room != null) {
                final player = room.engine.players.firstWhere(
                  (p) => p.id == clientId,
                  orElse: () => Player(id: '', name: ''),
                );
                if (player.id.isNotEmpty) {
                  room.broadcast({
                    'event': 'chat',
                    'data': {
                      'sender': player.name,
                      'senderId': clientId,
                      'message': data['message'],
                    },
                  });
                }
              }
            }
            return;
          }

          if (eventName == 'quick_chat') {
            final roomCode = _channelToRoom[channel];
            if (roomCode != null) {
              final room = _rooms[roomCode];
              if (room != null) {
                room.broadcast({
                  'event': 'quick_chat',
                  'data': {
                    'senderId': clientId,
                    'message': data['message'] ?? '',
                  },
                });
              }
            }
            return;
          }

          // --- surrender: voluntary exit mid-game (counts as loss) ---
          if (eventName == 'surrender') {
            final roomCode = _channelToRoom[channel];
            if (roomCode == null) return;
            final room = _rooms[roomCode];
            if (room == null) return;

            final player = room.engine.players.firstWhere(
              (p) => p.id == clientId,
              orElse: () => Player(id: '', name: ''),
            );
            if (player.id.isEmpty || player.isFinished) return;

            // Clear active_match_id immediately.
            final uid = room.playerUids.remove(player.id);
            if (uid != null) unawaited(_clearActiveMatch(uid));

            // Confirm surrender to the leaving player.
            channel.sink.add(jsonEncode({'event': 'surrendered', 'data': {}}));

            // Convert to AI so the game continues.
            player.isAI = true;
            player.isConnected = false;
            room.clients.remove(clientId);
            _channelToPlayer.remove(channel);
            _channelToRoom.remove(channel);

            _broadcastGameState(roomCode);
            _checkAndCleanupRoom(roomCode);
            return;
          }

          // --- leave_match: winner leaves after finishing ---
          if (eventName == 'leave_match') {
            final roomCode = _channelToRoom[channel];
            if (roomCode != null) {
              final room = _rooms[roomCode];
              if (room != null) {
                final player = room.engine.players.firstWhere(
                  (p) => p.id == clientId,
                  orElse: () => Player(id: '', name: ''),
                );
                if (player.id.isNotEmpty && player.isFinished) {
                  room.clients.remove(clientId);
                  _channelToPlayer.remove(channel);
                  _channelToRoom.remove(channel);
                  _broadcastGameState(roomCode);
                  _checkAndCleanupRoom(roomCode);
                }
              }
            }
            return;
          }

          // --- toggle_auto_play ---
          if (eventName == 'toggle_auto_play') {
            final value = data['value'] as bool? ?? false;
            final roomCode = _channelToRoom[channel];
            if (roomCode != null) {
              final room = _rooms[roomCode];
              if (room != null) {
                final player = room.engine.players.firstWhere(
                  (p) => p.id == clientId,
                  orElse: () => Player(id: '', name: ''),
                );
                if (player.id.isNotEmpty) {
                  player.isAutoPlaying = value;
                  _broadcastGameState(roomCode);
                  if (room.engine.currentPlayer.id == clientId &&
                      room.engine.phase != GamePhase.idle) {
                    room.startTimer(() => _handleTimeout(roomCode));
                  }
                }
              }
            }
            return;
          }
        } catch (e) { /* Error silencioso */ }
      },
      onDone: handleDisconnect,
      onError: (dynamic error) => handleDisconnect(),
    );
  });
  return handler(context);
}

// --- Helpers de Nivel ---

void _updatePlayerLevel(String clientId, int level) {
  for (final room in _rooms.values) {
    final player = room.engine.players
        .firstWhere((p) => p.id == clientId, orElse: () => Player(id: '', name: ''));
    if (player.id.isNotEmpty) {
      player.level = level;
      break;
    }
  }
}

// --- Funciones de Gestión de Salas ---

void _createAndJoinRoom(
  WebSocketChannel channel,
  String clientId,
  String? name,
  int maxPlayers,
  bool isPublic,
  int level,
  String avatarType,
  String? avatarIconId,
  String? idToken, {
  bool testMode = false,
}) {
  final roomCode =
      (DateTime.now().millisecondsSinceEpoch % 100000).toString().padLeft(5, '0');
  final board = generateBoard(classicActionPositions, classicActions, totalCells: 100);
  final engine = GameEngine(board: board, players: []);
  final room = GameRoom(roomCode, engine, maxPlayers, isPublic: isPublic, testMode: testMode);
  _rooms[roomCode] = room;

  final newPlayer = Player(
    id: clientId,
    name: name ?? 'Anfitrión',
    level: level,
    avatarType: avatarType,
    avatarIconId: avatarIconId,
  );
  room.engine.players.add(newPlayer);
  room.clients[clientId] = channel;
  _channelToPlayer[channel] = clientId;
  _channelToRoom[channel] = roomCode;

  unawaited(_storeUidAndSetActiveMatch(room, clientId, idToken, roomCode));

  if (room.engine.players.length == room.maxPlayers) {
    room.engine.phase = GamePhase.rolling;
    if (room.testMode) _applyTestMode(room);
  }

  channel.sink.add(jsonEncode({'event': 'game_created', 'data': {'roomCode': roomCode}}));
  _broadcastGameState(roomCode);

  if (room.engine.phase == GamePhase.rolling) {
    room.startTimer(() => _handleTimeout(roomCode));
  }
}

void _joinToRoom(
  WebSocketChannel channel,
  GameRoom room,
  String clientId,
  String? name,
  int level,
  String avatarType,
  String? avatarIconId,
  String? idToken,
) {
  final existingPlayerIndex = room.engine.players.indexWhere((p) => p.id == clientId);
  if (existingPlayerIndex != -1) {
    final player = room.engine.players[existingPlayerIndex];
    // Surrendered or grace-period-expired → permanently AI. Block rejoin.
    if (player.isAI) {
      _sendError(channel, 'No puedes unirte a esta partida.', code: 'CANNOT_REJOIN');
      return;
    }
    // Reconnection path — cancel grace timer and restore player.
    _reconnectionTimers[clientId]?.cancel();
    _reconnectionTimers.remove(clientId);
    player.isAI = false;
    player.isConnected = true;
    player.level = level;
    player.avatarType = avatarType;
    player.avatarIconId = avatarIconId;
    // Evict old channel (device switch — Scenario 5).
    final oldChannel = room.clients[clientId];
    if (oldChannel != null && oldChannel != channel) {
      _channelToPlayer.remove(oldChannel);
      _channelToRoom.remove(oldChannel);
      try { oldChannel.sink.close(); } catch (_) {}
    }
    room.clients[clientId] = channel;
    _channelToPlayer[channel] = clientId;
    _channelToRoom[channel] = room.code;
    // Refresh UID in case it was missing (e.g. server restart).
    unawaited(_storeUidAndSetActiveMatch(room, clientId, idToken, room.code));
    channel.sink.add(jsonEncode({'event': 'game_joined', 'data': {'reconnected': true}}));
    _broadcastGameState(room.code);
    if (room.engine.currentPlayer.id == clientId && room.engine.phase != GamePhase.idle) {
      room.startTimer(() => _handleTimeout(room.code));
    }
    return;
  }

  if (room.engine.phase != GamePhase.idle || room.engine.players.length >= room.maxPlayers) {
    _sendError(channel, 'Sala no disponible.');
    return;
  }

  final newPlayer = Player(
    id: clientId,
    name: name ?? 'Jugador ${room.engine.players.length + 1}',
    level: level,
    avatarType: avatarType,
    avatarIconId: avatarIconId,
  );
  room.engine.players.add(newPlayer);
  room.clients[clientId] = channel;
  _channelToPlayer[channel] = clientId;
  _channelToRoom[channel] = room.code;

  unawaited(_storeUidAndSetActiveMatch(room, clientId, idToken, room.code));

  var gameJustStarted = false;
  if (room.engine.players.length == room.maxPlayers) {
    room.engine.phase = GamePhase.rolling;
    gameJustStarted = true;
    if (room.testMode) _applyTestMode(room);
  }

  channel.sink.add(
      jsonEncode({'event': 'game_joined', 'data': {'playerCount': room.engine.players.length}}));
  _broadcastGameState(room.code);

  if (gameJustStarted) {
    room.startTimer(() => _handleTimeout(room.code));
    room.startMaxDurationTimer(() {
      _rooms.remove(room.code)?.stopAll();
    });
  }
}

void _handleRollDice(WebSocketChannel? channel, {String? roomCode, String? playerId}) {
  final rCode = roomCode ?? (channel != null ? _channelToRoom[channel] : null);
  final pId = playerId ?? (channel != null ? _channelToPlayer[channel] : null);
  if (rCode == null || pId == null) return;
  final room = _rooms[rCode];
  if (room != null) {
    if (room.engine.currentPlayer.id != pId) return;
    room.stopTimer();

    final diceValue = (room.testMode && room.forcedDice != null)
        ? () { final v = room.forcedDice!; room.forcedDice = null; return v; }()
        : room.engine.rollDice();
    room.engine.currentPlayer.lastDiceValue = diceValue;

    _broadcastDiceResult(rCode, diceValue, pId);

    room.engine.registerSix(room.engine.currentPlayer, diceValue);
    if (room.engine.currentPlayer.consecutiveSixes >= 3) {
      room.engine.penaltyThreeSixes(room.engine.currentPlayer);
      _broadcastGameEvent(rCode, '${room.engine.currentPlayer.name} sacó tres 6.');
      _moveToNextTurnWithSkips(rCode);
    } else if (room.engine.canMoveAnyToken(room.engine.currentPlayer, diceValue)) {
      room.engine.phase = GamePhase.choosingToken;
      _broadcastGameState(rCode);
      room.startTimer(() => _handleTimeout(rCode));
    } else {
      if (diceValue == 6) {
        room.broadcast({'event': 'game_event', 'data': {
          'message': 'player_cant_move',
          'playerId': room.engine.currentPlayer.id,
          'type': 'penalty',
          'args': {'name': room.engine.currentPlayer.name},
        }});
        room.engine.phase = GamePhase.rolling;
        _broadcastGameState(rCode);
        room.startTimer(() => _handleTimeout(rCode));
      } else {
        _moveToNextTurnWithSkips(rCode);
      }
    }
  }
}

Future<void> _handleMoveToken(WebSocketChannel? channel, int tokenId,
    {String? roomCode, String? playerId}) async {
  final rCode = roomCode ?? (channel != null ? _channelToRoom[channel] : null);
  final pId = playerId ?? (channel != null ? _channelToPlayer[channel] : null);
  if (rCode == null || pId == null) return;
  final room = _rooms[rCode];
  if (room == null) return;
  room.stopTimer();
  final token =
      room.engine.currentPlayer.tokens.firstWhere((t) => t.id == tokenId);
  if (!room.engine.canMove(token, room.engine.lastDiceValue)) {
    room.startTimer(() => _handleTimeout(rCode));
    return;
  }
  room.engine.phase = GamePhase.moving;
  _broadcastGameState(rCode);
  await Future.delayed(const Duration(milliseconds: 300));

  final diceValue = room.engine.lastDiceValue;
  for (var i = 0; i < diceValue; i++) {
    room.engine.stepForward(token);
  }

  // Broadcast intermediate position so clients can animate step-by-step.
  if (!token.isFinished) {
    room.broadcast({'event': 'token_stepped', 'data': {
      'playerId': room.engine.currentPlayer.id,
      'tokenId': tokenId,
      'position': token.position,
    }});
  }

  // Wait for step animation on clients (200ms per step + 300ms buffer).
  await Future.delayed(Duration(milliseconds: diceValue * 200 + 300));

  // Capture cell action before applying (position changes after apply).
  BoardAction? cellAction;
  if (!token.isFinished && token.position > 0) {
    cellAction = room.engine.board.getCell(token.position).action;
  }

  // skipTurn + dice-6 exception: cancel both effects instead of applying either.
  final bool skipTurnDice6 = cellAction?.type == BoardActionType.skipTurn && diceValue == 6;
  if (!skipTurnDice6) {
    room.engine.applyCellAction(room.engine.currentPlayer, token);
    if (cellAction != null) {
      _broadcastCellActionEvent(rCode, room.engine.currentPlayer, token, cellAction);
    }
  }

  final bool captured = room.engine.resolveCollisions(token);
  if (captured) {
    room.engine.currentPlayer.extraTurns++;
    room.broadcast({'event': 'game_event', 'data': {
      'message': 'captured_player',
      'playerId': room.engine.currentPlayer.id,
      'type': 'bonus',
      'args': {'name': room.engine.currentPlayer.name},
    }});
  }
  if (token.isFinished) room.engine.currentPlayer.extraTurns++;

  if (room.engine.currentPlayer.isFinished) {
    _notifyAndClearPlayerFinish(rCode, room.engine.currentPlayer);
    room.engine.currentPlayer.extraTurns = 0;
    _moveToNextTurnWithSkips(rCode);
  } else if (room.engine.currentPlayer.extraTurns > 0 || (diceValue == 6 && !skipTurnDice6)) {
    if (room.engine.currentPlayer.extraTurns > 0) {
      room.engine.currentPlayer.extraTurns--;
    }
    room.broadcast({'event': 'game_event', 'data': {
      'message': 'extra_turn',
      'playerId': room.engine.currentPlayer.id,
      'type': 'bonus',
      'args': {'name': room.engine.currentPlayer.name},
    }});
    room.engine.phase = GamePhase.rolling;
    _broadcastGameState(rCode);
    room.startTimer(() => _handleTimeout(rCode));
  } else {
    _moveToNextTurnWithSkips(rCode);
  }
}

void _handleTimeout(String roomCode) {
  final room = _rooms[roomCode];
  if (room == null) return;

  final currentPlayer = room.engine.currentPlayer;
  if (!currentPlayer.isAI && !currentPlayer.isAutoPlaying) {
    currentPlayer.isAutoPlaying = true;
    _broadcastGameState(roomCode);
  }

  if (room.engine.phase == GamePhase.rolling) {
    _handleRollDice(null, roomCode: roomCode, playerId: room.engine.currentPlayer.id);
  } else if (room.engine.phase == GamePhase.choosingToken) {
    Token? best;
    var max = -1;
    for (final t in room.engine.currentPlayer.tokens) {
      if (room.engine.canMove(t, room.engine.lastDiceValue) && t.position > max) {
        max = t.position;
        best = t;
      }
    }
    if (best != null) {
      unawaited(_handleMoveToken(null, best.id,
          roomCode: roomCode, playerId: room.engine.currentPlayer.id));
    } else {
      _moveToNextTurnWithSkips(roomCode);
    }
  }
}

void _moveToNextTurnWithSkips(String roomCode) {
  final room = _rooms[roomCode];
  if (room == null) return;
  room.stopTimer();
  bool skip;
  do {
    room.engine.nextTurn();
    if (room.engine.phase == GamePhase.finished) break;
    if (room.engine.currentPlayer.mustSkipTurn) {
      final skipped = room.engine.currentPlayer;
      skipped.consumeSkip();
      room.broadcast({'event': 'game_event', 'data': {
        'message': 'skip_turn_msg',
        'playerId': skipped.id,
        'type': 'penalty',
        'args': {'name': skipped.name},
      }});
      skip = true;
    } else {
      skip = false;
    }
  } while (skip);

  _broadcastGameState(roomCode);

  if (room.engine.phase == GamePhase.finished) {
    // Notify any remaining players who haven't received you_finished yet
    // (e.g. the last player who was force-finished by nextTurn).
    for (final p in room.engine.finishedPlayers) {
      if (room.playerUids.containsKey(p.id)) {
        _notifyAndClearPlayerFinish(roomCode, p);
      }
    }
    // Keep room alive for 60 s so spectators can see the final board.
    Timer(const Duration(seconds: 60), () => _rooms.remove(roomCode)?.stopAll());
  } else {
    room.startTimer(() => _handleTimeout(roomCode));
  }
}

// --- Helpers de broadcast ---

void _broadcastGameEvent(String r, String m) =>
    _rooms[r]?.broadcast({'event': 'game_event', 'data': {'message': m}});

void _broadcastCellActionEvent(String roomCode, Player player, Token token, BoardAction action) {
  final room = _rooms[roomCode];
  if (room == null) return;
  String msgKey;
  String type;
  final Map<String, String> args = {'name': player.name};
  switch (action.type) {
    case BoardActionType.goToStart:
      msgKey = 'bad_luck_home';
      type = 'penalty';
    case BoardActionType.rollAgain:
      msgKey = 'cell_action_roll_again';
      type = 'bonus';
    case BoardActionType.skipTurn:
      msgKey = 'cell_action_skip_turn';
      type = 'penalty';
    case BoardActionType.moveTo:
      msgKey = 'cell_action_move_to';
      type = (action.targetNumber != null && !token.isFinished && action.targetNumber! > token.position) ? 'bonus' : 'penalty';
      args['cell'] = token.isFinished ? '${room.engine.board.finalPosition}' : '${action.targetNumber}';
  }
  room.broadcast({
    'event': 'game_event',
    'data': {
      'message': msgKey,
      'playerId': player.id,
      'type': type,
      'args': args,
    },
  });
}
void _broadcastDiceResult(String r, int v, String p) =>
    _rooms[r]?.broadcast({'event': 'dice_result', 'data': {'diceValue': v, 'playerId': p}});
void _broadcastInfo(String r, String m) =>
    _rooms[r]?.broadcast({'event': 'info', 'data': {'message': m}});
void _sendError(WebSocketChannel c, String m, {String? code}) =>
    c.sink.add(jsonEncode({'event': 'error', 'data': {'message': m, 'code': code}}));

void _broadcastGameState(String roomCode) {
  final room = _rooms[roomCode];
  if (room == null) return;
  var phaseStr = 'idle';
  switch (room.engine.phase) {
    case GamePhase.idle:
      phaseStr = 'idle';
    case GamePhase.rolling:
      phaseStr = 'rolling';
    case GamePhase.choosingToken:
      phaseStr = 'choosing_token';
    case GamePhase.moving:
      phaseStr = 'moving';
    case GamePhase.finished:
      phaseStr = 'finished';
  }
  room.broadcast({
    'event': 'game_state',
    'data': {
      'roomCode': room.code,
      'timer': room.remainingSeconds,
      'phase': phaseStr,
      'boardSize': room.engine.board.finalPosition,
      'maxPlayers': room.maxPlayers,
      'winners': room.engine.finishedPlayers.map((p) => p.id).toList(),
      'players': room.engine.players.asMap().entries.map((e) {
        final json = e.value.toJson();
        json['index'] = e.key;
        return json;
      }).toList(),
      'currentPlayerId': room.engine.currentPlayer.id,
      'lastDiceValue': room.engine.lastDiceValue,
    },
  });
}

void _applyTestMode(GameRoom room) {
  final target = room.engine.board.finalPosition - 1;
  for (final player in room.engine.players) {
    for (final token in player.tokens) {
      token.position = target;
    }
  }
}
