import 'dart:async';
import 'dart:convert';
import 'dart:math';

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
  Timer? lobbyTimeoutTimer;
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

  void startLobbyTimeoutTimer(void Function() onExpired) {
    lobbyTimeoutTimer?.cancel();
    // 15 minutes to wait for players in the lobby
    lobbyTimeoutTimer = Timer(const Duration(minutes: 15), onExpired);
  }

  void stopAll() {
    turnTimer?.cancel();
    maxDurationTimer?.cancel();
    zombieCleanupTimer?.cancel();
    lobbyTimeoutTimer?.cancel();
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
      if (!room.engine.finishedPlayers.contains(player)) {
        room.engine.finishedPlayers.add(player);
      }
      
      _notifyAndClearPlayerFinish(roomCode, player, silent: true, reason: 'abandonment');
      room.engine.phase = GamePhase.finished;
      _broadcastGameState(roomCode);
      
      // Schedule cleanup
      Timer(const Duration(seconds: 30), () => _closeRoom(room));
      return;
    }
  }

  if (humansRemaining.isEmpty) _closeRoom(room);
}

/// Removes [room] if it is still the room registered under its code (a
/// delayed timer must not close a newer room that reused the code), stops its
/// timers, frees every player's match bookkeeping and, if [errorCode] is
/// given, tells the connected clients why.
void _closeRoom(GameRoom room, {String? errorCode}) {
  if (_rooms[room.code] != room) return;
  _rooms.remove(room.code);
  room.stopAll();
  if (errorCode != null) {
    room.broadcast({
      'event': 'error',
      'data': {'code': errorCode, 'message': errorCode},
    });
  }
  for (final uid in room.playerUids.values) {
    unawaited(_clearActiveMatch(uid));
  }
  room.playerUids.clear();
  for (final player in room.engine.players) {
    _reconnectionTimers.remove(player.id)?.cancel();
  }
  for (final channel in room.clients.values) {
    _channelToRoom.remove(channel);
    _channelToPlayer.remove(channel);
  }
  room.clients.clear();
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

          // Pre-game waiting room: remove immediately to free slot and update count.
          if (room.engine.phase == GamePhase.idle) {
            room.clients.remove(playerId);
            room.engine.players.removeWhere((p) => p.id == playerId);
            final uid = room.playerUids.remove(playerId);
            if (uid != null) unawaited(_clearActiveMatch(uid));

            _broadcastGameState(roomCode);

            if (room.clients.isEmpty) {
              room.zombieCleanupTimer?.cancel();
              // 5 minutes grace period for empty lobby
              room.zombieCleanupTimer = Timer(const Duration(minutes: 5), () {
                if (room.clients.isEmpty) _closeRoom(room);
              });
            }
          } else {
            if (player.id.isNotEmpty) {
              player.isConnected = false;
              player.isAutoPlaying = true;
              _broadcastGameState(roomCode);
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
                if (room.clients.isEmpty) _closeRoom(room);
              });
            }
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

          // A channel already seated in a room speaks only for that seat, so
          // a client cannot act (surrender, chat, auto-play) as another player.
          final boundId = _channelToPlayer[channel];
          if (boundId != null && boundId != clientId) {
            _sendError(channel, 'clientId no coincide.', code: 'CLIENT_MISMATCH');
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
              // clientIds are broadcast to every player, so knowing one is not
              // proof of owning the seat: require the same Firebase account.
              final seatUid = userRoom.playerUids[clientId];
              if (seatUid != null && seatUid != syncUid) {
                _sendError(channel, 'No puedes unirte a esta partida.',
                    code: 'CANNOT_REJOIN');
                return;
              }
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
            final targetMaxPlayers = _clampMaxPlayers(data['maxPlayers']);
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
              // Si no hay salas, creamos una pública automáticamente para esperar a otros
              _createAndJoinRoom(
                channel, clientId, data['name'] as String?,
                targetMaxPlayers,
                true, // isPublic
                level, avatarType, avatarIconId, idToken,
              );
            }
            return;
          }

          if (eventName == 'create_game') {
            if (!await verifyIdToken(idToken)) {
              _sendError(channel, 'Auth required.', code: 'UNAUTHORIZED');
              return;
            }
            // Test rooms let their members force dice, so they are only
            // available when the operator allows them and are never public.
            final testMode =
                testModeAllowed && ((data['testMode'] as bool?) ?? false);
            _createAndJoinRoom(
              channel, clientId, data['name'] as String?,
              _clampMaxPlayers(data['maxPlayers']),
              !testMode && ((data['isPublic'] as bool?) ?? false),
              level, avatarType, avatarIconId, idToken,
              testMode: testMode,
            );
          }

          if (eventName == 'join_game') {
            if (!await verifyIdToken(idToken)) {
              _sendError(channel, 'Auth required.', code: 'UNAUTHORIZED');
              return;
            }
            final room = _rooms[data['roomCode'] ?? ''];
            final seatUid = room?.playerUids[clientId];
            if (seatUid != null && seatUid != await getUidFromToken(idToken)) {
              _sendError(channel, 'No puedes unirte a esta partida.',
                  code: 'CANNOT_REJOIN');
              return;
            }
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
            // Only accepted from the current player when the server agrees
            // there is no legal move for the rolled value.
            final roomCode = _channelToRoom[channel];
            final room = roomCode != null ? _rooms[roomCode] : null;
            if (room != null &&
                room.engine.players.isNotEmpty &&
                room.engine.currentPlayer.id == _channelToPlayer[channel] &&
                room.engine.phase == GamePhase.choosingToken &&
                !room.engine.canMoveAnyToken(
                    room.engine.currentPlayer, room.engine.lastDiceValue)) {
              _moveToNextTurnWithSkips(roomCode!);
            }
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
                final message = data['message'];
                if (player.id.isNotEmpty &&
                    message is String &&
                    message.trim().isNotEmpty) {
                  room.broadcast({
                    'event': 'chat',
                    'data': {
                      'sender': player.name,
                      'senderId': clientId,
                      'message': message.length > _maxChatLength
                          ? message.substring(0, _maxChatLength)
                          : message,
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
            channel.sink.add(jsonEncode({'event': 'surrendered', 'data': <String, dynamic>{}}));

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

const _maxChatLength = 200;
final _roomCodeRandom = Random.secure();

/// A random, currently unused 5-digit room code. Random (not clock-based) so
/// codes can't be guessed and two rooms created in the same tick don't collide.
String _newRoomCode() {
  String code;
  do {
    code = _roomCodeRandom.nextInt(100000).toString().padLeft(5, '0');
  } while (_rooms.containsKey(code));
  return code;
}

/// Parchís seats 2–4 players; anything else from the client falls back into range.
int _clampMaxPlayers(Object? value) =>
    ((value is int) ? value : 2).clamp(2, 4);

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
  final roomCode = _newRoomCode();
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

  room.startLobbyTimeoutTimer(() {
    if (room.engine.phase == GamePhase.idle) {
      _closeRoom(room, errorCode: 'LOBBY_TIMEOUT');
    }
  });

  if (room.engine.phase == GamePhase.rolling) {
    room.lobbyTimeoutTimer?.cancel();
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
      jsonEncode({'event': 'game_joined', 'data': {
        'roomCode': room.code,
        'playerCount': room.engine.players.length,
        'maxPlayers': room.maxPlayers,
      }}));
  _broadcastGameState(room.code);

  if (gameJustStarted) {
    room.lobbyTimeoutTimer?.cancel();
    room.startTimer(() => _handleTimeout(room.code));
    room.startMaxDurationTimer(() {
      _closeRoom(room, errorCode: 'MATCH_TIMEOUT');
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
    if (room.engine.phase != GamePhase.rolling) return;
    room.stopTimer();

    final diceValue = (room.testMode && room.forcedDice != null)
        ? () { 
            final v = room.forcedDice!; 
            room.forcedDice = null; 
            room.engine.lastDiceValue = v; // ✅ Sincronizar con el engine
            return v; 
          }()
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
  // Only the current player may move, and only once per roll: the phase flips
  // to `moving` synchronously below, so a double-tap or a move racing the
  // timeout is rejected here.
  if (room.engine.currentPlayer.id != pId) return;
  if (room.engine.phase != GamePhase.choosingToken) return;
  final tokens = room.engine.currentPlayer.tokens.where((t) => t.id == tokenId);
  if (tokens.isEmpty) return;
  final token = tokens.first;
  room.stopTimer();
  if (!room.engine.canMove(token, room.engine.lastDiceValue)) {
    room.startTimer(() => _handleTimeout(rCode));
    return;
  }
  room.engine.phase = GamePhase.moving;
  _broadcastGameState(rCode);
  await Future<void>.delayed(const Duration(milliseconds: 300));
  // The room may have been closed while we waited.
  if (_rooms[rCode] != room) return;

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
  await Future<void>.delayed(Duration(milliseconds: diceValue * 200 + 300));
  if (_rooms[rCode] != room) return;

  // Capture cell action before applying (position changes after apply).
  BoardAction? cellAction;
  if (!token.isFinished && token.position > 0) {
    cellAction = room.engine.board.getCell(token.position).action;
  }

  bool bonusSent = false;

  // skipTurn + dice-6 exception: cancel both effects instead of applying either.
  final bool skipTurnDice6 = cellAction?.type == BoardActionType.skipTurn && diceValue == 6;
  if (!skipTurnDice6) {
    room.engine.applyCellAction(room.engine.currentPlayer, token);
    if (cellAction != null) {
      _broadcastCellActionEvent(rCode, room.engine.currentPlayer, token, cellAction);
      if (cellAction.type == BoardActionType.rollAgain) {
        bonusSent = true;
      }
    }
  }

  final capturedPlayers = room.engine.resolveCollisions(token);
  if (capturedPlayers.isNotEmpty) bonusSent = true;
  for (final capturedPlayer in capturedPlayers) {
    // room.engine.currentPlayer.extraTurns++ ya se hace en resolveCollisions del motor
    room.broadcast({'event': 'game_event', 'data': {
      'message': 'captured_player',
      'playerId': room.engine.currentPlayer.id,
      'type': 'bonus',
      'args': {
        'name': room.engine.currentPlayer.name,
        'other': capturedPlayer.name,
      },
    }});
  }

  // Si sacó un 6 y no cayó en casilla de saltar turno, gana un turno extra natural
  if (diceValue == 6 && !skipTurnDice6) {
    room.engine.currentPlayer.extraTurns++;
  }

  if (room.engine.currentPlayer.isFinished) {
    bonusSent = true;
    _notifyAndClearPlayerFinish(rCode, room.engine.currentPlayer);
    room.engine.currentPlayer.extraTurns = 0;
    _moveToNextTurnWithSkips(rCode);
  } else if (room.engine.currentPlayer.extraTurns > 0) {
    room.engine.currentPlayer.extraTurns--;

    // Solo enviamos 'extra_turn' si no hemos enviado ya un mensaje de bonus específico
    // o si aún quedan más turnos extra acumulados (ej: sacó un 6 Y capturó).
    if (!bonusSent || room.engine.currentPlayer.extraTurns > 0) {
      room.broadcast({'event': 'game_event', 'data': {
        'message': 'extra_turn',
        'playerId': room.engine.currentPlayer.id,
        'type': 'bonus',
        'args': {'name': room.engine.currentPlayer.name},
      }});
    }

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

  // --- Compensación Silenciosa de Penalizaciones ---
  // Si TODOS los jugadores activos tienen al menos un salto de turno pendiente,
  // les restamos uno a todos silenciosamente para evitar ráfagas de mensajes 
  // y permitir que el juego fluya si todos están en la misma situación.
  final activePlayers = room.engine.players.where((p) => !p.isFinished).toList();
  if (activePlayers.isNotEmpty && activePlayers.every((p) => p.mustSkipTurn)) {
    for (final p in activePlayers) {
      p.consumeSkip();
    }
  }

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
    Timer(const Duration(seconds: 60), () => _closeRoom(room));
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
      type = 'move';
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
void _sendError(WebSocketChannel c, String m, {String? code}) =>
    c.sink.add(jsonEncode({'event': 'error', 'data': {'message': m, 'code': code}}));

void _broadcastGameState(String roomCode) {
  final room = _rooms[roomCode];
  // An emptied lobby has no currentPlayer to serialize (and no one to tell).
  if (room == null || room.engine.players.isEmpty) return;
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
