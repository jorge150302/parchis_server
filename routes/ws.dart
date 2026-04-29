import 'dart:async';
import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:dart_frog_web_socket/dart_frog_web_socket.dart';
import 'package:parchis_server/game_engine.dart';
import 'package:parchis_server/logic/board_generator.dart';
import 'package:parchis_server/logic/board_presets.dart';
import 'package:parchis_server/models/board_action.dart';
import 'package:parchis_server/models/player.dart';

// --- Clases de Soporte ---

class GameRoom {
  GameRoom(this.code, this.engine, this.maxPlayers, {this.isPublic = false});

  final String code;
  final GameEngine engine;
  final int maxPlayers;
  bool isPublic;
  final Map<String, WebSocketChannel> clients = {}; // PlayerID -> Channel

  Timer? turnTimer;
  int remainingSeconds = 20;

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

  void startTimer(void Function() onTimeout) {
    stopTimer();
    
    final currentPlayer = engine.currentPlayer;
    
    // REQUERIMIENTO AFK: Si el jugador es IA o está en modo Auto-Play, el servidor ejecuta la acción
    // tras un retardo de cortesía (6s) para que el resto de jugadores vean qué sucede.
    if (currentPlayer.isAI || currentPlayer.isAutoPlaying) {
      turnTimer = Timer(const Duration(milliseconds: 6000), onTimeout);
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

// Temporizadores de limpieza para reconexión (clientId -> Timer)
final Map<String, Timer> _reconnectionTimers = {};

// Simulamos una base de datos de usuarios y reportes en memoria
final Map<String, Map<String, dynamic>> _userDatabase = {};
final List<Map<String, dynamic>> _playerReports = [];

Future<Response> onRequest(RequestContext context) async {
  final handler = webSocketHandler((channel, protocol) {
    
    void handleDisconnect() {
      final roomCode = _channelToRoom[channel];
      final playerId = _channelToPlayer[channel];
      
      if (roomCode != null && playerId != null) {
        final room = _rooms[roomCode];
        if (room != null) {
          // Buscamos al jugador para actualizar su estado de conexión
          final player = room.engine.players.firstWhere((p) => p.id == playerId, orElse: () => Player(id: '', name: ''));
          if (player.id.isNotEmpty) {
            // REQUERIMIENTO: Marcar como desconectado y activar Auto-Play
            player.isConnected = false;
            player.isAutoPlaying = true;
            _broadcastGameState(roomCode);
          }

          // 1. Iniciamos un temporizador de gracia de 2 minutos para la reconexión
          _reconnectionTimers[playerId]?.cancel();
          _reconnectionTimers[playerId] = Timer(const Duration(minutes: 2), () {
            // Si pasan 2 minutos sin reconexión, marcamos como IA definitiva
            final p = room.engine.players.firstWhere((p) => p.id == playerId, orElse: () => Player(id: '', name: ''));
            if (p.id.isNotEmpty) {
              p.isAI = true;
              _broadcastGameState(roomCode);
              _broadcastInfo(roomCode, '${p.name} abandonó la partida definitivamente.');
            }
            _reconnectionTimers.remove(playerId);
          });

          // 2. Quitamos el canal activo pero mantenemos al jugador en la sala
          room.clients.remove(playerId);
          _broadcastInfo(roomCode, '${playerId} se ha desconectado. Esperando reconexión (2 min)...');
        }
      }
      _channelToPlayer.remove(channel);
      _channelToRoom.remove(channel);
    }

    channel.stream.listen(
      (dynamic message) {
        try {
          final event = jsonDecode(message as String) as Map<String, dynamic>;
          final eventName = event['event'] as String;
          final data = (event['data'] ?? <String, dynamic>{}) as Map<String, dynamic>;
          final clientId = event['clientId'] as String?;
          final level = event['level'] as int? ?? 1; // REQUERIMIENTO: Extraer nivel del payload

          // REQUERIMIENTO: Soporte para Ping/Pong
          if (eventName == 'ping') {
            channel.sink.add(jsonEncode({'event': 'pong'}));
            return;
          }

          if (clientId == null) {
            _sendError(channel, 'clientId requerido.');
            return;
          }

          // --- EVENTO: request_sync ---
          if (eventName == 'request_sync') {
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
              player.isConnected = true;
              player.level = level; // REQUERIMIENTO: Actualizar nivel al sincronizar

              userRoom.clients[clientId] = channel;
              _channelToPlayer[channel] = clientId;
              _channelToRoom[channel] = userRoom.code;
              _broadcastGameState(userRoom.code);
              if (userRoom.engine.currentPlayer.id == clientId && userRoom.engine.phase != GamePhase.idle) {
                userRoom.startTimer(() => _handleTimeout(userRoom!.code));
              }
            } else {
              _sendError(channel, 'No se encontró una partida activa para este ID.');
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
              channel.sink.add(jsonEncode({'event': 'report_received', 'data': {'message': 'Reporte registrado.'}}));
            }
            return;
          }

          if (eventName == 'delete_user_data') {
            _userDatabase.remove(data['playerId'] ?? clientId);
            channel.sink.add(jsonEncode({'event': 'user_data_deleted', 'data': {'message': 'Datos eliminados.'}}));
            return;
          }

          if (eventName == 'find_match') {
            final targetMaxPlayers = (data['maxPlayers'] as int?) ?? 2;
            GameRoom? foundRoom;
            for (final room in _rooms.values) {
              if (room.isPublic && room.maxPlayers == targetMaxPlayers && 
                  room.engine.players.length < room.maxPlayers && room.engine.phase == GamePhase.idle) {
                foundRoom = room; break;
              }
            }
            if (foundRoom != null) {
              _joinToRoom(channel, foundRoom, clientId, data['name'] as String?, level);
            } else {
              _sendError(channel, 'No hay salas.', code: 'MATCH_NOT_FOUND');
            }
            return;
          }

          if (eventName == 'create_game') {
            _createAndJoinRoom(channel, clientId, data['name'] as String?, (data['maxPlayers'] as int?) ?? 2, (data['isPublic'] as bool?) ?? false, level);
          }

          if (eventName == 'join_game') {
            final room = _rooms[data['roomCode'] ?? ''];
            if (room != null) _joinToRoom(channel, room, clientId, data['name'] as String?, level);
            else _sendError(channel, 'La sala no existe.');
          }

          if (eventName == 'roll_dice') {
            _updatePlayerLevel(clientId, level);
            _handleRollDice(channel);
          }

          if (eventName == 'move_token') {
            _updatePlayerLevel(clientId, level);
            final tokenId = data['tokenId'] as int?;
            if (tokenId != null) _handleMoveToken(channel, tokenId);
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
                final player = room.engine.players.firstWhere((p) => p.id == clientId, orElse: () => Player(id: '', name: ''));
                if (player.id.isNotEmpty) {
                  room.broadcast({
                    'event': 'chat',
                    'data': {'sender': player.name, 'senderId': clientId, 'message': data['message']},
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

          // --- REQUERIMIENTO AFK: toggle_auto_play ---
          if (eventName == 'toggle_auto_play') {
            final value = data['value'] as bool? ?? false;
            final roomCode = _channelToRoom[channel];
            if (roomCode != null) {
              final room = _rooms[roomCode];
              if (room != null) {
                final player = room.engine.players.firstWhere((p) => p.id == clientId, orElse: () => Player(id: '', name: ''));
                if (player.id.isNotEmpty) {
                  player.isAutoPlaying = value;
                  _broadcastGameState(roomCode);
                  if (room.engine.currentPlayer.id == clientId && room.engine.phase != GamePhase.idle) {
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
    final player = room.engine.players.firstWhere((p) => p.id == clientId, orElse: () => Player(id: '', name: ''));
    if (player.id.isNotEmpty) {
      player.level = level;
      break;
    }
  }
}

// --- Funciones de Gestión de Salas ---

void _createAndJoinRoom(WebSocketChannel channel, String clientId, String? name, int maxPlayers, bool isPublic, int level) {
  final roomCode = (DateTime.now().millisecondsSinceEpoch % 100000).toString().padLeft(5, '0');
  final board = generateBoard(classicActionPositions, classicActions);
  final engine = GameEngine(board: board, players: []);
  final room = GameRoom(roomCode, engine, maxPlayers, isPublic: isPublic);
  _rooms[roomCode] = room;
  final newPlayer = Player(id: clientId, name: name ?? 'Anfitrión', level: level);
  room.engine.players.add(newPlayer);
  room.clients[clientId] = channel;
  _channelToPlayer[channel] = clientId;
  _channelToRoom[channel] = roomCode;

  if (room.engine.players.length == room.maxPlayers) {
    room.engine.phase = GamePhase.rolling;
  }

  channel.sink.add(jsonEncode({'event': 'game_created', 'data': {'roomCode': roomCode}}));
  _broadcastGameState(roomCode);
  _broadcastInfo(roomCode, '¡ATENCIÓN! El servidor está en MODO PRUEBA con un tablero de 10 casillas.');

  if (room.engine.phase == GamePhase.rolling) {
    room.startTimer(() => _handleTimeout(roomCode));
  }
}

void _joinToRoom(WebSocketChannel channel, GameRoom room, String clientId, String? name, int level) {
  final existingPlayerIndex = room.engine.players.indexWhere((p) => p.id == clientId);
  if (existingPlayerIndex != -1) {
    _reconnectionTimers[clientId]?.cancel();
    _reconnectionTimers.remove(clientId);
    final player = room.engine.players[existingPlayerIndex];
    player.isAI = false; 
    player.isConnected = true;
    player.level = level; // REQUERIMIENTO: Actualizar nivel al reconectar
    room.clients[clientId] = channel;
    _channelToPlayer[channel] = clientId;
    _channelToRoom[channel] = room.code;
    channel.sink.add(jsonEncode({'event': 'game_joined', 'data': {'reconnected': true}}));
    _broadcastGameState(room.code);
    if (room.engine.currentPlayer.id == clientId && room.engine.phase != GamePhase.idle) {
      room.startTimer(() => _handleTimeout(room.code));
    }
    return;
  }
  if (room.engine.phase != GamePhase.idle || room.engine.players.length >= room.maxPlayers) {
    _sendError(channel, 'Sala no disponible.'); return;
  }

  final newPlayer = Player(id: clientId, name: name ?? 'Jugador ${room.engine.players.length + 1}', level: level);
  room.engine.players.add(newPlayer);
  room.clients[clientId] = channel;
  _channelToPlayer[channel] = clientId;
  _channelToRoom[channel] = room.code;

  bool gameJustStarted = false;
  if (room.engine.players.length == room.maxPlayers) {
    room.engine.phase = GamePhase.rolling;
    gameJustStarted = true;
  }

  channel.sink.add(jsonEncode({'event': 'game_joined', 'data': {'playerCount': room.engine.players.length}}));
  _broadcastGameState(room.code);

  if (gameJustStarted) {
    room.startTimer(() => _handleTimeout(room.code));
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
    
    final diceValue = room.engine.rollDice();
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
        room.engine.phase = GamePhase.rolling; 
        _broadcastGameState(rCode); 
        room.startTimer(() => _handleTimeout(rCode)); 
      } else {
        _moveToNextTurnWithSkips(rCode);
      }
    }
  }
}

void _handleMoveToken(WebSocketChannel? channel, int tokenId, {String? roomCode, String? playerId}) {
  final rCode = roomCode ?? (channel != null ? _channelToRoom[channel] : null);
  final pId = playerId ?? (channel != null ? _channelToPlayer[channel] : null);
  if (rCode == null || pId == null) return;
  final room = _rooms[rCode];
  if (room == null) return;
  room.stopTimer();
  final token = room.engine.currentPlayer.tokens.firstWhere((t) => t.id == tokenId);
  if (!room.engine.canMove(token, room.engine.lastDiceValue)) { room.startTimer(() => _handleTimeout(rCode)); return; }
  room.engine.phase = GamePhase.moving;
  _broadcastGameState(rCode);
  Timer(const Duration(milliseconds: 500), () {
    final diceValue = room.engine.lastDiceValue;
    for (var i = 0; i < diceValue; i++) room.engine.stepForward(token);
    room.engine.applyCellAction(room.engine.currentPlayer, token);
    if (room.engine.resolveCollisions(token)) room.engine.currentPlayer.extraTurns++;
    if (token.isFinished) room.engine.currentPlayer.extraTurns++;
    if (room.engine.currentPlayer.isFinished) { room.engine.currentPlayer.extraTurns = 0; _moveToNextTurnWithSkips(rCode); }
    else if (room.engine.currentPlayer.extraTurns > 0 || diceValue == 6) {
      if (room.engine.currentPlayer.extraTurns > 0) room.engine.currentPlayer.extraTurns--;
      room.engine.phase = GamePhase.rolling; _broadcastGameState(rCode); room.startTimer(() => _handleTimeout(rCode));
    } else _moveToNextTurnWithSkips(rCode);
    if (room.engine.phase == GamePhase.finished) Timer(const Duration(seconds: 10), () => _rooms.remove(rCode));
  });
}

void _handleTimeout(String roomCode) {
  final room = _rooms[roomCode];
  if (room == null) return;

  // REQUERIMIENTO AFK: Si el timer llega a 0 sin acción (no es IA y no estaba en autoplay), activamos autoplay
  final currentPlayer = room.engine.currentPlayer;
  if (!currentPlayer.isAI && !currentPlayer.isAutoPlaying) {
    currentPlayer.isAutoPlaying = true;
    _broadcastInfo(roomCode, '${currentPlayer.name} ha entrado en modo automático por inactividad.');
    _broadcastGameState(roomCode);
  }

  if (room.engine.phase == GamePhase.rolling) _handleRollDice(null, roomCode: roomCode, playerId: room.engine.currentPlayer.id);
  else if (room.engine.phase == GamePhase.choosingToken) {
    Token? best; int max = -1;
    for (final t in room.engine.currentPlayer.tokens) {
      if (room.engine.canMove(t, room.engine.lastDiceValue) && t.position > max) { max = t.position; best = t; }
    }
    if (best != null) _handleMoveToken(null, best.id, roomCode: roomCode, playerId: room.engine.currentPlayer.id);
    else _moveToNextTurnWithSkips(roomCode);
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
    if (room.engine.currentPlayer.mustSkipTurn) { room.engine.currentPlayer.consumeSkip(); skip = true; }
    else skip = false;
  } while (skip);
  _broadcastGameState(roomCode);
  if (room.engine.phase != GamePhase.finished) room.startTimer(() => _handleTimeout(roomCode));
}

// --- Helpers ---

void _broadcastGameEvent(String r, String m) => _rooms[r]?.broadcast({'event': 'game_event', 'data': {'message': m}});
void _broadcastDiceResult(String r, int v, String p) => _rooms[r]?.broadcast({'event': 'dice_result', 'data': {'diceValue': v, 'playerId': p}});
void _broadcastInfo(String r, String m) => _rooms[r]?.broadcast({'event': 'info', 'data': {'message': m}});
void _sendError(WebSocketChannel c, String m, {String? code}) => c.sink.add(jsonEncode({'event': 'error', 'data': {'message': m, 'code': code}}));

void _broadcastGameState(String roomCode) {
  final room = _rooms[roomCode];
  if (room == null) return;
  String phaseStr = 'idle';
  switch (room.engine.phase) {
    case GamePhase.idle: phaseStr = 'idle'; break;
    case GamePhase.rolling: phaseStr = 'rolling'; break;
    case GamePhase.choosingToken: phaseStr = 'choosing_token'; break;
    case GamePhase.moving: phaseStr = 'moving'; break;
    case GamePhase.finished: phaseStr = 'finished'; break;
  }
  room.broadcast({
    'event': 'game_state',
    'data': {
      'roomCode': room.code, 
      'timer': room.remainingSeconds, 
      'phase': phaseStr,
      'boardSize': room.engine.board.finalPosition,
      'winners': room.engine.finishedPlayers.map((p) => p.id).toList(),
      'players': room.engine.players.asMap().entries.map((e) {
        final json = e.value.toJson(); json['index'] = e.key; return json;
      }).toList(),
      'currentPlayerId': room.engine.currentPlayer.id,
      'lastDiceValue': room.engine.lastDiceValue,
    },
  });
}
