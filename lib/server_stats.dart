/// Live counters exposed by `GET /health`.
///
/// The game state lives in private globals inside `routes/ws.dart`; that route
/// registers a snapshot function here on its first request. Until then nothing
/// has connected, so the empty snapshot is accurate.
Map<String, Object> Function() _snapshot = () => <String, Object>{
      'rooms': 0,
      'roomsByPhase': <String, int>{},
      'connections': 0,
      'reconnectionTimers': 0,
      'activeUids': 0,
      'uidSessions': 0,
    };

void registerServerStats(Map<String, Object> Function() snapshot) {
  _snapshot = snapshot;
}

Map<String, Object> serverStats() => _snapshot();
