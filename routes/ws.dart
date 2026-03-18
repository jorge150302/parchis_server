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

  void broadcast(Map<String, dynamic> event) {
    final message = jsonEncode(event);
    for (final channel in clients.values) {
      channel.sink.add(message);
    }
  }
}

// --- Estado Global del Servidor ---

final Map<String, GameRoom> _rooms = {};
final Map<WebSocketChannel, String> _channelToPlayer = {};
final Map<WebSocketChannel, String> _channelToRoom = {};

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
            player.isAI = true;
            room.clients.remove(playerId);
            _broadcastGameState(roomCode);
            _broadcastInfo(roomCode, '${player.name} ha salido. IA al mando.');

            if (room.engine.currentPlayer.id == playerId &&
                room.engine.players.length == room.maxPlayers) {
              _triggerAITurn(roomCode);
            }
          }
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
          final data =
              (event['data'] ?? <String, dynamic>{}) as Map<String, dynamic>;

          final clientId = event['clientId'] as String?;
          if (clientId == null) {
            _sendError(channel, 'clientId es requerido en la raíz del JSON.');
            return;
          }

          // 1. EVENTO: find_match (Matchmaking)
          if (eventName == 'find_match') {
            final targetMaxPlayers = (data['maxPlayers'] as int?) ?? 2;
            
            GameRoom? foundRoom;
            for (final room in _rooms.values) {
              if (room.isPublic && 
                  room.maxPlayers == targetMaxPlayers && 
                  room.engine.players.length < room.maxPlayers &&
                  room.engine.phase == GamePhase.idle) {
                foundRoom = room;
                break;
              }
            }

            if (foundRoom != null) {
              _joinToRoom(channel, foundRoom, clientId, data['name'] as String?);
            } else {
              // NO CREAR AUTOMÁTICAMENTE - DEVOLVER ERROR ESPECÍFICO
              channel.sink.add(jsonEncode({
                'event': 'error',
                'data': {
                  'code': 'MATCH_NOT_FOUND',
                  'message': 'No se encontraron salas públicas disponibles para $targetMaxPlayers jugadores.'
                }
              }));
            }
            return;
          }

          if (eventName == 'create_game') {
            final maxPlayers = (data['maxPlayers'] as int?) ?? 2;
            final isPublic = (data['isPublic'] as bool?) ?? false;
            _createAndJoinRoom(channel, clientId, data['name'] as String?, maxPlayers, isPublic);
          }

          if (eventName == 'join_game') {
            final roomCode = data['roomCode'] as String?;
            final room = _rooms[roomCode ?? ''];
            if (room != null) {
              _joinToRoom(channel, room, clientId, data['name'] as String?);
            } else {
              _sendError(channel, 'La sala no existe o ha sido cerrada.');
            }
          }

          if (eventName == 'roll_dice') {
            _handleRollDice(channel);
          }

          if (eventName == 'chat_message') {
            final roomCode = _channelToRoom[channel];
            if (roomCode != null) {
              final room = _rooms[roomCode];
              if (room != null) {
                final player =
                    room.engine.players.firstWhere((p) => p.id == clientId);
                room.broadcast({
                  'event': 'chat',
                  'data': {
                    'sender': player.name,
                    'senderId': clientId,
                    'message': data['message']
                  },
                });
              }
            }
          }
        } catch (e) {
          // Error silencioso
        }
      },
      onDone: handleDisconnect,
      onError: (dynamic error) => handleDisconnect(),
    );
  });
  return handler(context);
}

// --- Funciones de Gestión de Salas ---

void _createAndJoinRoom(WebSocketChannel channel, String clientId, String? name, int maxPlayers, bool isPublic) {
  final roomCode = (DateTime.now().millisecondsSinceEpoch % 100000).toString().padLeft(5, '0');
  final board = generateBoard(classicActionPositions, classicActions);
  final engine = GameEngine(board: board, players: []);
  
  final room = GameRoom(roomCode, engine, maxPlayers, isPublic: isPublic);
  _rooms[roomCode] = room;

  final playerName = name ?? 'Anfitrión';
  final newPlayer = Player(id: clientId, name: playerName);
  room.engine.players.add(newPlayer);
  room.clients[clientId] = channel;
  _channelToPlayer[channel] = clientId;
  _channelToRoom[channel] = roomCode;
  
  channel.sink.add(jsonEncode({
    'event': 'game_created',
    'data': {'roomCode': roomCode},
  }));
  _broadcastGameState(roomCode);
}

