import 'dart:convert';
import 'dart:io';

import 'package:firebase_admin_sdk/auth.dart';
import 'package:firebase_admin_sdk/firebase_admin_sdk.dart';
import 'package:google_cloud_firestore/google_cloud_firestore.dart' show Firestore;

FirebaseApp? _adminApp;

/// The Firebase service account, from the first source that is set:
/// 1. `FIREBASE_SERVICE_ACCOUNT_JSON`: the key file's JSON content (for hosts
///    that inject secrets as environment variables),
/// 2. `GOOGLE_APPLICATION_CREDENTIALS`: path to the key file,
/// 3. `service_account.json` in the working directory (local development).
Map<String, dynamic>? _serviceAccount() {
  final env = Platform.environment;
  final inline = env['FIREBASE_SERVICE_ACCOUNT_JSON'];
  if (inline != null && inline.trim().isNotEmpty) {
    return jsonDecode(inline) as Map<String, dynamic>;
  }
  final path = env['GOOGLE_APPLICATION_CREDENTIALS'];
  for (final file in [
    if (path != null && path.isNotEmpty) File(path),
    File('service_account.json'),
  ]) {
    if (file.existsSync()) {
      return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    }
  }
  return null;
}

/// Returns the lazily-initialised [FirebaseApp].
/// Throws [StateError] if no service account is configured.
FirebaseApp getAdminApp() {
  if (_adminApp != null) return _adminApp!;

  final sa = _serviceAccount();
  if (sa == null) {
    throw StateError(
      'No Firebase service account: set FIREBASE_SERVICE_ACCOUNT_JSON or '
      'GOOGLE_APPLICATION_CREDENTIALS, or place service_account.json in the '
      'working directory.',
    );
  }

  final projectId = sa['project_id'] as String;
  _adminApp = FirebaseApp.initializeApp(
    options: AppOptions(
      credential: Credential.fromServiceAccountParams(
        projectId: projectId,
        email: sa['client_email'] as String,
        privateKey: sa['private_key'] as String,
        clientId: sa['client_id'] as String?,
      ),
      projectId: projectId,
    ),
  );
  return _adminApp!;
}

/// Returns the [Auth] instance, initialising Firebase Admin if needed.
Auth getAdminAuth() => getAdminApp().auth();

/// Returns the [Firestore] instance, initialising Firebase Admin if needed.
Firestore getAdminFirestore() => getAdminApp().firestore();

/// Verifies [idToken] and returns the authenticated user's UID.
///
/// Returns `null` if invalid or expired.
/// Returns `null` (not a bypass) when `service_account.json` is absent —
/// callers that need a dev bypass should check [isAdminConfigured] themselves.
Future<String?> getUidFromToken(String? idToken) async {
  if (idToken == null || idToken.isEmpty) return null;
  try {
    final decoded = await getAdminAuth().verifyIdToken(idToken);
    return decoded.uid;
  } catch (_) {
    return null;
  }
}

/// `true` when a service account is available (see [_serviceAccount]).
/// Resolved once: credentials don't change while the server runs.
final bool isAdminConfigured = _serviceAccount() != null;

/// `true` only when the operator explicitly opts into running without Firebase
/// Admin (`PARCHIS_DEV_AUTH_BYPASS=true`). A deploy that merely lacks
/// `service_account.json` must fail closed, not silently disable auth.
bool get devAuthBypass =>
    Platform.environment['PARCHIS_DEV_AUTH_BYPASS'] == 'true';

/// `true` when debug-only room features (`testMode`, forced dice) may be used
/// (`PARCHIS_ALLOW_TEST_MODE=true`). Never enable in production.
bool get testModeAllowed =>
    Platform.environment['PARCHIS_ALLOW_TEST_MODE'] == 'true';

/// Verifies [idToken] against Firebase Auth.
///
/// Returns `true` if valid. Returns `false` if the token is invalid/expired.
/// Without `service_account.json`, returns [devAuthBypass] (default `false`).
Future<bool> verifyIdToken(String? idToken) async {
  if (!isAdminConfigured) return devAuthBypass;
  if (idToken == null || idToken.isEmpty) return false;
  return await getUidFromToken(idToken) != null;
}
