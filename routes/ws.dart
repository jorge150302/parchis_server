import 'package:dart_frog/dart_frog.dart';
import 'package:dart_frog_web_socket/dart_frog_web_socket.dart';
import 'package:parchis_server/rooms.dart';

/// Adapts a WebSocket to the transport-agnostic room logic in lib/rooms.dart.
class _WebSocketConnection implements ClientConnection {
  _WebSocketConnection(this._channel);
  final WebSocketChannel _channel;

  @override
  void send(String message) => _channel.sink.add(message);

  @override
  void close() => _channel.sink.close();
}

Future<Response> onRequest(RequestContext context) async {
  registerRoomStats();
  final handler = webSocketHandler((channel, protocol) {
    final connection = _WebSocketConnection(channel);
    channel.stream.listen(
      (dynamic message) => handleClientMessage(connection, message),
      onDone: () => handleClientDisconnect(connection),
      onError: (dynamic _) => handleClientDisconnect(connection),
    );
  });
  return handler(context);
}
