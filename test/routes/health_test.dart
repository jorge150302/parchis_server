import 'dart:convert';
import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:parchis_server/server_stats.dart';
import 'package:test/test.dart';

import '../../routes/health.dart' as route;

class _MockRequestContext extends Mock implements RequestContext {}

void main() {
  group('GET /health', () {
    test('reports zero counters before anything connects', () async {
      final response = route.onRequest(_MockRequestContext());
      expect(response.statusCode, equals(HttpStatus.ok));
      final body = jsonDecode(await response.body()) as Map<String, dynamic>;
      expect(body['status'], 'ok');
      expect(body['rooms'], 0);
      expect(body['connections'], 0);
      expect(body['reconnectionTimers'], 0);
    });

    test('reports whatever the registered snapshot returns', () async {
      registerServerStats(() => {'rooms': 3, 'connections': 7});
      final response = route.onRequest(_MockRequestContext());
      final body = jsonDecode(await response.body()) as Map<String, dynamic>;
      expect(body['rooms'], 3);
      expect(body['connections'], 7);
    });
  });
}