void _joinToRoom(WebSocketChannel channel, GameRoom room, String clientId, String? name) {
  final existingPlayerIndex = room.engine.players.indexWhere((p) => p.id == clientId);
  if (existingPlayerIndex != -1) {
    final player = room.engine.players[existingPlayerIndex];
    final oldChannel = room.clients[clientId];
    if (oldChannel != null && oldChannel != channel) {
      _channelToPlayer.remove(oldChannel);
      _channelToRoom.remove(oldChannel);
    }
    player.isAI = false; 
    room.clients[clientId] = channel;
    _channelToPlayer[channel] = clientId;
    _channelToRoom[channel] = room.code;
    channel.sink.add(jsonEncode({
      'event': 'game_joined',
      'data': {'playerCount': room.engine.players.length, 'reconnected': true},
    }));
    _broadcastGameState(room.code);
    return;
  }

  if (room.engine.phase != GamePhase.idle || room.engine.players.length >= room.maxPlayers) {
    _sendError(channel, 'La sala no está disponible.');
    return;
  }

  final playerName = name ?? 'Jugador ${room.engine.players.length + 1}';
  final newPlayer = Player(id: clientId, name: playerName);
  room.engine.players.add(newPlayer);
  room.clients[clientId] = channel;
  _channelToPlayer[channel] = clientId;
  _channelToRoom[channel] = room.code;
  channel.sink.add(jsonEncode({
    'event': 'game_joined',
    'data': {'playerCount': room.engine.players.length},
  }));
  _broadcastGameState(room.code);
  _broadcastInfo(room.code, '$playerName se ha unido.');
}

void _handleRollDice(WebSocketChannel? channel, {String? roomCode, String? playerId}) {
  final rCode = roomCode ?? _channelToRoom[channel];
  final pId = playerId ?? _channelToPlayer[channel];
  if (rCode == null || pId == null) return;
  final room = _rooms[rCode];

  if (room != null) {
    if (room.engine.currentPlayer.id != pId) {
      if (channel != null) _sendError(channel, 'No es tu turno.');
      return;
    }
    if (room.engine.phase != GamePhase.rolling && room.engine.phase != GamePhase.idle) {
      if (channel != null) _sendError(channel, 'Acción no permitida.');
      return;
    }
    if (room.engine.players.length < room.maxPlayers) {
      if (channel != null) _sendError(channel, 'Esperando jugadores...');
      return;
    }

    final engine = room.engine;
    final player = engine.players.firstWhere((p) => p.id == pId);

    if (!player.isFinished && engine.phase != GamePhase.finished) {
      engine.phase = GamePhase.moving;
      final diceValue = engine.rollDice();
      _broadcastDiceResult(rCode, diceValue, pId);

      if (diceValue == 6) player.consecutiveSixes++; else player.consecutiveSixes = 0;

      Timer(Duration(milliseconds: player.isAI ? 1500 : 500), () {
        var canRepeat = (diceValue == 6);
        String? actionMsg;

        if (player.consecutiveSixes >= 3) {
          player.resetToStart();
          player.consecutiveSixes = 0;
          _broadcastGameEvent(rCode, '${player.name} sacó tres 6 y vuelve al inicio.');
          _moveToNextTurnWithSkips(rCode);
          return;
        }

        if (engine.canMove(player, diceValue)) {
          for (var i = 0; i < diceValue; i++) engine.stepForward(player);
          final cell = engine.board.getCell(player.position);
          if (cell.action != null) {
            final action = cell.action!;
            switch (action.type) {
              case BoardActionType.goToStart: actionMsg = '${player.name} volvió al inicio.'; break;
              case BoardActionType.moveTo: actionMsg = '${player.name} fue movido a la casilla ${action.targetNumber}.'; break;
              case BoardActionType.skipTurn: actionMsg = '${player.name} perdió el turno.'; break;
              case BoardActionType.rollAgain: actionMsg = '${player.name} repite turno.'; player.extraTurns++; break;
            }
            engine.applyCellAction(player);
          }
          if (engine.resolveCollisions(player)) { actionMsg = '${player.name} capturó ficha.'; player.extraTurns++; }
          if (diceValue == 6 && actionMsg == null) actionMsg = '${player.name} sacó un 6.';
          if (player.isFinished) actionMsg = '${player.name} llegó a la meta.';
        } else if (diceValue == 6) {
          actionMsg = '${player.name} sacó un 6 pero no tiene espacio.';
        }

        if (actionMsg != null) _broadcastGameEvent(rCode, actionMsg);
        if (player.extraTurns > 0) { player.extraTurns--; engine.phase = GamePhase.rolling; _broadcastGameState(rCode); }
        else if (canRepeat) { engine.phase = GamePhase.rolling; _broadcastGameState(rCode); }
        else _moveToNextTurnWithSkips(rCode);

        if (engine.phase == GamePhase.finished) _rooms.remove(rCode);
        else if (engine.currentPlayer.isAI && !engine.currentPlayer.isFinished) _triggerAITurn(rCode);
      });
    }
  }
}

