import 'dart:async';
import 'dart:convert';
import 'package:dart_frog/dart_frog.dart';
import 'package:dart_frog_web_socket/dart_frog_web_socket.dart';

import 'package:parchis_server/game_engine.dart';
import 'package:parchis_server/logic/board_generator.dart';
import 'package:parchis_server/logic/board_presets.dart';
import 'package:parchis_server/models/player.dart';

// --- Clases de Soporte ---

class GameRoom {
  GameRoom(this.code, this.engine);

  final String code;
  final GameEngine engine;
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
    
    channel.stream.listen(
      (dynamic message) {
        try {
          final event = jsonDecode(message as String) as Map<String, dynamic>;
          final eventName = event['event'] as String;
          final data = (event['data'] ?? <String, dynamic>{}) as Map<String, dynamic>;
          
          // EXTRAEMOS EL clientId DE LA RAÍZ DEL JSON
          final String? clientId = event['clientId'] as String?;

          // 1. EVENTO: create_game
          if (eventName == 'create_game') {
            if (clientId == null) {
              _sendError(channel, 'clientId es requerido.');
              return;
            }

            final roomCode = (DateTime.now().millisecondsSinceEpoch % 100000)
                .toString()
                .padLeft(5, '0');
            final board = generateBoard(classicActionPositions, classicActions);
            final engine = GameEngine(board: board, players: []);
            
            final room = GameRoom(roomCode, engine);
            _rooms[roomCode] = room;

            final playerName = (data['name'] as String?) ?? 'Anfitrión';
            
            final newPlayer = Player(id: clientId, name: playerName);
            room.engine.players.add(newPlayer);
            room.clients[clientId] = channel;
            
            _channelToPlayer[channel] = clientId;
            _channelToRoom[channel] = roomCode;
            
            channel.sink.add(jsonEncode({
              'event': 'game_created',
              'data': {'roomCode': roomCode}
            }));

            _broadcastGameState(roomCode);
          }

          // 2. EVENTO: join_game
          if (eventName == 'join_game') {
            if (clientId == null) {
              _sendError(channel, 'clientId es requerido.');
              return;
            }

            final roomCode = data['roomCode'] as String?;
            final room = _rooms[roomCode ?? ''];

            if (room != null && roomCode != null) {
              if (room.engine.players.length >= 4) {
                _sendError(channel, 'La sala está llena.');
                return;
              }

              final playerName = (data['name'] as String?) ?? 'Jugador ${room.engine.players.length + 1}';
              
              final newPlayer = Player(id: clientId, name: playerName);
              room.engine.players.add(newPlayer);
              room.clients[clientId] = channel;
              
              _channelToPlayer[channel] = clientId;
              _channelToRoom[channel] = roomCode;

              channel.sink.add(jsonEncode({
                'event': 'game_joined',
                'data': {'playerCount': room.engine.players.length}
              }));

              _broadcastGameState(roomCode);
              _broadcastInfo(roomCode, '$playerName se ha unido.');
            } else {
              _sendError(channel, 'La sala $roomCode no existe.');
            }
          }

          // 3. EVENTO: roll_dice
          if (eventName == 'roll_dice') {
            _handleRollDice(channel);
          }

          // 4. EVENTO: chat_message
          if (eventName == 'chat_message') {
            final roomCode = _channelToRoom[channel];
            final playerId = _channelToPlayer[channel];
            if (roomCode != null && playerId != null) {
              final room = _rooms[roomCode];
              if (room != null) {
                final player = room.engine.players.firstWhere((p) => p.id == playerId);
                room.broadcast({
                  'event': 'chat',
                  'data': {'sender': player.name, 'message': data['message']}
                });
              }
            }
          }

        } catch (e) {
          print('Error procesando mensaje: $e');
        }
      },
      onDone: () {
        final roomCode = _channelToRoom[channel];
        final playerId = _channelToPlayer[channel];
        
        if (roomCode != null && playerId != null) {
          final room = _rooms[roomCode];
          if (room != null) {
            final player = room.engine.players.firstWhere((p) => p.id == playerId);
            player.isAI = true; 
            room.clients.remove(playerId);
            
            _broadcastInfo(roomCode, '${player.name} desconectado. IA al mando.');
            _broadcastGameState(roomCode);

            if (room.engine.currentPlayer.id == playerId) {
              _triggerAITurn(roomCode);
            }
          }
        }
        _channelToPlayer.remove(channel);
        _channelToRoom.remove(channel);
      },
    );
  });

  return handler(context);
}

// --- Lógica de Juego y Turnos IA ---

void _handleRollDice(WebSocketChannel? channel, {String? roomCode, String? playerId}) {
  final rCode = roomCode ?? _channelToRoom[channel];
  final pId = playerId ?? _channelToPlayer[channel];
  
  if (rCode == null || pId == null) return;
  final room = _rooms[rCode];

  if (room != null && room.engine.currentPlayer.id == pId) {
    if (room.engine.players.length < 2) {
      if (channel != null) {
        _sendError(channel, 'Esperando a que se una otro jugador...');
      }
      return;
    }

    final engine = room.engine;
    final player = engine.players.firstWhere((p) => p.id == pId);

    if (!player.isFinished) {
      final diceValue = engine.rollDice();
      
      _broadcastDiceResult(rCode, diceValue, pId);

      Timer(Duration(milliseconds: player.isAI ? 1500 : 500), () {
        bool extraTurn = false;
        if (engine.canMove(player, diceValue)) {
          for (var i = 0; i < diceValue; i++) { engine.stepForward(player); }
          engine.applyCellAction(player);
          final ateSomeone = engine.resolveCollisions(player);
          if (diceValue == 6 || ateSomeone) extraTurn = true;
        }

        if (!extraTurn) engine.nextTurn();
        _broadcastGameState(rCode);

        if (engine.currentPlayer.isAI && !engine.currentPlayer.isFinished) {
          _triggerAITurn(rCode);
        }
      });
    }
  }
}

void _triggerAITurn(String roomCode) {
  Timer(const Duration(seconds: 2), () {
    final room = _rooms[roomCode];
    if (room != null) {
      _handleRollDice(null, roomCode: roomCode, playerId: room.engine.currentPlayer.id);
    }
  });
}

// --- Helpers de Comunicación ---

void _broadcastGameState(String roomCode) {
  final room = _rooms[roomCode];
  if (room == null) return;

  room.broadcast({
    'event': 'game_state',
    'data': {
      'roomCode': room.code,
      'players': room.engine.players.asMap().entries.map((entry) {
        final index = entry.key;
        final p = entry.value;
        final json = p.toJson();
        json['index'] = index;
        return json;
      }).toList(),
      'currentPlayerId': room.engine.currentPlayer.id,
    }
  });
}

void _broadcastDiceResult(String roomCode, int diceValue, String playerId) {
  _rooms[roomCode]?.broadcast({
    'event': 'dice_result',
    'data': {'diceValue': diceValue, 'playerId': playerId}
  });
}

void _broadcastInfo(String roomCode, String message) {
  _rooms[roomCode]?.broadcast({
    'event': 'info',
    'data': {'message': message}
  });
}

void _sendError(WebSocketChannel channel, String message) {
  channel.sink.add(jsonEncode({
    'event': 'error',
    'data': {'message': message}
  }));
}
