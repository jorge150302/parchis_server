import 'dart:convert';
import 'dart:io';
import 'package:web_socket_channel/io.dart';

void main() async {
  final channel = IOWebSocketChannel.connect('ws://localhost:8080/ws');
  print('✅ Conectado al servidor de Parchís');

  channel.stream.listen((dynamic message) {
    try {
      // Añadimos "as Map<String, dynamic>" para evitar el error de tipos
      final event = jsonDecode(message as String) as Map<String, dynamic>;
      final eventName = event['event'] as String;
      final data = (event['data'] ?? <String, dynamic>{}) as Map<String, dynamic>;

      switch (eventName) {
        case 'game_created':
          print('\n🏠 SALA CREADA: ${data['roomCode']}');
          break;
        case 'game_joined':
          print('\n🤝 UNIDO CON ÉXITO. Jugadores en sala: ${data['playerCount']}');
          break;
        case 'game_state':
          print('\n--- TABLERO ---');
          print('Sala: ${data['roomCode']}');
          final players = data['players'] as List<dynamic>;
          for (var p in players) {
            final player = p as Map<String, dynamic>;
            print('👤 [Slot ${player['index']}] ${player['name']} | Pos: ${player['position']} | AI: ${player['isAI']}');
          }
          print('👉 Turno de: ${data['currentPlayerId']}');
          break;
        case 'dice_result':
          print('\n🎲 DADO: ${data['diceValue']} (Por: ${data['playerId']})');
          break;
        case 'chat':
          print('\n💬 [${data['sender']}]: ${data['message']}');
          break;
        case 'error':
          print('\n❌ ERROR: ${data['message']}');
          break;
      }
    } catch (e) {
      print('Error procesando respuesta del servidor: $e');
    }
  });

  print('\n--- COMANDOS ---');
  print('- "create" : Crear sala');
  print('- "join [CÓDIGO]" : Unirse a una sala');
  print('- "roll" : Tirar dado');
  print('- Cualquier cosa : Chatear');

  stdin.listen((List<int> bytes) {
    final input = utf8.decode(bytes).trim();
    if (input.isEmpty) return;

    if (input == 'create') {
      channel.sink.add(jsonEncode({
        'event': 'create_game',
        'data': {'name': 'Anfitrión'}
      }));
    }
    else if (input.startsWith('join ')) {
      final parts = input.split(' ');
      if (parts.length < 2) return;
      final code = parts[1];
      channel.sink.add(jsonEncode({
        'event': 'join_game',
        'data': {'roomCode': code, 'name': 'Tester_${DateTime.now().second % 100}'}
      }));
    }
    else if (input == 'roll') {
      channel.sink.add(jsonEncode({'event': 'roll_dice'}));
    } else {
      channel.sink.add(jsonEncode({
        'event': 'chat_message',
        'data': {'message': input}
      }));
    }
  });
}
