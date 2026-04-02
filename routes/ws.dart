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
      try {
        channel.sink.add(message);
      } catch (_) {}
    }
  }

  void stopTimer() {
    turnTimer?.cancel();
    turnTimer = null;
  }

  void startTimer(void Function() onTimeout) {
    stopTimer();
    
    final currentPlayer = engine.currentPlayer;
    
    // Si el jugador es IA o está en modo Auto-Play, jugamos rápido (1s delay)
    if (currentPlayer.isAI || (currentPlayer.isAutoPlaying)) {
      remainingSeconds = 0;
      _broadcastTimer();
      turnTimer = Timer(const Duration(milliseconds: 1000), () {
        try { onTimeout(); } catch (_) {}
      });
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

Future<Response> onRequest(RequestContext context) async {
  final handler = webSocketHandler((channel, protocol) {
    
    void handleDisconnect() {
      final roomCode = _channelToRoom[channel];
      final playerId = _channelToPlayer[channel];
      
      if (roomCode != null && playerId != null) {
        final room = _rooms[roomCode];
        if (room != null) {
          _reconnectionTimers[playerId]?.cancel();
          _reconnectionTimers[playerId] = Timer(const Duration(minutes: 2), () {
            final p = room.engine.players.where((p) => p.id == playerId).firstOrNull;
            if (p != null) {
              p.isAI = true;
              _broadcastGameState(roomCode);
            }
            _reconnectionTimers.remove(playerId);
          });
          room.clients.remove(playerId);
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

          if (clientId == null) return;

          // --- Evento: toggle_auto_play ---
          if (eventName == 'toggle_auto_play') {
            final roomCode = _channelToRoom[channel];
            if (roomCode != null) {
              final room = _rooms[roomCode];
              final player = room?.engine.players.where((p) => p.id == clientId).firstOrNull;
              if (player != null) {
                player.isAutoPlaying = (data['value'] as bool? ?? !player.isAutoPlaying);
                _broadcastGameState(roomCode);
                if (player.isAutoPlaying && room?.engine.currentPlayer.id == clientId) {
                  room?.startTimer(() => _handleTimeout(roomCode));
                }
              }
            }
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
              userRoom.clients[clientId] = channel;
              _channelToPlayer[channel] = clientId;
              _channelToRoom[channel] = userRoom.code;
              _broadcastGameState(userRoom.code);
              if (userRoom.engine.currentPlayer.id == clientId && userRoom.engine.phase != GamePhase.idle) {
                userRoom.startTimer(() => _handleTimeout(userRoom.code));
              }
            }
            return;
          }

          if (eventName == 'create_game') {
            _createAndJoinRoom(channel, clientId, data['name'] as String?, (data['maxPlayers'] as int? ?? 2), (data['isPublic'] as bool? ?? false));
          } else if (eventName == 'join_game') {
            final room = _rooms[data['roomCode'] as String? ?? ''];
            if (room != null) _joinToRoom(channel, room, clientId, data['name'] as String?);
          } else if (eventName == 'roll_dice') {
            _handleRollDice(channel);
          } else if (eventName == 'move_token') {
            final tokenId = data['tokenId'] as int?;
            if (tokenId != null) _handleMoveToken(channel, tokenId);
          } else if (eventName == 'chat_message' || eventName == 'quick_chat') {
            final roomCode = _channelToRoom[channel];
            if (roomCode != null) {
              final room = _rooms[roomCode];
              final player = room?.engine.players.where((p) => p.id == clientId).firstOrNull;
              if (player != null) {
                room?.broadcast({
                  'event': eventName == 'chat_message' ? 'chat' : 'quick_chat',
                  'data': {'senderId': clientId, 'sender': player.name, 'message': data['message']},
                });
              }
            }
          }
        } catch (e) { print('WS Error: $e'); }
      },
      onDone: handleDisconnect,
      onError: (_) => handleDisconnect(),
    );
  });
  return handler(context);
}

// --- Lógica de Juego ---

void _handleRollDice(WebSocketChannel? channel, {String? roomCode, String? playerId}) {
  final rCode = roomCode ?? _channelToRoom[channel];
  final pId = playerId ?? _channelToPlayer[channel];
  if (rCode == null || pId == null) return;
  final room = _rooms[rCode];
  if (room == null || room.engine.currentPlayer.id != pId) return;

  if (channel != null) room.engine.currentPlayer.isAutoPlaying = false;
  room.stopTimer();
  
  final diceValue = room.engine.rollDice();
  room.engine.currentPlayer.lastDiceValue = diceValue;
  _broadcastDiceResult(rCode, diceValue, pId);
  room.engine.registerSix(room.engine.currentPlayer, diceValue);

  if (room.engine.reachedThreeSixes(room.engine.currentPlayer)) {
    room.engine.penaltyThreeSixes(room.engine.currentPlayer);
    _moveToNextTurnWithSkips(rCode);
  } else if (room.engine.canMoveAnyToken(room.engine.currentPlayer, diceValue)) {
    room.engine.phase = GamePhase.choosingToken;
    _broadcastGameState(rCode);
    room.startTimer(() => _handleTimeout(rCode));
  } else {
    // REQUISITO: Si no hay movimientos válidos, pasar turno automáticamente.
    // En Parchís, si sacas un 6 y no puedes mover, pierdes el turno extra.
    _broadcastInfo(rCode, '${room.engine.currentPlayer.name} no tiene movimientos válidos.');
    _moveToNextTurnWithSkips(rCode);
  }
}

void _handleMoveToken(WebSocketChannel? channel, int tokenId, {String? roomCode, String? playerId}) {
  final rCode = roomCode ?? _channelToRoom[channel];
  final pId = playerId ?? _channelToPlayer[channel];
  if (rCode == null || pId == null) return;
  final room = _rooms[rCode];
  if (room == null || room.engine.currentPlayer.id != pId) return;

  if (channel != null) room.engine.currentPlayer.isAutoPlaying = false;
  room.stopTimer();

  final token = room.engine.currentPlayer.tokens.where((t) => t.id == tokenId).firstOrNull;
  if (token == null || !room.engine.canMove(token, room.engine.lastDiceValue)) {
    room.startTimer(() => _handleTimeout(rCode));
    return;
  }
  
  room.engine.phase = GamePhase.moving;
  _broadcastGameState(rCode);

  Timer(const Duration(milliseconds: 600), () {
    try {
      final diceValue = room.engine.lastDiceValue;
      for (var i = 0; i < diceValue; i++) room.engine.stepForward(token);
      room.engine.applyCellAction(room.engine.currentPlayer, token);
      room.engine.resolveCollisions(token);
      
      if (room.engine.currentPlayer.isFinished || (diceValue != 6 && room.engine.currentPlayer.extraTurns == 0)) {
        _moveToNextTurnWithSkips(rCode);
      } else {
        room.engine.phase = GamePhase.rolling;
        _broadcastGameState(rCode);
        room.startTimer(() => _handleTimeout(rCode));
      }
    } catch (e) { print('Move Error: $e'); }
  });
}

void _handleTimeout(String roomCode) {
  final room = _rooms[roomCode];
  if (room == null) return;

  if (!room.engine.currentPlayer.isAI) {
    room.engine.currentPlayer.isAutoPlaying = true;
    _broadcastGameState(roomCode);
  }

  if (room.engine.phase == GamePhase.rolling) {
    _handleRollDice(null, roomCode: roomCode, playerId: room.engine.currentPlayer.id);
  } else if (room.engine.phase == GamePhase.choosingToken) {
    Token? best; int maxPos = -1;
    for (final t in room.engine.currentPlayer.tokens) {
      if (room.engine.canMove(t, room.engine.lastDiceValue) && t.position > maxPos) {
        maxPos = t.position; best = t;
      }
    }
    if (best != null) _handleMoveToken(null, best.id, roomCode: roomCode, playerId: room.engine.currentPlayer.id);
    else _moveToNextTurnWithSkips(roomCode);
  }
}

void _moveToNextTurnWithSkips(String roomCode) {
  final room = _rooms[roomCode];
  if (room == null) return;
  bool skip = false;
  do {
    room.engine.nextTurn();
    if (room.engine.phase == GamePhase.finished) break;
    if (room.engine.currentPlayer.mustSkipTurn) { 
      room.engine.currentPlayer.consumeSkip(); 
      skip = true; 
    } else { skip = false; }
  } while (skip);
  _broadcastGameState(roomCode);
  if (room.engine.phase != GamePhase.finished) room.startTimer(() => _handleTimeout(roomCode));
}

// --- Gestión de Salas ---

void _createAndJoinRoom(WebSocketChannel channel, String clientId, String? name, int max, bool pub) {
  final code = (DateTime.now().millisecondsSinceEpoch % 100000).toString().padLeft(5, '0');
  final engine = GameEngine(board: generateBoard(classicActionPositions, classicActions), players: [Player(id: clientId, name: name ?? 'P1')]);
  final room = GameRoom(code, engine, max, isPublic: pub);
  _rooms[code] = room;
  room.clients[clientId] = channel;
  _channelToPlayer[channel] = clientId; _channelToRoom[channel] = code;
  _broadcastGameState(code);
}

void _joinToRoom(WebSocketChannel channel, GameRoom room, String clientId, String? name) {
  if (room.engine.players.any((p) => p.id == clientId)) return;
  room.engine.players.add(Player(id: clientId, name: name ?? 'P${room.engine.players.length + 1}'));
  room.clients[clientId] = channel;
  _channelToPlayer[channel] = clientId; _channelToRoom[channel] = room.code;
  if (room.engine.players.length == room.maxPlayers) room.engine.phase = GamePhase.rolling;
  _broadcastGameState(room.code);
  if (room.engine.phase == GamePhase.rolling) room.startTimer(() => _handleTimeout(room.code));
}

void _broadcastDiceResult(String r, int v, String p) => _rooms[r]?.broadcast({'event': 'dice_result', 'data': {'diceValue': v, 'playerId': p}});
void _broadcastInfo(String r, String m) => _rooms[r]?.broadcast({'event': 'info', 'data': {'message': m}});
void _broadcastGameState(String roomCode) {
  final room = _rooms[roomCode];
  if (room == null) return;
  room.broadcast({
    'event': 'game_state',
    'data': {
      'roomCode': room.code, 'timer': room.remainingSeconds, 'phase': room.engine.phase.name,
      'players': room.engine.players.map((p) => p.toJson()).toList(),
      'currentPlayerId': room.engine.currentPlayer.id, 'lastDiceValue': room.engine.lastDiceValue,
    },
  });
}
