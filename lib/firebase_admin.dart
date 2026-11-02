import 'dart:convert';
import 'dart:io';

import 'package:firebase_admin_sdk/auth.dart';
import 'package:firebase_admin_sdk/firebase_admin_sdk.dart';
import 'package:google_cloud_firestore/google_cloud_firestore.dart' show Firestore;

FirebaseApp? _adminApp;

/// Returns the lazily-initialised [FirebaseApp].
/// Throws [StateError] if `service_account.json` is missing.
FirebaseApp getAdminApp() {
  if (_adminApp != null) return _adminApp!;

  final saFile = File('service_account.json');
  if (!saFile.existsSync()) {
    throw StateError(
      'service_account.json not found. Place the Firebase service account '
      'file in the parchis_server/ root directory.',
    );
  }

  final saJson = jsonDecode(saFile.readAsStringSync()) as Map<String, dynamic>;
  _adminApp = FirebaseApp.initializeApp(
    options: AppOptions(
      credential: Credential.fromServiceAccount(saFile),
      projectId: saJson['project_id'] as String,
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

/// `true` when `service_account.json` exists next to the server root.
bool get isAdminConfigured => File('service_account.json').existsSync();

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
