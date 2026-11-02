import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:parchis_server/server_stats.dart';

/// Liveness plus in-memory counters, used to spot rooms, sockets or timers
/// that are never released.
Response onRequest(RequestContext context) {
  return Response(
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({'status': 'ok', ...serverStats()}),
  );
}