void _moveToNextTurnWithSkips(String roomCode) {
  final room = _rooms[roomCode];
  if (room == null) return;
  final engine = room.engine;
  engine.nextTurn();
  engine.phase = GamePhase.rolling;
  if (engine.currentPlayer.mustSkipTurn && !engine.currentPlayer.isFinished) {
    engine.currentPlayer.consumeSkip();
    _broadcastGameEvent(roomCode, '${engine.currentPlayer.name} salta turno.');
    _moveToNextTurnWithSkips(roomCode); 
  } else {
    _broadcastGameState(roomCode);
    if (engine.phase == GamePhase.finished) _rooms.remove(roomCode);
  }
}

void _triggerAITurn(String roomCode) {
  Timer(const Duration(seconds: 2), () {
    final room = _rooms[roomCode];
    if (room != null && room.engine.phase != GamePhase.finished) {
      _handleRollDice(null, roomCode: roomCode, playerId: room.engine.currentPlayer.id);
    }
  });
}

// --- Helpers de Comunicación ---

void _broadcastGameEvent(String roomCode, String message) {
  _rooms[roomCode]?.broadcast({
    'event': 'game_event',
    'data': {'message': message},
  });
}

void _broadcastGameState(String roomCode) {
  final room = _rooms[roomCode];
  if (room == null) return;

  String phaseStr = 'idle';
  switch (room.engine.phase) {
    case GamePhase.idle: phaseStr = 'idle'; break;
    case GamePhase.rolling: phaseStr = 'rolling'; break;
    case GamePhase.moving: phaseStr = 'moving'; break;
    case GamePhase.finished: phaseStr = 'finished'; break;
  }

  room.broadcast({
    'event': 'game_state',
    'data': {
      'roomCode': room.code,
      'maxPlayers': room.maxPlayers,
      'phase': phaseStr,
      'winners': room.engine.finishedPlayers.map((p) => p.id).toList(),
      'players': room.engine.players.asMap().entries.map((entry) {
        final index = entry.key;
        final p = entry.value;
        final json = p.toJson();
        json['index'] = index;
        return json;
      }).toList(),
      'currentPlayerId': room.engine.currentPlayer.id,
    },
  });
}

void _broadcastDiceResult(String roomCode, int diceValue, String playerId) {
  _rooms[roomCode]?.broadcast({
    'event': 'dice_result',
    'data': {'diceValue': diceValue, 'playerId': playerId},
  });
}

void _broadcastInfo(String roomCode, String message) {
  _rooms[roomCode]?.broadcast({
    'event': 'info',
    'data': {'message': message},
  });
}

void _broadcastInfoToChannel(WebSocketChannel channel, String message) {
  channel.sink.add(jsonEncode({
    'event': 'info',
    'data': {'message': message},
  }));
}

void _sendError(WebSocketChannel channel, String message) {
  channel.sink.add(
    jsonEncode({
      'event': 'error',
      'data': {'message': message},
    }),
  );
}
