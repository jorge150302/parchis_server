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

          if (eventName == 'move_token') {
            final tokenId = data['tokenId'] as int?;
            if (tokenId != null) {
              _handleMoveToken(channel, tokenId);
            } else {
              _sendError(channel, 'tokenId es requerido.');
            }
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
      final diceValue = engine.rollDice();
      _broadcastDiceResult(rCode, diceValue, pId);

      engine.registerSix(player, diceValue);

      if (player.consecutiveSixes >= 3) {
        engine.penaltyThreeSixes(player);
        _broadcastGameEvent(rCode, '${player.name} sacó tres 6 y sus fichas vuelven al inicio.');
        _moveToNextTurnWithSkips(rCode);
        return;
      }

      if (engine.canMoveAnyToken(player, diceValue)) {
        engine.phase = GamePhase.choosingToken;
        _broadcastGameState(rCode);
        
        if (player.isAI) {
           Timer(const Duration(seconds: 1), () {
             final validToken = player.tokens.firstWhere((t) => engine.canMove(t, diceValue));
             _handleMoveToken(null, validToken.id, roomCode: rCode, playerId: pId);
           });
        }
      } else {
        String msg = '${player.name} sacó un $diceValue pero no puede mover ninguna ficha.';
        _broadcastGameEvent(rCode, msg);
        if (diceValue == 6) {
           engine.phase = GamePhase.rolling;
           _broadcastGameState(rCode);
        } else {
           _moveToNextTurnWithSkips(rCode);
        }
      }
    }
  }
}

void _handleMoveToken(WebSocketChannel? channel, int tokenId, {String? roomCode, String? playerId}) {
  final rCode = roomCode ?? _channelToRoom[channel];
  final pId = playerId ?? _channelToPlayer[channel];
  if (rCode == null || pId == null) return;
  final room = _rooms[rCode];
  if (room == null) return;

  final engine = room.engine;
  final player = engine.players.firstWhere((p) => p.id == pId);

  if (engine.currentPlayer.id != pId || engine.phase != GamePhase.choosingToken) {
    if (channel != null) _sendError(channel, 'No es el momento de mover.');
    return;
  }

  final token = player.tokens.firstWhere((t) => t.id == tokenId, orElse: () => throw 'Token no encontrado');
  final diceValue = engine.lastDiceValue;

  if (!engine.canMove(token, diceValue)) {
    if (channel != null) _sendError(channel, 'Esa ficha no se puede mover.');
    return;
  }

  engine.phase = GamePhase.moving;
  _broadcastGameState(rCode);

  Timer(const Duration(milliseconds: 500), () {
    final canRepeat = (diceValue == 6);
    String? actionMsg;

    for (var i = 0; i < diceValue; i++) engine.stepForward(token);
    
    final cell = engine.board.getCell(token.position);
    if (cell.action != null) {
      final action = cell.action!;
      switch (action.type) {
        case BoardActionType.goToStart: actionMsg = '${player.name} volvió al inicio.'; break;
        case BoardActionType.moveTo: actionMsg = '${player.name} avanzó/retrocedió por casilla de acción.'; break;
        case BoardActionType.skipTurn: actionMsg = '${player.name} perdió el turno.'; break;
        case BoardActionType.rollAgain: actionMsg = '${player.name} repite turno por casilla.'; player.extraTurns++; break;
      }
      engine.applyCellAction(player, token);
    }

    if (engine.resolveCollisions(token)) {
      final captureMsg = '${player.name} capturó una ficha.';
      actionMsg = (actionMsg == null) ? captureMsg : '$actionMsg y $captureMsg';
      player.extraTurns++;
    }

    if (token.isFinished) {
       final finishMsg = '¡Una ficha de ${player.name} llegó a la meta!';
       actionMsg = (actionMsg == null) ? finishMsg : '$actionMsg. $finishMsg';
       player.extraTurns++;
    }

    if (actionMsg != null) _broadcastGameEvent(rCode, actionMsg);

    // CRUCIAL: Si el jugador ha terminado, ignorar turnos extra y pasar turno / finalizar juego
    if (player.isFinished) {
      player.extraTurns = 0;
      _moveToNextTurnWithSkips(rCode);
    } else if (player.extraTurns > 0) {
      player.extraTurns--;
      engine.phase = GamePhase.rolling;
      _broadcastGameState(rCode);
    } else if (canRepeat) {
      engine.phase = GamePhase.rolling;
      _broadcastGameState(rCode);
    } else {
      _moveToNextTurnWithSkips(rCode);
    }

    if (engine.phase == GamePhase.finished) {
      _broadcastGameEvent(rCode, '¡${player.name} ha terminado!');
      Timer(const Duration(seconds: 10), () => _rooms.remove(rCode));
    } else if (engine.currentPlayer.isAI && !engine.currentPlayer.isFinished) {
      _triggerAITurn(rCode);
    }
  });
}

void _moveToNextTurnWithSkips(String roomCode) {
  final room = _rooms[roomCode];
  if (room == null) return;
  final engine = room.engine;

  bool skipHappened = false;
  do {
    engine.nextTurn();
    if (engine.phase == GamePhase.finished) break;

    if (engine.currentPlayer.mustSkipTurn && !engine.currentPlayer.isFinished) {
      engine.currentPlayer.consumeSkip();
      _broadcastGameEvent(roomCode, '${engine.currentPlayer.name} salta el turno.');
      skipHappened = true;
    } else {
      skipHappened = false;
    }
  } while (skipHappened);

  _broadcastGameState(roomCode);
}

void _triggerAITurn(String roomCode) {
  Timer(const Duration(seconds: 2), () {
    final room = _rooms[roomCode];
    if (room != null && room.engine.phase == GamePhase.rolling) {
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
    case GamePhase.choosingToken: phaseStr = 'choosing_token'; break;
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
      'lastDiceValue': room.engine.lastDiceValue,
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
